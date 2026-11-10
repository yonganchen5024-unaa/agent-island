import Foundation
import Darwin

/// Which Claude sessions are running right now, from Claude Code's own registry
/// (~/.claude/sessions/<pid>.json) checked against the process table. This decides which rows exist;
/// hook events decide their state. The registry format is Claude's internal one, so an unreadable
/// entry is skipped rather than guessed at. Re-verify after Claude upgrades.
enum ClaudeLiveScan {
    static func scan(directory: URL) -> [ClaudeLiveSession] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        var found: [ClaudeLiveSession] = []
        for url in entries.prefix(4096) where url.pathExtension == "json" {
            guard let fileNumber = Int32(url.deletingPathExtension().lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 1_048_576,
                  let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (object["pid"] as? NSNumber)?.int32Value, pid == fileNumber, pid > 0,
                  let sessionID = object["sessionId"] as? String, !sessionID.isEmpty,
                  let startedMS = object["startedAt"] as? Double else { continue }
            // The usage probes of this app and of Agent HUD are not conversations.
            if let entry = object["entrypoint"] as? String, ClaudeProbeSessions.entrypoints.contains(entry) { ClaudeProbeSessions.mark(sessionID); continue }
            let started = Date(timeIntervalSince1970: startedMS / 1000)
            guard isRunning(pid: pid, startedBy: started) else { continue }
            // The name shown by Claude itself: set by /rename, or derived when the user gave none.
            let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            found.append(ClaudeLiveSession(sessionID: sessionID, cwd: object["cwd"] as? String ?? "", startedAt: started, name: name?.isEmpty == false ? name : nil,
                                           status: object["status"] as? String, statusUpdatedAt: (object["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }, pid: pid))
        }
        return found
    }

    /// True if the PID is alive, not a zombie, and is not a later process that reused the PID.
    static func isRunning(pid: Int32, startedBy: Date) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return false }
        guard info.kp_proc.p_stat != 5 /* SZOMB */ else { return false }
        let start = info.kp_proc.p_starttime
        let processStart = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
        return processStart.timeIntervalSince(startedBy) <= 5
    }
}

@MainActor final class ClaudeLiveSessionReader {
    private let store: SessionStore
    private let directory: URL
    private var task: Task<Void, Never>?
    init(store: SessionStore, directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true)) {
        self.store = store; self.directory = directory
    }
    func start() {
        guard task == nil else { return }
        let directory = self.directory
        let activity = ClaudeActivityScanner(projects: directory.deletingLastPathComponent().appendingPathComponent("projects", isDirectory: true))
        task = Task { [weak self] in
            while !Task.isCancelled {
                let live = await Task.detached(priority: .utility) { ClaudeLiveScan.scan(directory: directory) }.value
                let doing = await activity.scan(live)
                guard let self, !Task.isCancelled else { break }
                self.store.updateClaudeActivity(doing)
                self.store.syncClaudeLive(live)
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
        }
    }
    func stop() {
        task?.cancel(); task = nil
        store.syncClaudeLive([])
    }
}
