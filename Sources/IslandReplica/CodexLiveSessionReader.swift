import Darwin
import Foundation

/// Codex has no session registry like Claude's. A session is live if a running codex process holds its
/// rollout file open. Asks the kernel directly: this runs every few seconds, and needs no ps or lsof.
struct CodexProcessDiscovery: CodexOpenFileDiscovering {
    func discover() throws -> CodexOpenFileSnapshot {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { throw CodexLiveTrackerError.commandFailed }
        var files: [CodexOpenFile] = []
        for pid in pids.prefix(Int(bytes)) where pid > 0 {
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, 256) > 0, String(cString: name) == "codex" else { continue }
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
            guard got > 0 else { continue }
            for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.stride)) > 0 else { continue }
                let path = withUnsafePointer(to: &info.pvip.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
                if path.hasSuffix(".jsonl") { files.append(CodexOpenFile(pid: pid, path: path)) }
            }
        }
        return CodexOpenFileSnapshot(files: files, complete: true)
    }
}

/// Conversation names from Codex's own index, reread only when the file changes.
struct CodexThreadNames {
    private var modified: Date?
    private var names: [String: String] = [:]

    mutating func current(file: URL) -> [String: String] {
        let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard changed != modified else { return names }
        modified = changed
        guard let handle = try? FileHandle(forReadingFrom: file) else { names = [:]; return names }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let limit: UInt64 = 2_097_152
        try? handle.seek(toOffset: size > limit ? size - limit : 0)
        guard let data = try? handle.readToEnd() else { return names }
        var lines = data.split(separator: 10)
        if size > limit, !lines.isEmpty { lines.removeFirst() }
        var found: [String: String] = [:]
        for line in lines {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let id = object["id"] as? String, let name = (object["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            found[id] = name
        }
        names = found
        return names
    }
}

enum CodexLiveRows {
    static let prefix = SessionStore.codexLivePrefix

    /// Whether a turn is running is read from the log, so it can be wrong for a moment. Codex does not
    /// log a pending approval, so one shows as running.
    static func rows(from observations: [CodexLiveObservation], names: [String: String], now: Date) -> [SessionItem] {
        let showProject = UserDefaults.standard.object(forKey: "showProjectName") as? Bool ?? true
        return observations.filter { !$0.isChild }.map { session in
            let folder = session.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
            let recentlyWritten = session.modified.map { now.timeIntervalSince($0) < 30 } ?? false
            // A long turn can push its start out of the bounded tail that was read.
            let running = session.lastRecordedTurn == .started || (session.lastRecordedTurn == .unknown && session.truncated && recentlyWritten)
            let name = names[session.sessionID]
            let validID = session.sessionID.allSatisfy { $0.isHexDigit || $0 == "-" }
            return SessionItem(id: prefix + session.sessionID, title: name ?? (folder.isEmpty ? "Codex 会话" : folder), agent: "Codex",
                               status: running ? .working : .idle, detail: showProject && name != nil ? folder : "",
                               updatedAt: session.modified ?? now, lifecycle: session.lastEvent, lifecycleID: session.lastEventID,
                               pid: session.associatedPIDs.min(), jumpURL: session.desktop && validID ? "codex://threads/" + session.sessionID : nil)
        }
    }
}

/// Keeps the Codex rows in the list. Only live sessions, unlike the seven-day log reader in settings.
@MainActor final class CodexLiveSessionReader {
    private let store: SessionStore
    private let root: URL
    private let index: URL
    private let discovery: any CodexOpenFileDiscovering
    private var task: Task<Void, Never>?

    init(store: SessionStore, codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true), discovery: any CodexOpenFileDiscovering = CodexProcessDiscovery()) {
        self.store = store
        root = codexHome.appendingPathComponent("sessions", isDirectory: true)
        index = codexHome.appendingPathComponent("session_index.jsonl")
        self.discovery = discovery
    }

    func start() {
        guard task == nil else { return }
        let root = self.root, index = self.index, discovery = self.discovery
        task = Task { [weak self] in
            var names = CodexThreadNames()
            while !Task.isCancelled {
                let known = names
                let (rows, updated) = await Task.detached(priority: .utility) { () -> ([SessionItem], CodexThreadNames) in
                    var names = known
                    let current = names.current(file: index)
                    // No Codex directory, or nothing running: no rows.
                    let observed = (try? CodexLiveTracker(root: root, discovery: discovery).snapshot())?.sessions ?? []
                    return (CodexLiveRows.rows(from: observed, names: current, now: Date()), names)
                }.value
                names = updated
                guard let self, !Task.isCancelled else { break }
                self.store.syncCodexLive(rows)
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { break }
            }
        }
    }

    func stop() { task?.cancel(); task = nil; store.syncCodexLive([]) }
}
