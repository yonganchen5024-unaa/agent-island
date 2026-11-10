import Foundation
import Combine
import Darwin

/// Receives unauthenticated, one-way event observations. Never approve actions from this channel.
@MainActor final class ClaudeSpoolReader: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "未启用"
    @Published private(set) var managedInstalled = false
    var onEvent: ((String, String, String, Date) -> Void)?
    private let store: SessionStore
    private let scanner: ClaudeSpoolScanner
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var seen: [String:TimeInterval] = [:]
    private var last: [String:TimeInterval] = [:]
    init(store:SessionStore, root:URL, spool:URL, managedSettings:URL = URL(fileURLWithPath:"/Library/Application Support/ClaudeCode/managed-settings.json")) {
        self.store = store; self.scanner = ClaudeSpoolScanner(root:root,spool:spool)
        if let data=try? Data(contentsOf:managedSettings), let config=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any], let hooks=config["hooks"] as? [String:Any], config["allowManagedHooksOnly"] as? Bool == true {
            let required=["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest","Notification","Stop","StopFailure","SessionEnd"]
            let args=["-I","/Library/Application Support/ClaudeCode/IslandReplica/managed_spool_hook.py","--target-uid",String(getuid()),"--root",root.path,"--spool",spool.path]
            managedInstalled=required.allSatisfy { event in
                guard let groups=hooks[event] as? [[String:Any]] else { return false }
                return groups.contains { group in
                    guard let handlers=group["hooks"] as? [[String:Any]] else { return false }
                    return handlers.contains { item in
                        (item["command"] as? String)=="/usr/bin/python3" && (item["args"] as? [String]) == args && ((item["statusMessage"] as? String)?.hasPrefix("IslandReplica managed observation v1") == true)
                    }
                }
            }
        }
    }
    func start() {
        guard task == nil else { return }
        enabled = true; status = "等待状态事件"; let g = UUID(); generation = g
        task = Task { [weak self,scanner] in
            while !Task.isCancelled {
                let result = await scanner.consume()
                guard let self, !Task.isCancelled, self.generation == g else { break }
                let now = Date().timeIntervalSince1970
                self.seen = self.seen.filter { now - $0.value <= 300 }
                for (id, time) in self.last where now - time > 120 { self.last.removeValue(forKey:id) }
                switch result {
                case .success(let events):
                    for ev in events {
                        guard self.seen[ev.id] == nil, ev.time >= now-120, ev.time <= now+10,
                              ev.time >= (self.last[ev.sessionID] ?? 0) else { continue }
                        guard self.seen.count < 2048, self.last[ev.sessionID] != nil || self.last.count < 512 else { continue }
                        self.seen[ev.id] = now; self.last[ev.sessionID] = ev.time
                        if ClaudeProbeSessions.isProbe(ev.sessionID) { continue }
                        self.onEvent?(ev.event, ev.detail, ev.id, Date(timeIntervalSince1970:ev.time))
                        self.store.observeClaude(sessionID:ev.sessionID, event:ev.event, notification:ev.notification, at:Date(timeIntervalSince1970:ev.time))
                    }
                    self.status = "等待状态事件"
                case .failure: self.status = "事件目录不可用"
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; enabled = false; status = "未启用"
        seen.removeAll(); last.removeAll()
    }
}

private struct ClaudeSpoolEvent {
    let id:String; let sessionID:String; let event:String; let time:TimeInterval; let detail:String; let notification:String?
}
private enum ClaudeSpoolError: Error { case invalid, unavailable, oversized, malformed }
private actor ClaudeSpoolScanner {
    private let root:URL; private let spool:URL
    private let allowed:Set<String> = ["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest","Notification","Stop","StopFailure","SessionEnd"]
    init(root:URL,spool:URL) { self.root=root; self.spool=spool }
    func consume() -> Result<[ClaudeSpoolEvent],Error> {
        do {
            let rootPath=root.path, spoolPath=spool.path
            guard rootPath.hasPrefix("/"), rootPath != "/", spoolPath.hasPrefix(rootPath + "/") else { throw ClaudeSpoolError.invalid }
            let rootParts = try components(rootPath); let subParts = try components(String(spoolPath.dropFirst(rootPath.count)))
            var dfd = open("/",O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard dfd >= 0 else { throw ClaudeSpoolError.unavailable }
            defer { close(dfd) }
            for part in rootParts + subParts {
                let next = openat(dfd,part,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ClaudeSpoolError.unavailable }
                close(dfd); dfd = next
            }
            var ds=stat(); guard fstat(dfd,&ds) == 0, ds.st_uid == getuid(), ds.st_mode & 0o077 == 0 else { throw ClaudeSpoolError.invalid }
            let fd = openat(dfd,"events.ndjson",O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if fd < 0 && errno == ENOENT { return .success([]) }
            guard fd >= 0 else { throw ClaudeSpoolError.unavailable }; defer { close(fd) }
            var st=stat(); guard fstat(fd,&st) == 0, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), st.st_uid == getuid(), st.st_mode & 0o077 == 0, st.st_nlink == 1 else { throw ClaudeSpoolError.invalid }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return .success([]) }; defer { flock(fd,LOCK_UN) }
            guard fstat(fd,&st) == 0, st.st_size >= 0, st.st_size <= 262144 else { throw ClaudeSpoolError.oversized }
            let size = Int(st.st_size); if size == 0 { return .success([]) }
            var bytes=[UInt8](repeating:0,count:size), pos=0
            while pos < size {
                let n = bytes.withUnsafeMutableBytes { raw in Darwin.read(fd, raw.baseAddress!.advanced(by:pos), size-pos) }
                guard n > 0 else { throw ClaudeSpoolError.unavailable }; pos += n
            }
            guard bytes.last == 10 else { throw ClaudeSpoolError.malformed }
            var events:[ClaudeSpoolEvent] = []
            for line in Data(bytes).split(separator:10,omittingEmptySubsequences:true) {
                guard let obj = (try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any],
                      Set(obj.keys).isSubset(of:["v","id","session_id","event","time","notification_type"]),
                      let version=obj["v"] as? Int, version == 1,
                      let id=obj["id"] as? String, UUID(uuidString:id) != nil,
                      let sid=obj["session_id"] as? String, UUID(uuidString:sid) != nil,
                      let event=obj["event"] as? String, allowed.contains(event),
                      let timestamp=obj["time"] as? Double, timestamp.isFinite else { throw ClaudeSpoolError.malformed }
                let detail:String
                if event == "Notification" {
                    guard let kind=obj["notification_type"] as? String,
                          ["permission_prompt","idle_prompt","elicitation_dialog","elicitation_url_dialog"].contains(kind) else { throw ClaudeSpoolError.malformed }
                    switch kind {
                    case "permission_prompt": detail = "收到权限提示"
                    case "idle_prompt": detail = "收到空闲提醒"
                    default: detail = "收到提问"
                    }
                } else {
                    switch event {
                    case "PermissionRequest": detail = "收到权限请求"
                    case "SessionStart": detail = "会话开始"
                    case "SessionEnd": detail = "会话结束"
                    case "Stop": detail = "本轮结束"
                    case "StopFailure": detail = "本轮异常结束"
                    case "UserPromptSubmit": detail = "本轮开始"
                    default: detail = "收到工具事件"
                    }
                }
                events.append(ClaudeSpoolEvent(id:id.lowercased(),sessionID:sid.lowercased(),event:event,time:timestamp,detail:detail,notification:obj["notification_type"] as? String))
            }
            guard ftruncate(fd,0) == 0 else { throw ClaudeSpoolError.unavailable }
            return .success(events)
        } catch { return .failure(error) }
    }
    private func components(_ path:String) throws -> [String] {
        let result=path.split(separator:"/",omittingEmptySubsequences:true).map(String.init)
        guard !result.contains(where: { $0 == "." || $0 == ".." }) else { throw ClaudeSpoolError.invalid }
        return result
    }
}
