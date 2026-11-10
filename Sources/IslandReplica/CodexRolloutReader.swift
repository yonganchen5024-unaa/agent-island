import Foundation
import Combine

/// Reads only metadata and lifecycle event names; never writes the Codex directory.
@MainActor
final class CodexRolloutReader: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "未连接"
    private let store: SessionStore
    private let root: URL
    private let inspectOpenFiles: Bool
    private let prefix = "rollout:"
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(store: SessionStore, root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true), inspectOpenFiles: Bool = false) {
        self.store = store; self.root = root; self.inspectOpenFiles = inspectOpenFiles
    }
    func start() {
        guard task == nil else { return }
        let id = UUID(); generation = id; enabled = true; status = "读取本机会话中…"
        let root = self.root; let inspectOpenFiles = self.inspectOpenFiles
        task = Task { [weak self] in
            var associated: Set<String> = []
            var pollCount = 0
            while !Task.isCancelled {
                let shouldInspect = inspectOpenFiles && pollCount % 4 == 0
                let pair = await Task.detached(priority: .utility) {
                    let rows = Self.read(root: root)
                    let snapshot = shouldInspect ? try? CodexLiveTracker(root: root).snapshot() : nil
                    return (rows, snapshot)
                }.value
                let result = pair.0
                guard let self, !Task.isCancelled, self.generation == id else { break }
                if shouldInspect { associated = Set((pair.1?.sessions ?? []).map { $0.sessionID }) }
                pollCount += 1
                switch result {
                case .success(var rows):
                    for index in rows.indices {
                        let id = String(rows[index].id.dropFirst(self.prefix.count))
                        if associated.contains(id) { rows[index].detail += " · 最近发现关联进程" }
                    }
                    let retained = self.store.sessions.filter { !$0.id.hasPrefix(self.prefix) && !$0.id.hasPrefix("demo-") }
                    self.store.sessions = retained + rows
                    self.status = "已读取 \(rows.count) 个近期会话；状态为日志推断"
                case .failure:
                    self.store.sessions.removeAll { $0.id.hasPrefix(self.prefix) }
                    self.status = "无法读取 Codex 会话目录"
                }
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
            }
        }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; enabled = false; status = "未连接"
        store.sessions.removeAll { $0.id.hasPrefix(prefix) }
    }
    private nonisolated static func read(root: URL) -> Result<[SessionItem], Error> {
        let fm = FileManager.default
        do {
            guard fm.isReadableFile(atPath: root.path) else { throw NSError(domain:"sessions", code:1) }
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
            var directoryError: Error?
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in directoryError = error; return false }) else { throw NSError(domain:"sessions", code:1) }
            var candidates: [(URL, Date)] = []
            let cutoff = Date().addingTimeInterval(-7 * 86400)
            while let url = en.nextObject() as? URL {
                guard url.pathExtension == "jsonl", let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true, v.isSymbolicLink != true, let modified = v.contentModificationDate, modified >= cutoff else { continue }
                candidates.append((url, modified))
            }
            if let directoryError { throw directoryError }
            candidates.sort { $0.1 > $1.1 }
            var result: [SessionItem] = []
            var seen = Set<String>()
            for (url, modified) in candidates.prefix(30) {
                guard let f = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? f.close() }
                guard let headData = try? f.read(upToCount: 1_048_576), let newline = headData.firstIndex(of: 10), let meta = object(Data(headData[..<newline])), meta["type"] as? String == "session_meta", let payload = meta["payload"] as? [String: Any], let id = payload["id"] as? String, !id.isEmpty else { continue }
                let parent = payload["parent_thread_id"] as? String
                if parent != nil { continue }
                guard !seen.contains(id) else { continue }
                let cwd = payload["cwd"] as? String
                let title = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? "Codex 会话"
                let size = (try? f.seekToEnd()) ?? 0
                let offset = size > 262144 ? size - 262144 : 0
                try? f.seek(toOffset: offset)
                guard let data = try? f.read(upToCount: 262144) else { continue }
                var lines = data.split(separator: 10, omittingEmptySubsequences: false)
                // A bounded tail can begin or end inside a concurrently written line.
                if offset > 0 && !lines.isEmpty { lines.removeFirst() }
                if data.last != 10 && !lines.isEmpty { lines.removeLast() }
                var lastEvent: String?
                var lastEventID: String?
                for line in lines {
                    guard let o = object(Data(line)), o["type"] as? String == "event_msg", let p = o["payload"] as? [String: Any], let kind = p["type"] as? String else { continue }
                    if ["task_started", "task_complete", "turn_aborted"].contains(kind) {
                        lastEvent = kind
                        lastEventID = (p["turn_id"] as? String).map { kind + ":" + $0 }
                    }
                }
                // A historical log does not prove its process still exists, even
                // if the file was just modified. Never present these as live states.
                let state: SessionStatus = .unknown; let detail: String
                switch lastEvent {
                case "task_complete": detail = "最近一轮已结束，当前状态未知"
                case "turn_aborted": detail = "最近一轮已中断，当前状态未知"
                case "task_started": detail = "最近一轮已开始，当前状态未知"
                default: detail = "当前状态未知"
                }
                seen.insert(id)
                result.append(SessionItem(id: "rollout:" + id, title: title, agent: "Codex", status: state, detail: detail, updatedAt: modified, lifecycle: lastEvent, lifecycleID: lastEventID))
            }
            return .success(result)
        } catch { return .failure(error) }
    }
    private nonisolated static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
}
