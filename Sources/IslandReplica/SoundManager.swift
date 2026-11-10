import AppKit
import Combine
import Foundation

enum IslandSoundCue: String, CaseIterable, Identifiable {
    case sessionStarted, acknowledged, completed, failed, waiting, question, resourceLimit, userSpam, idleReminder, usageWarning, usageReset, resetCard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sessionStarted: return "会话开始"
        case .acknowledged: return "任务确认"
        case .completed: return "任务完成"
        case .failed: return "任务错误"
        case .waiting: return "需要审批"
        case .question: return "回答问题"
        case .resourceLimit: return "上下文限制"
        case .userSpam: return "连续提交"
        case .idleReminder: return "闲置提醒"
        case .usageWarning: return "额度即将用完"
        case .usageReset: return "额度已刷新"
        case .resetCard: return "重置卡到账"
        }
    }
}

/// Pure transition state. The first snapshot primes it without playing sounds.
/// Unknown status and removed sessions do not invent completions.
struct IslandSoundTransitions {
    private var previous: [String: SessionStatus]?
    private var previousLifecycle: [String: String] = [:]

    mutating func update(_ sessions: [SessionItem]) -> IslandSoundCue? {
        var next: [String: SessionStatus] = [:]
        var nextLifecycle: [String: String] = [:]
        for item in sessions where !item.id.hasPrefix("demo-") { next[item.id] = item.status }
        for item in sessions where item.id.hasPrefix("rollout:") {
            if let id = item.lifecycleID { nextLifecycle[item.id] = id }
        }
        guard let previous else { self.previous = next; self.previousLifecycle = nextLifecycle; return nil }
        let priorLifecycle = previousLifecycle
        previousLifecycle = nextLifecycle
        self.previous = next
        var candidates = Set<Int>()
        for item in sessions where item.id.hasPrefix("rollout:") {
            guard previous[item.id] != nil, let id = item.lifecycleID, let old = priorLifecycle[item.id], id != old else { continue }
            switch item.lifecycle {
            case "task_started": candidates.insert(1)
            case "task_complete": candidates.insert(2)
            case "turn_aborted": candidates.insert(4)
            default: break
            }
        }
        for (id, status) in next {
            let old = previous[id]
            guard old != status else { continue }
            switch status {
            case .error: candidates.insert(4)
            case .waiting: candidates.insert(3)
            case .idle where old == .working: candidates.insert(2)
            case .working where old == nil: candidates.insert(1)
            default: break
            }
        }
        switch candidates.max() {
        case 4: return .failed
        case 3: return .waiting
        case 2: return .completed
        case 1: return .sessionStarted
        default: return nil
        }
    }
}

/// Optional, locally played status sounds. It never accesses network or emits speech.
@MainActor
final class SoundManager: ObservableObject {
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "islandSoundEnabled") }
    }
    @Published var volume: Double {
        didSet {
            let bounded = min(max(volume.isFinite ? volume : 0, 0), 1)
            if bounded != volume { volume = bounded }
            defaults.set(bounded, forKey: "islandSoundVolume")
        }
    }
    @Published private(set) var disabledCues: Set<String>
    private let defaults: UserDefaults
    private let playSound: @MainActor (IslandSoundCue, Float) -> Void
    private var transitions = IslandSoundTransitions()
    private var subscription: AnyCancellable?
    private var lastPlayed: Date?
    private var recentPrompts: [Date] = []
    private let builtin: Builtin8BitPlayer

    init(store: SessionStore, defaults: UserDefaults = .standard,
         play: (@MainActor (IslandSoundCue, Float) -> Void)? = nil) {
        self.defaults = defaults
        self.enabled = defaults.object(forKey: "islandSoundEnabled") as? Bool ?? false
        let stored = defaults.object(forKey: "islandSoundVolume") as? Double ?? 0.3
        self.volume = min(max(stored.isFinite ? stored : 0.3, 0), 1)
        self.disabledCues = Set(defaults.stringArray(forKey:"islandDisabledSoundCues") ?? [IslandSoundCue.acknowledged.rawValue, IslandSoundCue.userSpam.rawValue, IslandSoundCue.idleReminder.rawValue])
        let synth = Builtin8BitPlayer()
        self.builtin = synth
        self.playSound = play ?? { cue, volume in
            switch cue {
            case .completed: _ = synth.play(Builtin8BitSynth.taskComplete(), volume: volume)
            case .sessionStarted: _ = synth.play(Builtin8BitSynth.sessionStart(), volume: volume)
            case .failed: _ = synth.play(Builtin8BitSynth.taskError(), volume: volume)
            case .waiting: _ = synth.play(Builtin8BitSynth.inputRequired(), volume: volume)
            case .acknowledged: _ = synth.play(Builtin8BitSynth.taskAcknowledge(), volume: volume)
            case .question: _ = synth.play(Builtin8BitSynth.question(), volume: volume)
            case .resourceLimit: _ = synth.play(Builtin8BitSynth.resourceLimit(), volume: volume)
            case .userSpam: _ = synth.play(Builtin8BitSynth.userSpam(), volume: volume)
            case .idleReminder: _ = synth.play(Builtin8BitSynth.idleReminder(), volume: volume)
            case .usageWarning: _ = synth.play(Builtin8BitSynth.usageWarning(), volume: volume)
            case .usageReset: _ = synth.play(Builtin8BitSynth.usageReset(), volume: volume)
            case .resetCard: _ = synth.play(Builtin8BitSynth.resetCard(), volume: volume)
            }
        }
        subscription = store.$sessions.sink { [weak self] sessions in
            guard let self else { return }
            let cue = self.transitions.update(sessions)
            guard let cue else { return }
            self.emit(cue)
        }
    }

    func emit(_ cue: IslandSoundCue) {
        guard enabled, volume > 0, !disabledCues.contains(cue.rawValue) else { return }
        let now = Date()
        guard lastPlayed.map({ now.timeIntervalSince($0) >= 1.5 }) ?? true else { return }
        lastPlayed = now
        playSound(cue, Float(volume))
    }
    func isEnabled(_ cue: IslandSoundCue) -> Bool { !disabledCues.contains(cue.rawValue) }
    func setEnabled(_ enabled: Bool, for cue: IslandSoundCue) {
        if enabled { disabledCues.remove(cue.rawValue) } else { disabledCues.insert(cue.rawValue) }
        defaults.set(Array(disabledCues).sorted(), forKey:"islandDisabledSoundCues")
    }
    /// Observation-only events may play a cue; they never convey approval authority.
    func emitClaudeObservation(event: String, detail: String) {
        switch event {
        case "SessionStart": emit(.sessionStarted)
        case "UserPromptSubmit": noteUserPrompt()
        case "Stop": emit(.completed)
        case "StopFailure": emit(.failed)
        case "PermissionRequest": emit(.waiting)
        case "Notification" where detail == "收到权限提示": emit(.waiting)
        case "Notification" where detail == "收到空闲提醒": emit(.idleReminder)
        case "Notification" where detail == "收到提问": emit(.question)
        default: break
        }
    }

    /// Three prompts inside ten seconds counts as "连续提交". The threshold is this project's own
    /// choice: the original's value could not be established from static analysis.
    private func noteUserPrompt() {
        let now = Date()
        recentPrompts = recentPrompts.filter { now.timeIntervalSince($0) < 10 } + [now]
        emit(recentPrompts.count >= 3 ? .userSpam : .acknowledged)
    }

    /// A preview is explicitly requested from settings and does not enable event sounds.
    func preview(_ cue: IslandSoundCue = .completed) {
        guard volume > 0 else { return }
        playSound(cue, Float(volume))
    }

}
