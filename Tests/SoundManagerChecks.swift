import Foundation

@main struct SoundManagerChecks {
    @MainActor static func main() {
        let now = Date()
        func session(_ id: String, _ status: SessionStatus) -> SessionItem {
            SessionItem(id: id, title: "fixture", agent: "fixture", status: status, detail: "", updatedAt: now)
        }
        var transitions = IslandSoundTransitions()
        precondition(transitions.update([session("demo-1", .working)]) == nil)
        precondition(transitions.update([session("demo-1", .waiting)]) == nil)
        precondition(transitions.update([session("x", .working)]) == .sessionStarted)
        precondition(transitions.update([session("x", .working)]) == nil)
        precondition(transitions.update([session("x", .waiting)]) == .waiting)
        precondition(transitions.update([session("x", .working)]) == nil)
        precondition(transitions.update([session("x", .idle)]) == .completed)
        precondition(transitions.update([session("x", .error)]) == .failed)
        precondition(transitions.update([]) == nil)
        var logTransitions = IslandSoundTransitions()
        var log = session("rollout:fixture", .unknown)
        log.lifecycle = "task_started"; log.lifecycleID = "task_started:turn1"
        precondition(logTransitions.update([log]) == nil)
        precondition(logTransitions.update([log]) == nil)
        log.lifecycle = "task_complete"; log.lifecycleID = "task_complete:turn1"
        precondition(logTransitions.update([log]) == .completed)
        precondition(logTransitions.update([log]) == nil)
        log.lifecycle = "task_started"; log.lifecycleID = "task_started:turn2"
        precondition(logTransitions.update([log]) == .sessionStarted)
        let suite = "local.island.sound-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(demo: false)
        var played: [(IslandSoundCue, Float)] = []
        let sounds = SoundManager(store: store, defaults: defaults) { cue, volume in played.append((cue, volume)) }
        store.ingest(SessionEvent(sessionId:"a",event:"working",agent:nil,title:nil,detail:nil))
        precondition(played.isEmpty)
        sounds.volume = 0.25
        sounds.preview()
        precondition(played.count == 1 && played[0].0 == .completed && played[0].1 == 0.25)
        played.removeAll()
        sounds.enabled = true
        sounds.setEnabled(false, for: .waiting)
        store.ingest(SessionEvent(sessionId:"a",event:"PermissionRequest",agent:nil,title:nil,detail:nil))
        precondition(played.isEmpty)
        sounds.setEnabled(true, for: .waiting)
        store.ingest(SessionEvent(sessionId:"a",event:"working",agent:nil,title:nil,detail:nil))
        store.ingest(SessionEvent(sessionId:"a",event:"PermissionRequest",agent:nil,title:nil,detail:nil))
        precondition(played.count == 1 && played[0].0 == .waiting)
        sounds.volume = 4
        precondition(sounds.volume == 1)
        print("sound transitions, disabled default, preview, volume: PASS")
    }
}
