import Foundation
@main struct ClaudeObserverChecks {
 @MainActor static func main() async throws {
  let project = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("island-observe-"+String(UUID().uuidString.prefix(8)))
  defer { try? FileManager.default.removeItem(at:root) }
  let store=SessionStore(demo:false)
  let bridge=ClaudeObserverBridge(store:store,script:project.appendingPathComponent("scripts/claude_observe_broker.py"),runtime:root,settings:root.appendingPathComponent("settings.json"))
  bridge.start()
  for _ in 0..<50 { if bridge.state == .ready { break }; try await Task.sleep(nanoseconds:100_000_000) }
  precondition(bridge.state == .ready)
  func send(_ name:String) throws {
   let p=Process(), input=Pipe(), out=Pipe()
   p.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
   p.arguments=[project.appendingPathComponent("scripts/claude_observe_hook.py").path,"--runtime-dir",root.path]
   p.standardInput=input;p.standardOutput=out;p.standardError=FileHandle.nullDevice
   try p.run()
   let data=try JSONSerialization.data(withJSONObject:["session_id":"fixture123","hook_event_name":name,"prompt":"secret-text-must-not-display"])
   try input.fileHandleForWriting.write(contentsOf:data);try input.fileHandleForWriting.close();p.waitUntilExit()
   precondition(p.terminationStatus == 0 && out.fileHandleForReading.readDataToEndOfFile().isEmpty)
  }
  try send("UserPromptSubmit")
  try await Task.sleep(nanoseconds:300_000_000)
  precondition(store.sessions.count == 1 && store.sessions[0].status == .working && !store.sessions[0].detail.contains("secret-text"))
  try send("PermissionRequest")
  try await Task.sleep(nanoseconds:300_000_000)
  precondition(store.sessions.first?.status == .waiting)
  let h=SessionItem(id:"claude:fixture123",title:"fixture",agent:"Claude Code",status:.unknown,detail:"history",updatedAt:Date())
  store.mergeClaudeHistory([h]); precondition(store.sessions.first?.status == .waiting)
  try send("SessionEnd");try await Task.sleep(nanoseconds:300_000_000)
  store.mergeClaudeHistory([h]); precondition(store.sessions.isEmpty)
  bridge.stop()
  print("Claude observer: broker, privacy, lifecycle, history merge, stop PASS")
 }
}
