import Foundation
import Combine

/// Local observer only. It never makes or forwards approval decisions.
@MainActor final class ClaudeObserverBridge: ObservableObject {
    enum State: Equatable { case stopped, starting, ready, failed(String) }
    @Published private(set) var state: State = .stopped
    @Published private(set) var hookConfigured = false
    @Published private(set) var managedHooksOnly = false
    @Published private(set) var configurationMessage: String?
    @Published private(set) var configurationBusy = false
    @Published private(set) var receivedCount = 0
    @Published private(set) var lastEventName: String?
    private let store: SessionStore
    private let script: URL
    let runtime: URL
    private let settings: URL
    private let defaults: UserDefaults
    private let configScript: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var generation = UUID()
    private var buffer = Data()
    private let maxBytes = 65_536

    init(store: SessionStore, script: URL, runtime: URL, settings: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"), defaults: UserDefaults = .standard, configScript: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Island/claude-observer-v1/claude_observe_config.py")) {
        self.store=store; self.script=script; self.runtime=runtime; self.settings=settings; self.defaults=defaults; self.configScript=configScript; refreshConfiguration()
    }
    func refreshConfiguration() {
        let managed = URL(fileURLWithPath:"/Library/Application Support/ClaudeCode/managed-settings.json")
        if let data=try? Data(contentsOf:managed), let obj=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
            managedHooksOnly = obj["allowManagedHooksOnly"] as? Bool == true
        } else { managedHooksOnly = false }
        let hook = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Island/claude-observer-v1/claude_observe_hook.py").path
        guard let data=try? Data(contentsOf:settings), let root=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any], let hooks=root["hooks"] as? [String:Any] else { hookConfigured=false; return }
        let required=["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest","Notification","Stop","StopFailure","SessionEnd"]
        hookConfigured = required.allSatisfy { name in
            guard let groups=hooks[name] as? [[String:Any]] else { return false }
            return groups.contains { group in
                guard let handlers=group["hooks"] as? [[String:Any]] else { return false }
                return handlers.contains { h in
                    guard h["command"] as? String == "/usr/bin/python3", let args=h["args"] as? [String], args == [hook,"--runtime-dir",runtime.path], let marker=h["statusMessage"] as? String else { return false }
                    return marker.hasPrefix("IslandReplica Claude observer")
                }
            }
        }
    }
    /// User-initiated removal of only this app's observer hooks; the script backs up settings.
    func removeConfiguredHooks() {
        guard !configurationBusy else { return }
        stop(); defaults.set(false, forKey:"claudeObserverEnabled")
        configurationBusy = true; configurationMessage = "正在移除观察 Hook…"
        let script = self.configScript
        let settings = self.settings
        Task { [weak self] in
            let succeeded = await Task.detached(priority:.utility) {
                guard FileManager.default.isReadableFile(atPath:script.path) else { return false }
                let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
                process.arguments=[script.path,"--settings",settings.path,"remove"]
                process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
                do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
                catch { return false }
            }.value
            guard let self else { return }
            self.configurationBusy = false; self.refreshConfiguration()
            self.configurationMessage = succeeded && !self.hookConfigured ? "观察 Hook 已移除，原配置已备份" : "移除未完成，请检查配置"
        }
    }
    func start() {
        guard process == nil else { return }
        guard FileManager.default.isReadableFile(atPath:script.path) else { state = .failed("实时桥文件不可用"); return }
        let id=UUID(); generation=id; buffer=Data(); state = .starting
        let p=Process(), stdinPipe=Pipe(), stdoutPipe=Pipe()
        p.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        p.arguments=["-u",script.path,"--runtime-dir",runtime.path]
        p.standardInput=stdinPipe; p.standardOutput=stdoutPipe; p.standardError=FileHandle.nullDevice
        p.terminationHandler={ [weak self] _ in DispatchQueue.main.async { [weak self] in self?.ended(id) } }
        stdoutPipe.fileHandleForReading.readabilityHandler={ [weak self] handle in
            let data=handle.availableData
            DispatchQueue.main.async { [weak self] in self?.receive(data,id:id) }
        }
        do { try p.run(); process=p; input=stdinPipe.fileHandleForWriting; output=stdoutPipe.fileHandleForReading }
        catch { stdoutPipe.fileHandleForReading.readabilityHandler=nil; try? stdinPipe.fileHandleForWriting.close(); try? stdoutPipe.fileHandleForReading.close(); state = .failed("实时桥无法启动") }
    }
    func stop() {
        generation=UUID(); output?.readabilityHandler=nil
        try? input?.close(); try? output?.close()
        if let process, process.isRunning { process.terminate() }
        process=nil; input=nil; output=nil; buffer=Data(); store.clearClaudeObservations(); state = .stopped
    }
    private func ended(_ id:UUID) {
        guard id==generation else { return }
        output?.readabilityHandler=nil; try? input?.close(); try? output?.close()
        process=nil; input=nil; output=nil; buffer=Data(); store.clearClaudeObservations()
        state = .failed("实时桥已停止")
    }
    private func receive(_ data:Data,id:UUID) {
        guard id==generation, !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= maxBytes else { stop(); state = .failed("实时桥消息过大"); return }
        while let end=buffer.firstIndex(of:10) {
            let line=Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let obj=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any], let kind=obj["type"] as? String else { continue }
            if kind=="ready" { state = .ready; continue }
            guard kind=="claude_event", state == .ready, let sid=obj["session_id"] as? String, let event=obj["event"] as? String,
                  let ms=obj["timestamp_ms"] as? Double, obj["is_subagent"] as? Bool == false else { continue }
            store.observeClaude(sessionID:sid,event:event,notification:obj["notification_type"] as? String,at:Date(timeIntervalSince1970:ms/1000))
            receivedCount += 1; lastEventName = event
        }
    }
}
