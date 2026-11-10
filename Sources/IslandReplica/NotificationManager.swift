import Foundation
import Combine
import UserNotifications

/// Only adapters which have positively established a new live event may call emitLive.
/// Historical snapshots, inferred status changes and demo events must not call it.
enum IslandNotificationKind: Equatable {
    case completed, waiting, failed
    var body: String {
        switch self {
        case .completed: return "一个任务已完成。"
        case .waiting: return "一个会话正在等待你的处理。"
        case .failed: return "一个任务遇到错误。"
        }
    }
    /// An unauthenticated local observation is not proof of the underlying state.
    var observedBody: String {
        switch self {
        case .completed: return "Claude Code 检测到完成事件，请核实。"
        case .waiting: return "Claude Code 检测到等待事件，请核实。"
        case .failed: return "Claude Code 检测到错误事件，请核实。"
        }
    }
}

@MainActor
protocol IslandNotificationTransport {
    func requestPermission() async throws -> Bool
    func send(body: String) async throws
}

@MainActor
final class SystemNotificationTransport: IslandNotificationTransport {
    func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }
    func send(body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = "会话提醒"
        content.body = body
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}

/// Explicit notification opt-in. No data access or authorization request during initialization.
@MainActor
final class NotificationManager: ObservableObject {
    enum State: Equatable {
        case disabled, requesting, enabled, denied, failed(String)
    }
    @Published private(set) var state: State = .disabled
    var enabled: Bool { state == .enabled }
    private let transport: IslandNotificationTransport
    private var enabledAt: Date?
    private var seenIDs = Set<String>()
    private var seenOrder: [String] = []
    private var generation = UUID()
    private let capacity = 1024

    init(transport: IslandNotificationTransport) {
        self.transport = transport
    }
    convenience init() { self.init(transport: SystemNotificationTransport()) }

    /// Call only from an explicit user action, not from app startup.
    func requestPermissionAndEnable() {
        guard state != .requesting && state != .enabled else { return }
        let token = UUID(); generation = token; state = .requesting
        Task {
            do {
                let granted = try await transport.requestPermission()
                guard generation == token else { return }
                if granted {
                    enabledAt = Date(); seenIDs.removeAll(); seenOrder.removeAll(); state = .enabled
                } else { enabledAt = nil; state = .denied }
            } catch {
                guard generation == token else { return }
                enabledAt = nil; state = .failed("无法请求通知权限")
            }
        }
    }

    func disable() {
        generation = UUID(); enabledAt = nil; seenIDs.removeAll(); seenOrder.removeAll(); state = .disabled
    }

    /// The caller must verify real-time provenance and supply a stable event ID.
    /// Event details are intentionally omitted from the displayed notification.
    func emitLive(id: String, kind: IslandNotificationKind, happenedAt: Date) {
        enqueue(id: id, namespace: "live:", body: kind.body, happenedAt: happenedAt, maxAge: nil, futureTolerance: 5)
    }

    /// An untrusted, local-only Claude status observation. The notification never
    /// asserts the event is verified or offers an approval action.
    func emitObservedClaude(id: String, kind: IslandNotificationKind, happenedAt: Date) {
        enqueue(id: id, namespace: "observed-claude:", body: kind.observedBody, happenedAt: happenedAt, maxAge: 30, futureTolerance: 0)
    }
    func emitObservedClaudeEvent(id: String, event: String, detail: String, happenedAt: Date) {
        let kind: IslandNotificationKind?
        switch event {
        case "Stop": kind = .completed
        case "StopFailure": kind = .failed
        case "PermissionRequest": kind = .waiting
        case "Notification" where detail == "收到权限提示": kind = .waiting
        default: kind = nil
        }
        if let kind { emitObservedClaude(id:id, kind:kind, happenedAt:happenedAt) }
    }

    private func enqueue(id: String, namespace: String, body: String, happenedAt: Date, maxAge: TimeInterval?, futureTolerance: TimeInterval) {
        let dedupeID = namespace + id
        let now = Date()
        guard enabled, let enabledAt, happenedAt >= enabledAt,
              happenedAt <= now.addingTimeInterval(futureTolerance),
              maxAge.map({ happenedAt >= now.addingTimeInterval(-$0) }) ?? true,
              !id.isEmpty, id.utf8.count <= 512, seenIDs.insert(dedupeID).inserted else { return }
        seenOrder.append(dedupeID)
        if seenOrder.count > capacity { seenIDs.remove(seenOrder.removeFirst()) }
        let token = generation
        Task {
            guard state == .enabled && generation == token else { return }
            do { try await transport.send(body: body) }
            catch {
                guard generation == token else { return }
                self.enabledAt = nil; state = .failed("系统通知发送失败")
            }
        }
    }
}
