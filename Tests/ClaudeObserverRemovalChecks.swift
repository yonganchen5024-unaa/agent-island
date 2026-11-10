import Foundation
@main struct Checks {
 @MainActor static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("island-removal-"+String(UUID().uuidString.prefix(8)))
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:root) }
  let settings=root.appendingPathComponent("settings.json"), runtime=root.appendingPathComponent("runtime")
  let original="{\"other\":true,\"hooks\":{\"PermissionRequest\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo harmless\"}]}]}}"
  try original.write(to:settings,atomically:true,encoding:.utf8)
  let config=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Island/claude-observer-v1/claude_observe_config.py")
  let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/python3");p.arguments=[config.path,"--settings",settings.path,"--runtime-dir",runtime.path,"install"];p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try p.run();p.waitUntilExit();precondition(p.terminationStatus == 0)
  let suite="test.island.removal."+UUID().uuidString, defaults=UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  let store=SessionStore(demo:false), bridge=ClaudeObserverBridge(store:store,script:root.appendingPathComponent("missing.py"),runtime:runtime,settings:settings,defaults:defaults,configScript:config)
  precondition(bridge.hookConfigured)
  bridge.removeConfiguredHooks()
  for _ in 0..<50 { if !bridge.configurationBusy { break }; try await Task.sleep(nanoseconds:100_000_000) }
  precondition(!bridge.configurationBusy && !bridge.hookConfigured)
  let a=try JSONSerialization.jsonObject(with:Data(original.utf8)) as! NSDictionary
  let b=try JSONSerialization.jsonObject(with:Data(contentsOf:settings)) as! NSDictionary
  precondition(a == b)
  print("Claude observer removal preserves existing hooks: PASS")
 }
}
