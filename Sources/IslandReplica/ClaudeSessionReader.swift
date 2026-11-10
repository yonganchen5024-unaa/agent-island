import Foundation
import Combine
import Darwin

struct ClaudeFileAssociations {
    let paths: Set<String>
    /// False means lack of an association is not evidence of absence.
    let complete: Bool
}
protocol ClaudeProcessDiscovering {
    func discover() throws -> ClaudeFileAssociations
}

/// Optional read-only Claude Code session history. No configuration writes, model calls,
/// raw transcript storage, or claims about current turn/approval activity.
@MainActor final class ClaudeSessionReader: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "未连接"
    private let store: SessionStore
    private let scanner: ClaudeSessionScanner
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(store: SessionStore, root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects",isDirectory:true), discovery: any ClaudeProcessDiscovering = ClaudeLsofDiscovery()) {
        self.store = store
        self.scanner = ClaudeSessionScanner(root: root, discovery: discovery)
    }
    func start() {
        guard task == nil else { return }
        enabled = true; status = "正在读取本机会话…"
        let id = UUID(); generation = id
        task = Task { [weak self, scanner] in
            while !Task.isCancelled {
                let result = await scanner.scan()
                guard let self, !Task.isCancelled, self.generation == id else { break }
                switch result {
                case .success(let rows):
                    self.store.mergeClaudeHistory(rows)
                    self.status = "已读取 \(rows.count) 个近期会话；运行状态待确认"
                case .failure:
                    self.store.mergeClaudeHistory([])
                    self.status = "无法读取 Claude 会话目录"
                }
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
            }
        }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; enabled = false; status = "未连接"
        store.mergeClaudeHistory([])
        Task { await scanner.clear() }
    }
}

private actor ClaudeSessionScanner {
    private struct Cached { let size: UInt64; let modified: Date; let record: ClaudeRecord }
    private let root: URL
    private let discovery: any ClaudeProcessDiscovering
    private var cache: [String: Cached] = [:]
    private var lastDiscovery: Date?
    private var cachedOpenPaths = Set<String>()
    init(root:URL, discovery: any ClaudeProcessDiscovering) { self.root = root; self.discovery = discovery }
    func clear() { cache.removeAll(); cachedOpenPaths.removeAll(); lastDiscovery = nil }
    func scan() -> Result<[SessionItem], Error> {
        do {
            let fm = FileManager.default, base = root.standardizedFileURL.resolvingSymlinksInPath()
            guard fm.isReadableFile(atPath: base.path) else { throw ClaudeReaderError.unreadable }
            let keys: Set<URLResourceKey> = [.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.contentModificationDateKey,.fileSizeKey]
            let dirs = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys:Array(keys), options:[.skipsHiddenFiles])
            var candidates: [(URL, Date, UInt64)] = []; let cutoff = Date().addingTimeInterval(-7*86400)
            for dir in dirs.prefix(5000) {
                guard let values = try? dir.resourceValues(forKeys:keys), values.isDirectory == true, values.isSymbolicLink != true,
                      let children = try? fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:Array(keys),options:[.skipsHiddenFiles]) else { continue }
                for url in children {
                    guard url.pathExtension == "jsonl", UUID(uuidString:url.deletingPathExtension().lastPathComponent) != nil,
                          let v = try? url.resourceValues(forKeys:keys), v.isRegularFile == true, v.isSymbolicLink != true,
                          let m = v.contentModificationDate, m >= cutoff, let size = v.fileSize, size > 0 else { continue }
                    candidates.append((url,m,UInt64(size)))
                }
            }
            candidates.sort { $0.1 > $1.1 }; candidates = Array(candidates.prefix(30))
            if lastDiscovery.map({ Date().timeIntervalSince($0) >= 20 }) ?? true {
                cachedOpenPaths = (try? discovery.discover().paths) ?? []
                lastDiscovery = Date()
            }
            let openPaths = cachedOpenPaths
            var result: [SessionItem] = []; var next: [String: Cached] = [:]; var seen = Set<String>()
            for (url, modified, size) in candidates {
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard path.hasPrefix(base.path + "/") else { continue }
                let rec: ClaudeRecord
                if let old = cache[path], old.size == size, old.modified == modified { rec = old.record }
                else { guard let new = Self.parse(url:url,size:size) else { continue }; rec = new }
                next[path] = Cached(size:size,modified:modified,record:rec)
                guard seen.insert(rec.id).inserted else { continue }
                let hint = openPaths.contains(path) ? "最近发现关联进程，运行状态待确认" : "运行状态待确认"
                result.append(SessionItem(id:"claude:"+rec.id,title:rec.title,agent:"Claude Code",status:.unknown,detail:"\(rec.event) · \(hint)",updatedAt:modified))
            }
            cache = next
            return .success(result)
        } catch { cache.removeAll(); return .failure(error) }
    }
    private static func parse(url:URL,size:UInt64) -> ClaudeRecord? {
        let fileID = url.deletingPathExtension().lastPathComponent
        guard let f = try? FileHandle(forReadingFrom:url) else { return nil }; defer { try? f.close() }
        let off = size > 262144 ? size - 262144 : 0
        guard (try? f.seek(toOffset:off)) != nil, let data = try? f.read(upToCount:262144) else { return nil }
        var lines = data.split(separator:10,omittingEmptySubsequences:false)
        if off > 0 && !lines.isEmpty { lines.removeFirst() }
        if data.last != 10 && !lines.isEmpty { lines.removeLast() }
        var event = "最近事件未知", title = "Claude 会话", verified = false
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any],
                  let sid = obj["sessionId"] as? String, sid.caseInsensitiveCompare(fileID) == .orderedSame else { continue }
            verified = true
            if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                let name = URL(fileURLWithPath:cwd).lastPathComponent
                if !name.isEmpty && name != "/" { title = name }
            }
            let message = obj["message"] as? [String:Any]
            let blocks = message?["content"] as? [[String:Any]] ?? []
            let types = Set(blocks.compactMap { $0["type"] as? String })
            switch obj["type"] as? String {
            case "user": event = types.contains("tool_result") ? "最近事件：工具结果" : "最近事件：用户输入"
            case "assistant":
                if message?["stop_reason"] as? String == "end_turn" { event = "最近事件：本轮结束" }
                else if types.contains("tool_use") || message?["stop_reason"] as? String == "tool_use" { event = "最近事件：请求工具" }
                else { event = "最近事件：助手输出" }
            case "system": event = "最近事件：系统事件"
            default: break
            }
        }
        return verified ? ClaudeRecord(id:fileID,title:title,event:event) : nil
    }
}
private struct ClaudeRecord { let id:String; let title:String; let event:String }
private enum ClaudeReaderError: Error { case unreadable, timeout, invalid }

