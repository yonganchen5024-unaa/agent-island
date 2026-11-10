import Foundation
import Combine
import Darwin

/// Local app-server transport. Injectable so protocol behavior can be tested without user data.
protocol CodexRPCTransport: Sendable {
    func start() async throws
    func request(_ data: Data, id: Int) async throws -> Data
    func notify(_ data: Data) async throws
    func stop() async
}

private enum CodexAdapterError: LocalizedError {
    case unavailable, disconnected, timeout, malformed, oversized, server
    var errorDescription: String? {
        switch self {
        case .unavailable: return "未找到可执行的 Codex CLI"
        case .disconnected: return "Codex 本地服务未连接"
        case .timeout: return "Codex 本地服务响应超时"
        case .malformed: return "Codex 本地服务返回了无法识别的数据"
        case .oversized: return "Codex 本地服务响应过大"
        case .server: return "Codex 本地服务拒绝了请求"
        }
    }
}

/// Connects only to an already-running app-server proxy. Never starts or resumes a thread.
actor CodexProcessTransport: CodexRPCTransport {
    private let executable: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()
    private let maxResponseBytes = 4 * 1024 * 1024
    private let timeout: TimeInterval = 8

    init(executable: URL) { self.executable = executable }

    func start() throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CodexAdapterError.unavailable }
        let p = Process()
        p.executableURL = executable
        p.arguments = ["app-server", "proxy"]
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
    }

    func notify(_ data: Data) throws {
        guard let input, process?.isRunning == true else { throw CodexAdapterError.disconnected }
        var wire = data; wire.append(0x0a)
        try input.write(contentsOf: wire)
    }

    func request(_ data: Data, id: Int) throws -> Data {
        try notify(data)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            while let newline = pending.firstIndex(of: 0x0a) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                // Only inspect the response id; notification bodies and unrelated fields are not logged.
                guard let envelope = try? JSONDecoder().decode(RPCIdentity.self, from: line), envelope.id == id else { continue }
                if envelope.error != nil { throw CodexAdapterError.server }
                return line
            }
            guard pending.count <= maxResponseBytes else { throw CodexAdapterError.oversized }
            guard let output, process?.isRunning == true else { throw CodexAdapterError.disconnected }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexAdapterError.timeout }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 8000)))
            if ready == 0 { throw CodexAdapterError.timeout }
            if ready < 0 { if errno == EINTR { continue }; throw CodexAdapterError.disconnected }
            guard let chunk = try output.read(upToCount: 8192), !chunk.isEmpty else { throw CodexAdapterError.disconnected }
            pending.append(chunk)
        }
    }

    func stop() {
        try? input?.close()
        try? output?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil; output = nil; pending.removeAll()
    }
}

private struct RPCIdentity: Decodable {
    let id: Int?
    let error: RPCError?
    struct RPCError: Decodable { let code: Int? }
}

/// Maps only metadata returned by `thread/list`; message fields are deliberately not decoded.
@MainActor
final class CodexSessionAdapter: ObservableObject {
    enum State: Equatable { case stopped, connecting, connected, failed(String) }
    @Published private(set) var state: State = .stopped
    private let store: SessionStore
    private let transport: any CodexRPCTransport
    private let interval: UInt64
    private var task: Task<Void, Never>?
    private var nextID = 0
    private let prefix = "codex:"

    init(store: SessionStore, transport: any CodexRPCTransport, pollSeconds: UInt64 = 5) {
        self.store = store; self.transport = transport
        self.interval = max(1, pollSeconds) * 1_000_000_000
    }

    /// No process or data access occurs until this method is explicitly called.
    func start() {
        guard task == nil else { return }
        state = .connecting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await transport.start()
                try Task.checkCancellation()
                _ = try await self.request(method: "initialize", params: ["clientInfo": ["name": "session-island", "version": "0.1.0"]])
                try Task.checkCancellation()
                try await transport.notify(try Self.encode(["method": "initialized", "params": [:]]))
                while !Task.isCancelled {
                    let threads = try await self.listAll()
                    guard !Task.isCancelled else { break }
                    self.apply(threads)
                    self.state = .connected
                    try await Task.sleep(nanoseconds: self.interval)
                }
            } catch is CancellationError {
                // Stop is expected.
            } catch {
                if !Task.isCancelled {
                    self.store.sessions.removeAll { $0.id.hasPrefix(self.prefix) }
                    self.state = .failed(error.localizedDescription)
                }
            }
            await transport.stop()
            self.task = nil
        }
    }

    func stop() {
        task?.cancel()
        state = .stopped
        store.sessions.removeAll { $0.id.hasPrefix(prefix) }
    }

    private func request(method: String, params: [String: Any]) async throws -> Data {
        nextID += 1
        let id = nextID
        let wire = try Self.encode(["id": id, "method": method, "params": params])
        return try await transport.request(wire, id: id)
    }

    private func listAll() async throws -> [CodexThread] {
        var cursor: String? = nil
        var seen = Set<String>()
        var result: [CodexThread] = []
        // Bound paging; report failure instead of silently presenting an incomplete list as complete.
        for _ in 0..<20 {
            var params: [String: Any] = ["limit": 100, "sortKey": "updated_at", "useStateDbOnly": true,
                                         "sourceKinds": ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"]]
            if let cursor { params["cursor"] = cursor }
            let data = try await request(method: "thread/list", params: params)
            let response = try JSONDecoder().decode(ThreadListEnvelope.self, from: data)
            result.append(contentsOf: response.result.data)
            guard let next = response.result.nextCursor else { return result }
            guard seen.insert(next).inserted else { throw CodexAdapterError.malformed }
            cursor = next
        }
        throw CodexAdapterError.oversized
    }

    private func apply(_ threads: [CodexThread]) {
        // notLoaded is unknown, not idle: do not present it as an active or completed session.
        let items = threads.compactMap { thread -> SessionItem? in
            let status: SessionStatus
            let detail: String
            switch thread.status.type {
            case "active":
                let flags = thread.status.activeFlags ?? []
                if flags.contains("waitingOnApproval") { status = .waiting; detail = "等待审批" }
                else if flags.contains("waitingOnUserInput") { status = .waiting; detail = "等待输入" }
                else { status = .working; detail = "运行中" }
            case "idle": status = .idle; detail = "空闲"
            case "systemError": status = .error; detail = "状态异常"
            default: return nil
            }
            return SessionItem(id: prefix + thread.id, title: thread.name?.isEmpty == false ? thread.name! : "Codex 会话",
                               agent: "Codex", status: status, detail: detail,
                               updatedAt: Date(timeIntervalSince1970: thread.updatedAt))
        }
        store.sessions.removeAll { $0.id.hasPrefix(prefix) }
        store.sessions.append(contentsOf: items)
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private struct ThreadListEnvelope: Decodable {
    struct Result: Decodable { let data: [CodexThread]; let nextCursor: String? }
    let result: Result
}
private struct CodexThread: Decodable {
    struct Status: Decodable { let type: String; let activeFlags: [String]? }
    let id: String
    let name: String?
    let status: Status
    let updatedAt: TimeInterval
}
