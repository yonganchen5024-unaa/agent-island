import Foundation

@MainActor final class StubNotifications: IslandNotificationTransport {
    var allowed = true
    var permissionRequests = 0
    var sends: [String] = []
    var failSend = false
    func requestPermission() async throws -> Bool { permissionRequests += 1; return allowed }
    func send(body: String) async throws {
        if failSend { throw NSError(domain:"fixture", code:1) }
        sends.append(body)
    }
}
@main struct NotificationChecks {
    @MainActor static func main() async throws {
        let transport = StubNotifications()
        let service = NotificationManager(transport: transport)
        service.emitLive(id:"before",kind:.completed,happenedAt:Date())
        precondition(transport.permissionRequests == 0 && transport.sends.isEmpty)
        let historic = Date(timeIntervalSinceNow: -60)
        service.requestPermissionAndEnable()
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(service.enabled && transport.permissionRequests == 1)
        service.emitLive(id:"history",kind:.completed,happenedAt:historic)
        service.emitObservedClaude(id:"old",kind:.completed,happenedAt:historic)
        service.emitObservedClaude(id:"future",kind:.waiting,happenedAt:Date(timeIntervalSinceNow: 60))
        service.emitObservedClaude(id:"private-fixture",kind:.waiting,happenedAt:Date())
        service.emitObservedClaude(id:"private-fixture",kind:.waiting,happenedAt:Date())
        service.emitLive(id:"fixture-1",kind:.waiting,happenedAt:Date())
        service.emitLive(id:"fixture-1",kind:.waiting,happenedAt:Date())
        service.emitLive(id:"fixture-2",kind:.completed,happenedAt:Date())
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(transport.sends.count == 3 && transport.sends.contains("一个会话正在等待你的处理。") && transport.sends.contains("一个任务已完成。") && transport.sends.contains("Claude Code 检测到等待事件，请核实。"))
        precondition(!transport.sends.joined().contains("fixture"))
        service.disable()
        service.emitLive(id:"after",kind:.failed,happenedAt:Date())
        service.emitObservedClaude(id:"after",kind:.failed,happenedAt:Date())
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(transport.sends.count == 3 && service.state == .disabled)
        let denied = StubNotifications(); denied.allowed = false
        let deniedService = NotificationManager(transport:denied)
        deniedService.requestPermissionAndEnable()
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(deniedService.state == .denied)
        let failing = StubNotifications(); failing.failSend = true
        let failingService = NotificationManager(transport:failing)
        failingService.requestPermissionAndEnable()
        try await Task.sleep(nanoseconds: 20_000_000)
        failingService.emitLive(id:"new",kind:.failed,happenedAt:Date())
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(failingService.state == .failed("系统通知发送失败"))
        print("notification consent, filtering, dedupe, privacy, disable, failures: PASS")
    }
}