/// Best-effort process/open-file observation. It doesn't prove a turn is running.
struct ClaudeLsofDiscovery: ClaudeProcessDiscovering {
    func discover() throws -> ClaudeFileAssociations {
        let output = try run("/bin/ps",["-axo","pid=,comm="])
        let pids = output.split(separator:"\n").compactMap { line -> String? in
            let parts = line.split(maxSplits:1,whereSeparator:{ $0 == " " || $0 == "\t" })
            guard parts.count == 2, Int32(parts[0]) != nil else { return nil }
            let name = URL(fileURLWithPath:String(parts[1]).trimmingCharacters(in:.whitespaces)).lastPathComponent
            return name == "claude" ? String(parts[0]) : nil
        }
        guard !pids.isEmpty, pids.count <= 128 else { return ClaudeFileAssociations(paths:[],complete:false) }
        let raw = try run("/usr/sbin/lsof",["-n","-F","pfn","-p",pids.joined(separator:",")],allowOne:true)
        var paths = Set<String>(); var numericFD = false
        for line in raw.split(separator:"\n") {
            guard let k = line.first else { continue }; let value = String(line.dropFirst())
            switch k {
            case "p": numericFD = false
            case "f": numericFD = value.first?.isNumber == true
            case "n":
                if numericFD && value.hasPrefix("/") && value.hasSuffix(".jsonl") { paths.insert(URL(fileURLWithPath:value).standardizedFileURL.resolvingSymlinksInPath().path) }
                numericFD = false
            default: break
            }
        }
        return ClaudeFileAssociations(paths:paths,complete:false)
    }
    private func run(_ command:String,_ args:[String],allowOne:Bool = false) throws -> String {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath:command); p.arguments = args
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; try p.run()
        defer { if p.isRunning { p.terminate() }; try? pipe.fileHandleForReading.close() }
        let fd = pipe.fileHandleForReading.fileDescriptor, deadline = Date().addingTimeInterval(4)
        var data = Data(), bytes = [UInt8](repeating:0,count:8192)
        while true {
            let remaining = deadline.timeIntervalSinceNow; guard remaining > 0 else { throw ClaudeReaderError.timeout }
            var descriptor = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            let ready = Darwin.poll(&descriptor,1,Int32(min(remaining*1000,4000)))
            if ready == 0 { throw ClaudeReaderError.timeout }
            if ready < 0 { if errno == EINTR { continue }; throw ClaudeReaderError.invalid }
            let n = Darwin.read(fd,&bytes,bytes.count)
            if n < 0 { if errno == EINTR { continue }; throw ClaudeReaderError.invalid }
            if n == 0 { break }
            guard data.count + n <= 2_097_152 else { throw ClaudeReaderError.invalid }
            data.append(contentsOf:bytes[0..<n])
        }
        while p.isRunning { guard deadline.timeIntervalSinceNow > 0 else { throw ClaudeReaderError.timeout }; usleep(10000) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 || (allowOne && p.terminationStatus == 1), let result = String(data:data,encoding:.utf8) else { throw ClaudeReaderError.invalid }
        return result
    }
}
