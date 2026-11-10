import Foundation
@main struct CodexSoundIntegrationChecks {
 @MainActor static func main() async throws {
  let fm = FileManager.default
  let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fm.createDirectory(at: dir, withIntermediateDirectories:true)
  defer { try? fm.removeItem(at:dir) }
  let file = dir.appendingPathComponent("fixture.jsonl")
  let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"fixture\",\"cwd\":\"/tmp/demo\"}}\n"
  let start = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn1\"}}\n"
  let end = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn1\"}}\n"
  try (meta + start).write(to:file,atomically:true,encoding:.utf8)
  let defaults = UserDefaults(suiteName: "island-sound-integration-" + UUID().uuidString)!
  let store = SessionStore(demo:false)
  var events:[IslandSoundCue] = []
  let sound = SoundManager(store:store,defaults:defaults) { cue,_ in events.append(cue) }
  sound.enabled = true
  let reader = CodexRolloutReader(store:store,root:dir); reader.start()
  try await Task.sleep(nanoseconds:1_000_000_000)
  precondition(store.sessions.count == 1 && events.isEmpty)
  let handle = try FileHandle(forWritingTo:file); try handle.seekToEnd(); try handle.write(contentsOf:Data(end.utf8)); try handle.close()
  try await Task.sleep(nanoseconds:5_300_000_000)
  precondition(events == [.completed])
  precondition(store.sessions[0].status == .unknown)
  reader.stop()
  print("Codex log event -> sound transition: PASS")
 }
}
