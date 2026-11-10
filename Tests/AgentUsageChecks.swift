import Foundation
// Compile with AgentUsageReader.swift. Fictional replies only; no network and no credentials.
@main struct AgentUsageChecks {
    @MainActor static func main() {
        let claude = UsageParsing.claude(["rate_limits": ["five_hour": ["utilization": 38, "resets_at": "2026-11-05T01:00:00Z"], "seven_day": ["utilization": 12.4]]])
        precondition(claude.map(\.label) == ["5H", "7D"] && claude.map(\.remainingPercent) == [62, 88] && claude[0].resetsAt != nil)
        let lowUse = UsageParsing.claude(["rate_limits": ["five_hour": ["utilization": 1, "resets_at": 1793800000]]])
        precondition(lowUse[0].remainingPercent == 99 && lowUse[0].resetsAt != nil, "1 means 1 percent, not all of it")
        precondition(UsageParsing.claude([:]).isEmpty)
        let codex = UsageParsing.codex(["rateLimitsByLimitId": ["codex": ["limitId": "codex", "primary": ["usedPercent": 6, "windowDurationMins": 300, "resetsAt": 1793800000], "secondary": ["usedPercent": 29, "windowDurationMins": 10080]]]])
        precondition(codex.map(\.label) == ["5H", "7D"] && codex.map(\.remainingPercent) == [94, 71] && codex[0].resetsAt != nil)
        precondition(UsageParsing.codex(["rateLimits": ["primary": ["usedPercent": 100]]]).first?.remainingPercent == 0)
        let kimi = UsageParsing.kimi(["usage": ["limit": "100", "used": "20", "remaining": "80", "resetTime": "2026-11-10T00:00:00.123Z"],
                                      "limits": [["window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"], "detail": ["limit": "100", "remaining": "45"]]]])
        precondition(kimi.map(\.label) == ["5H", "7D"] && kimi.map(\.remainingPercent) == [45, 80] && kimi[1].resetsAt != nil, "\(kimi)")
        precondition(UsageParsing.durationLabel(minutes: 10080, fallback: "x") == "7D" && UsageParsing.durationLabel(minutes: 300, fallback: "x") == "5H" && UsageParsing.durationLabel(minutes: nil, fallback: "x") == "x")
        print("AgentUsageChecks passed")
    }
}
