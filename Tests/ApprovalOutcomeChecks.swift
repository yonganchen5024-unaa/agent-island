import Foundation
// Compile with ClaudeApprovalBridge.swift. The text must follow Claude's result, not the click.
@main struct ApprovalOutcomeChecks {
    @MainActor static func main() {
        let cases: [(String, Bool, String, ClaudeApprovalOutcome.Kind)] = [
            ("allow", false, "Claude 已执行 Bash", .success),
            ("allow", true, "Bash 没有成功：工具出错，或另一个审批方先拒绝了，请到终端查看", .warning),
            ("deny", true, "Claude 已按拒绝处理 Bash", .success),
            ("deny", false, "拒绝没有生效：另一个审批方先允许了，Bash 已执行", .warning),
            ("answer", false, "Claude 已收到回答", .success),
            ("answer", true, "回答没有生效，请到终端查看", .warning),
        ]
        for (decision, isError, text, kind) in cases {
            let outcome = ClaudeApprovalBridge.confirmedOutcome(decision: decision, isError: isError, name: "Bash")
            precondition(outcome.text == text && outcome.kind == kind, "\(decision) \(isError)")
        }
        print("ApprovalOutcomeChecks passed")
    }
}
