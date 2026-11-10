import Foundation
import Network

/// Receives explicitly supplied events on loopback only. No hooks or files are installed.
/// Loopback TCP is unauthenticated and must not be used as an approval authority.
@MainActor
final class LocalEventServer {
    private let store: SessionStore
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "island.local-events")
    private(set) var port: UInt16 = 0
    private var generation = UUID()
    private var peers: [UUID: LocalEventPeer] = [:]

    init(store: SessionStore) {
        self.store = store
    }

    /// Listener readiness is asynchronous; port remains 0 until the listener is ready.
    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        let newListener = try NWListener(using: parameters, on: .any)
        let currentGeneration = UUID()
        generation = currentGeneration
        listener = newListener
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                switch state {
                case .ready:
                    self.port = newListener?.port?.rawValue ?? 0
                    print("Local event port: \(self.port)")
                    fflush(stdout)
                case .failed, .cancelled:
                    self.stop()
                default:
                    break
                }
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration, self.listener != nil, self.peers.count < 32 else {
                    connection.cancel()
                    return
                }
                let id = UUID()
                let peer = LocalEventPeer(connection: connection, queue: self.queue) { [weak self] event in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == currentGeneration else { return }
                        self.store.ingest(event)
                    }
                } onClose: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.peers.removeValue(forKey: id)
                    }
                }
                self.peers[id] = peer
                peer.start()
            }
        }
        newListener.start(queue: queue)
    }

    func stop() {
        generation = UUID()
        listener?.cancel()
        listener = nil
        port = 0
        let oldPeers = peers.values
        peers.removeAll()
        for peer in oldPeers { peer.cancel() }
    }
}

/// A connection receives UTF-8 NDJSON. Each line is limited to 64 KiB.
private final class LocalEventPeer {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onEvent: (SessionEvent) -> Void
    private let onClose: () -> Void
    private var buffer = Data()
    private var closed = false
    private static let maxLineBytes = 65_536
    private static let idleNanoseconds: UInt64 = 10_000_000_000
    private static let lifetimeNanoseconds: UInt64 = 60_000_000_000
    private var timer: DispatchSourceTimer?
    private var expiresAt: UInt64 = 0

    init(connection: NWConnection, queue: DispatchQueue, onEvent: @escaping (SessionEvent) -> Void, onClose: @escaping () -> Void) {
        self.connection = connection
        self.queue = queue
        self.onEvent = onEvent
        self.onClose = onClose
    }

    func start() {
        expiresAt = DispatchTime.now().uptimeNanoseconds + Self.lifetimeNanoseconds
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.setEventHandler { [weak self] in self?.finish() }
        resetDeadline()
        timer.resume()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        queue.async { [self] in finish() }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        connection.cancel()
        onClose()
    }

    /// Active connections still expire after one minute, so a byte trickle cannot
    /// reserve a listener slot indefinitely. Forwarders can reconnect as needed.
    private func resetDeadline() {
        let idleDeadline = DispatchTime.now().uptimeNanoseconds + Self.idleNanoseconds
        timer?.schedule(deadline: DispatchTime(uptimeNanoseconds: min(idleDeadline, expiresAt)))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.resetDeadline()
            }
            while let newline = self.buffer.firstIndex(of: 10) {
                guard self.buffer.distance(from: self.buffer.startIndex, to: newline) <= Self.maxLineBytes else {
                    self.finish(); return
                }
                var line = Data(self.buffer[..<newline])
                self.buffer.removeSubrange(...newline)
                if line.last == 13 { line.removeLast() }
                guard !line.isEmpty, let event = try? JSONDecoder().decode(SessionEvent.self, from: line) else {
                    self.finish(); return
                }
                self.onEvent(event)
            }
            guard self.buffer.count <= Self.maxLineBytes, error == nil, !complete else {
                self.finish(); return
            }
            self.receive()
        }
    }
}
