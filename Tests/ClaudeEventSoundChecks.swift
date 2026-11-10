import Foundation

// Compile with SessionStore.swift, SoundManager.swift and Builtin8BitSynth.swift.
// Each Claude event reaches the intended cue. A fresh manager avoids the 1.5 s rate limit.
@main struct ClaudeEventSoundChecks {
    @MainActor static func cue(for event: String, detail: String = "") -> IslandSoundCue? {
        let defaults = UserDefaults(suiteName: "island.sound.check.\(UUID().uuidString)")!
        defaults.set(true, forKey: "islandSoundEnabled")
        defaults.set([String](), forKey: "islandDisabledSoundCues")
        var played: IslandSoundCue?
        let manager = SoundManager(store: SessionStore(demo: false), defaults: defaults, play: { cue, _ in played = cue })
        manager.emitClaudeObservation(event: event, detail: detail)
        return played
    }
    @MainActor static func main() {
        precondition(cue(for: "SessionStart") == .sessionStarted)
        precondition(cue(for: "UserPromptSubmit") == .acknowledged)
        precondition(cue(for: "Stop") == .completed)
        precondition(cue(for: "StopFailure") == .failed)
        precondition(cue(for: "PermissionRequest") == .waiting)
        precondition(cue(for: "Notification", detail: "收到权限提示") == .waiting)
        precondition(cue(for: "Notification", detail: "收到空闲提醒") == .idleReminder)
        precondition(cue(for: "Notification", detail: "收到提问") == .question)
        precondition(cue(for: "PreToolUse") == nil)
        print("ClaudeEventSoundChecks passed")
    }
}
