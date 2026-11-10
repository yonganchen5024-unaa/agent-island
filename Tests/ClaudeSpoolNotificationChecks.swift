import Foundation
@MainActor final class FakeNotice: IslandNotificationTransport {
 var messages:[String]=[]
 func requestPermission() async throws -> Bool { true }
 func send(body:String) async throws { messages.append(body) }
}
@main struct Checks {
 @MainActor static func main() async throws {
  let tmp=FileManager.default.temporaryDirectory.path
  let base=URL(fileURLWithPath:tmp.hasPrefix("/var/") ? "/private"+tmp : tmp).appendingPathComponent("notice-"+UUID().uuidString)
  let dir=base.appendingPathComponent("spool")
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  chmod(base.path,0o700)
  defer { try? FileManager.default.removeItem(at:base) }
  let store=SessionStore(demo:false), transport=FakeNotice(), notifications=NotificationManager(transport:transport)
  notifications.requestPermissionAndEnable()
  try await Task.sleep(nanoseconds:100_000_000)
  precondition(notifications.enabled)
  let reader=ClaudeSpoolReader(store:store,root:base,spool:dir,managedSettings:base.appendingPathComponent("none"))
  reader.onEvent={ event,detail,id,date in notifications.emitObservedClaudeEvent(id:id,event:event,detail:detail,happenedAt:date) }
  reader.start()
  let p=Process(), input=Pipe(); p.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
  p.arguments=[CommandLine.arguments[1],"--root",base.path,"--spool",dir.path]
  p.standardInput=input;p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
  try p.run(); try input.fileHandleForWriting.write(contentsOf:Data("{\"session_id\":\"11111111-1111-4111-8111-111111111111\",\"hook_event_name\":\"PermissionRequest\",\"prompt\":\"do-not-display\"}".utf8));try input.fileHandleForWriting.close();p.waitUntilExit()
  for _ in 0..<40 { if !transport.messages.isEmpty { break }; try await Task.sleep(nanoseconds:100_000_000) }
  precondition(transport.messages == ["Claude Code 检测到等待事件，请核实。"])
  reader.stop();notifications.disable()
  print("Claude spool -> opt-in privacy-safe notification: PASS")
 }
}
