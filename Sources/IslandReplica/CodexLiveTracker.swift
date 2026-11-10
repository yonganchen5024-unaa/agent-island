import Foundation
import Darwin

/// Open files are observations at one instant, not evidence that a turn is running.
struct CodexOpenFile: Equatable {
    let pid: Int32
    let path: String
}
struct CodexOpenFileSnapshot {
    let files: [CodexOpenFile]
    /// A false value means permissions or races may have omitted open files.
    let complete: Bool
}
protocol CodexOpenFileDiscovering {
    func discover() throws -> CodexOpenFileSnapshot
}

enum CodexObservedTurn: String { case started, completed, aborted, unknown }
struct CodexLiveObservation {
    let sessionID: String
    let associatedPIDs: Set<Int32>
    let lastRecordedTurn: CodexObservedTurn
    /// An open file and the last log event do not establish live turn state.
    let currentState: SessionStatus = .unknown
    var cwd: String? = nil
    /// A thread spawned by another one, not a conversation of its own.
    var isChild = false
    /// Written by the Codex desktop app, which can open a thread by link.
    var desktop = false
    /// Only the end of the log was read, so the turn's start may lie before it.
    var truncated = false
    var modified: Date? = nil
    var lastEvent: String? = nil
    var lastEventID: String? = nil
}
struct CodexLiveSnapshot {
    let sessions: [CodexLiveObservation]
    let openFileDiscoveryComplete: Bool
    /// Even complete open-file discovery cannot prove absence or current activity.
    let lifecycleCoverageComplete = false
}

enum CodexLiveTrackerError: Error { case invalidRoot, commandFailed, timeout, outputLimit, malformedOutput }

/// Opt-in read-only snapshot; call on a background task. No process or file writes.
struct CodexLiveTracker {
    let root: URL
    let discovery: any CodexOpenFileDiscovering
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory:true), discovery: any CodexOpenFileDiscovering = CodexLsofDiscovery()) {
        self.root = root; self.discovery = discovery
    }
    func snapshot() throws -> CodexLiveSnapshot {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard FileManager.default.isReadableFile(atPath: canonicalRoot) else { throw CodexLiveTrackerError.invalidRoot }
        let discovered = try discovery.discover()
        var records: [String: CodexLiveObservation] = [:]
        var allParsed = true
        for entry in discovered.files {
            let url = URL(fileURLWithPath: entry.path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(canonicalRoot + "/"), url.pathExtension == "jsonl" else { continue }
            guard let f = try? FileHandle(forReadingFrom: url) else { allParsed = false; continue }
            defer { try? f.close() }
            guard let head = try? f.read(upToCount: 1_048_576), let nl = head.firstIndex(of: 10),
                  let meta = Self.decode(Data(head[..<nl])), meta["type"] as? String == "session_meta",
                  let payload = meta["payload"] as? [String: Any], let id = payload["id"] as? String,
                  !id.isEmpty else { allParsed = false; continue }
            let cwd = payload["cwd"] as? String
            let isChild = payload["parent_thread_id"] != nil || payload["thread_source"] as? String == "subagent"
            let desktop = payload["originator"] as? String == "Codex Desktop"
            let size = (try? f.seekToEnd()) ?? 0
            let offset = size > 262144 ? size - 262144 : 0
            guard (try? f.seek(toOffset: offset)) != nil, let tail = try? f.read(upToCount: 262144) else { allParsed = false; continue }
            var lines = tail.split(separator: 10, omittingEmptySubsequences: false)
            if offset > 0 && !lines.isEmpty { lines.removeFirst() }
            if tail.last != 10 && !lines.isEmpty { lines.removeLast() }
            var turn = CodexObservedTurn.unknown
            var lastEvent: String?, lastEventID: String?
            for line in lines {
                guard let o = Self.decode(Data(line)), o["type"] as? String == "event_msg",
                      let payload = o["payload"] as? [String: Any], let type = payload["type"] as? String else { continue }
                switch type { case "task_started": turn = .started; case "task_complete": turn = .completed; case "turn_aborted": turn = .aborted; default: continue }
                lastEvent = type
                lastEventID = (payload["turn_id"] as? String).map { type + ":" + $0 }
            }
            if let old = records[id] {
                // Multiple processes may hold one log. If they disagree, keep the turn unknown.
                records[id] = CodexLiveObservation(sessionID:id, associatedPIDs:old.associatedPIDs.union([entry.pid]), lastRecordedTurn:old.lastRecordedTurn == turn ? turn : .unknown)
            } else {
                records[id] = CodexLiveObservation(sessionID:id, associatedPIDs:[entry.pid], lastRecordedTurn:turn)
            }
            records[id]?.cwd = cwd
            records[id]?.isChild = isChild
            records[id]?.desktop = desktop
            records[id]?.truncated = offset > 0
            records[id]?.modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            records[id]?.lastEvent = lastEvent
            records[id]?.lastEventID = lastEventID
        }
        return CodexLiveSnapshot(sessions:Array(records.values), openFileDiscoveryComplete:discovered.complete && allParsed)
    }
    private static func decode(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with:data)) as? [String: Any] }
}

