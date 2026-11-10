import Foundation
@main struct Checks {
    static func transitions(_ x:[Float], _ from:Int, _ to:Int) -> Int {
        var count = 0
        for i in (from+1)..<to { if (x[i-1] < 0) != (x[i] < 0) { count += 1 } }
        return count
    }
    static func main() {
        let complete = Builtin8BitSynth.taskComplete()
        let start = Builtin8BitSynth.sessionStart()
        let other: [([Float], Int)] = [
            (Builtin8BitSynth.taskAcknowledge(), 10_560),
            (Builtin8BitSynth.taskError(), 24_000),
            (Builtin8BitSynth.inputRequired(), 28_800),
            (Builtin8BitSynth.question(), 19_200),
            (Builtin8BitSynth.resourceLimit(), 24_000),
            (Builtin8BitSynth.userSpam(), 16_800),
            (Builtin8BitSynth.idleReminder(), 16_800),
            (Builtin8BitSynth.usageWarning(), 33_600),
            (Builtin8BitSynth.usageReset(), 31_199), // Float32(0.65) * 48000, then truncate.
            (Builtin8BitSynth.resetCard(), 86_400)
        ]
        precondition(complete.count == 52_800 && start.count == 24_000)
        precondition(complete[0] == 0 && start[0] == 0)
        precondition(complete[3500] == 0 && complete[50000] == 0)
        precondition(complete.allSatisfy { $0.isFinite && abs($0) <= 1 })
        precondition(start.allSatisfy { $0.isFinite && abs($0) <= 1 })
        for (samples, count) in other {
            precondition(samples.count == count)
            precondition(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
            precondition(samples.contains { abs($0) > 0.01 })
        }
        let first = transitions(complete, 960, 1920)
        let second = transitions(complete, 4800, 5760)
        precondition((25...27).contains(first) && (30...33).contains(second))
        print("8-bit candidate durations, gaps, limits, and tone frequencies: PASS")
    }
}
