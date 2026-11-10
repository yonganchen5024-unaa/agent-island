import Foundation
import Darwin
@main struct Check {
 @MainActor static func main() async throws {
  let tmp = FileManager.default.temporaryDirectory.path
  let safeTmp = tmp.hasPrefix("/var/") ? "/private" + tmp : tmp
  let base = URL(fileURLWithPath:safeTmp).appendingPathComponent("spool-"+UUID().uuidString)
  let spool=base.appendingPathComponent("queue"); try FileManager.default.createDirectory(at:spool,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); chmod(base.path,0o700)
  defer { try? FileManager.default.removeItem(at:base) }
  let id="6a23744f-577f-4da6-9c19-66035cd2a001", script=URL(fileURLWithPath:CommandLine.arguments[1])
  let proc=Process(), input=Pipe(); proc.executableURL=URL(fileURLWithPath:"/usr/bin/python3"); proc.arguments=[script.path,"--root",base.path,"--spool",spool.path];proc.standardInput=input;proc.standardOutput=FileHandle.nullDevice;proc.standardError=FileHandle.nullDevice;try proc.run()
  let payload="{\"session_id\":\"\(id)\",\"hook_event_name\":\"PermissionRequest\",\"prompt\":\"sensitive-fixture\"}"
  try input.fileHandleForWriting.write(contentsOf:Data(payload.utf8));try input.fileHandleForWriting.close();proc.waitUntilExit(); precondition(proc.terminationStatus == 0)
  let file=spool.appendingPathComponent("events.ndjson"), bytes=try Data(contentsOf:file)
  precondition(!String(decoding:bytes,as:UTF8.self).contains("sensitive-fixture"))
  let store=SessionStore(demo:false)
  let suite="island-spool-sound-" + UUID().uuidString, defaults=UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  var cues:[IslandSoundCue] = []
  let sound=SoundManager(store:store,defaults:defaults) { cue,_ in cues.append(cue) }
  sound.enabled=true
  let reader=ClaudeSpoolReader(store:store,root:base,spool:spool,managedSettings:base.appendingPathComponent("managed-settings.json"))
  reader.onEvent = { event,detail,_,_ in sound.emitClaudeObservation(event:event,detail:detail) }
  reader.start()
  for _ in 0..<60 { if store.sessions.count == 1 { break }; try await Task.sleep(nanoseconds:100_000_000) }
  precondition(store.sessions.count == 1 && store.sessions[0].id == "claude:"+id && store.sessions[0].status == .waiting)
  precondition(cues == [.waiting], "live permission observation should emit one waiting cue")
  let firstTime=store.sessions[0].updatedAt, now=Date().timeIntervalSince1970
  let stale="{\"v\":1,\"id\":\"\(UUID().uuidString)\",\"session_id\":\"\(id)\",\"event\":\"Stop\",\"time\":\(now-200)}\n"
  try stale.write(to:file,atomically:false,encoding:.utf8)
  try await Task.sleep(nanoseconds:1_500_000_000)
  precondition(store.sessions.count == 1 && store.sessions[0].updatedAt == firstTime, "stale event must not update")
  var duplicate = (try JSONSerialization.jsonObject(with:bytes)) as! [String:Any]
  duplicate["time"] = now + 2
  var duplicateData = try JSONSerialization.data(withJSONObject:duplicate); duplicateData.append(10)
  try duplicateData.write(to:file)
  try await Task.sleep(nanoseconds:1_500_000_000)
  precondition(store.sessions.count == 1 && store.sessions[0].updatedAt == firstTime, "duplicate event must not update")
  precondition(cues == [.waiting], "duplicate and stale events must not replay sound")
  let end="{\"v\":1,\"id\":\"\(UUID().uuidString)\",\"session_id\":\"\(id)\",\"event\":\"SessionEnd\",\"time\":\(Date().timeIntervalSince1970)}\n"
  try end.write(to:file,atomically:false,encoding:.utf8)
  for _ in 0..<30 { if store.sessions.isEmpty { break }; try await Task.sleep(nanoseconds:100_000_000) }
  precondition(store.sessions.isEmpty, "SessionEnd must remove own row")
  reader.stop();precondition(store.sessions.isEmpty)
  print("spool hook to reader: PASS; stale and duplicates ignored, end removed, no sensitive data")
 }
}