/// Uses bounded `ps` / `lsof` output and never logs their content.
struct CodexLsofDiscovery: CodexOpenFileDiscovering {
    func discover() throws -> CodexOpenFileSnapshot {
        let ps = try run("/bin/ps", ["-axo", "pid=,comm="])
        var pids: [String] = []
        for line in ps.output.split(separator:"\n") {
            let parts = line.split(maxSplits:1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, Int32(parts[0]) != nil else { continue }
            let executable = String(parts[1]).trimmingCharacters(in:.whitespaces)
            if URL(fileURLWithPath:executable).lastPathComponent == "codex" { pids.append(String(parts[0])) }
        }
        guard !pids.isEmpty else { return CodexOpenFileSnapshot(files:[], complete:false) }
        guard pids.count <= 128 else { throw CodexLiveTrackerError.outputLimit }
        let response = try run("/usr/sbin/lsof", ["-n", "-F", "pfn", "-p", pids.joined(separator:",")])
        var result: [CodexOpenFile] = []
        var currentPID: Int32?; var numericFD = false
        for line in response.output.split(separator:"\n") {
            guard let kind = line.first else { continue }
            let value = String(line.dropFirst())
            switch kind {
            case "p": currentPID = Int32(value); numericFD = false
            case "f": numericFD = !value.isEmpty && value.first?.isNumber == true
            case "n":
                if numericFD, let pid = currentPID, value.hasPrefix("/"), value.hasSuffix(".jsonl") {
                    result.append(CodexOpenFile(pid:pid,path:value))
                }
                numericFD = false
            default: break
            }
        }
        // lsof may omit processes due to permission, process death, or an inaccessible mount.
        return CodexOpenFileSnapshot(files:result, complete:false)
    }
    private func run(_ executable: String, _ arguments: [String]) throws -> (output: String, exit: Int32) {
        let p = Process(); let out = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let fd = out.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(5)
        var buffer = Data(); var bytes = [UInt8](repeating:0,count:8192)
        defer { if p.isRunning { p.terminate() }; try? out.fileHandleForReading.close() }
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexLiveTrackerError.timeout }
            var descriptor = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            let ready = Darwin.poll(&descriptor,1,Int32(min(remaining * 1000,5000)))
            if ready == 0 { throw CodexLiveTrackerError.timeout }
            if ready < 0 { if errno == EINTR { continue }; throw CodexLiveTrackerError.commandFailed }
            let n = Darwin.read(fd,&bytes,bytes.count)
            if n < 0 { if errno == EINTR { continue }; throw CodexLiveTrackerError.commandFailed }
            if n == 0 { break }
            guard buffer.count + n <= 2_097_152 else { throw CodexLiveTrackerError.outputLimit }
            buffer.append(contentsOf:bytes[0..<n])
        }
        while p.isRunning {
            guard deadline.timeIntervalSinceNow > 0 else { throw CodexLiveTrackerError.timeout }
            usleep(10_000)
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 || (executable == "/usr/sbin/lsof" && p.terminationStatus == 1) else { throw CodexLiveTrackerError.commandFailed }
        guard let string = String(data:buffer,encoding:.utf8) else { throw CodexLiveTrackerError.malformedOutput }
        return (string,p.terminationStatus)
    }
}
