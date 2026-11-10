import Foundation

/// Which real events reach the phone: something that needs the user, right now. Used by the app and
/// by the end-to-end harness, so the harness tests this mapping and not a copy of it. The end of a
/// turn is deliberately absent. BarkNotifier.observeWork decides when everything has stopped.
extension BarkNotifier {
    func notify(_ request: ClaudeApprovalRequest, session: String?) {
        notify(request.isQuestion ? .question : .approval, session: session, sessionKey: request.source + ":" + request.sessionID)
    }

    func notify(_ event: ClaudeApprovalLifecycle, session: String?) {
        let key = event.source + ":" + event.sessionID
        // A question also arrives as a PermissionRequest, in bypassPermissions too (measured 3/3 on
        // 2.1.318). This one comes first, and the per-session limit makes the two one push.
        if event.name == "PreToolUse", event.toolName == "AskUserQuestion" { notify(.question, session: session, sessionKey: key) }
        if event.name == "StopFailure", !event.isSubagent { recordFailure(session: session, sessionKey: key) }
    }
}
