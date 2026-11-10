import AppKit
import SwiftUI

enum IslandMetrics {
    static let expandedWidth: CGFloat = 652
    /// Room around the island for its shadow, which SwiftUI draws inside the window.
    static let shadowMargin: CGFloat = 28
    /// Values from the original's own code (1010a1f00, 1010a1f44). That the first opens and the second
    /// closes is inferred: the bouncy one suits opening, and both are used by the same view.
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let close = Animation.spring(response: 0.45, dampingFraction: 1.0)
    /// Long enough for either spring to settle before the window shrinks back around the island.
    static let settle: TimeInterval = 0.8
    /// The left side area beside a camera housing, from the original (100291a80).
    static let wing: CGFloat = 36
    /// The right side area. The original uses 36 (100291b64); this is the user's choice, so that the
    /// island leaves more of the menu bar's status icons free. It still fits a two-digit count.
    static let rightWing: CGFloat = 26
}

/// Where the camera housing is on this display. A screen without one reports a zero notch.
/// Sizes follow the original's NotchViewModel: the housing's width is the screen minus both auxiliary
/// areas (101592c44), and a collapsed island is housing + 36 + 36 at the housing's height (100291908).
/// Without a housing it is 43 + 43 + 120 wide and 38 tall (1002921c4, 1002922b8, 101592c44).
struct IslandGeometry: Equatable {
    /// The usage strip's own row, under the camera housing.
    static let usageRow: CGFloat = 26
    /// Height of everything above the session list.
    var headerHeight: CGFloat { notchWidth > 0 ? max(notchHeight, 36) + Self.usageRow : 36 }
    var notchWidth: CGFloat = 0
    var notchHeight: CGFloat = 0
    var collapsed = CGSize(width: 206, height: 38)
    /// Unequal side areas mean a collapsed island's centre is not the housing's centre.
    var collapsedOffset: CGFloat { notchWidth > 0 ? (IslandMetrics.rightWing - IslandMetrics.wing) / 2 : 0 }

    init() {}
    init(notchWidth: CGFloat, notchHeight: CGFloat) {
        self.notchWidth = notchWidth; self.notchHeight = notchHeight
        if notchWidth > 0 { collapsed = CGSize(width: notchWidth + IslandMetrics.wing + IslandMetrics.rightWing, height: notchHeight) }
    }
    /// The offsets are the user's fine tuning from the display settings, as in the original (100291908).
    init(screen: NSScreen, widthOffset: CGFloat = 0, heightOffset: CGFloat = 0) {
        guard screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { self.init(); return }
        self.init(notchWidth: max(40, screen.frame.width - left.width - right.width + widthOffset), notchHeight: max(8, screen.safeAreaInsets.top + heightOffset))
    }
}

@MainActor final class IslandPresentation: ObservableObject {
    @Published var expanded = false
    @Published var geometry = IslandGeometry()
    /// The island's current size and sideways shift from the screen's centre, which are what animate.
    @Published var size = IslandGeometry().collapsed
    @Published var centerOffset: CGFloat = 0
    /// The expanded content's final height. It does not animate, so text is never re-wrapped mid-flight.
    @Published var contentHeight: CGFloat = 138
    /// The expanded width. It changes only from settings, and does not animate content either.
    @Published var expandedWidth: CGFloat = IslandMetrics.expandedWidth
}

/// Hosts the island at one fixed size, in the top centre of this view. Changing the window's size then
/// only crops it evenly from both sides. SwiftUI sees no layout change, so nothing can slide: when the
/// hosting view followed the window, its re-layout joined the spring and the island moved sideways as
/// it opened. The position is set explicitly, because AppKit's autoresizing does not keep a subview
/// centred when it is larger than its parent.
@MainActor final class IslandContainerView: NSView {
    private let host: NSView
    private let hostSize: CGSize
    /// Where the screen's centre falls inside the window, measured from the window's left edge. The
    /// window may be off-centre when collapsed, and the hosted content must not move when it changes.
    var hostCenterX: CGFloat? { didSet { place() } }
    init(host: NSView, hostSize: CGSize, windowSize: CGSize) {
        self.host = host; self.hostSize = hostSize
        super.init(frame: NSRect(origin: .zero, size: windowSize))
        addSubview(host)
        place()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }
    override func layout() { super.layout(); place() }
    private func place() {
        let center = hostCenterX ?? bounds.width / 2
        host.frame = NSRect(x: (center - hostSize.width / 2).rounded(), y: bounds.height - hostSize.height, width: hostSize.width, height: hostSize.height)
    }
}

@MainActor func makeIslandContainer<Content: View>(root: Content, width: CGFloat = 1400, height: CGFloat = 1600, windowSize: CGSize) -> NSView {
    let host = NSHostingView(rootView: root)
    // Otherwise the hosting view pushes its own size constraints onto the window.
    host.sizingOptions = []
    return IslandContainerView(host: host, hostSize: CGSize(width: width, height: height), windowSize: windowSize)
}

struct RootIsland: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var sound: SoundManager
    @ObservedObject var approval: ClaudeApprovalBridge
    @ObservedObject var presentation: IslandPresentation
    @ObservedObject var usage: AgentUsageReader
    var onToggle: () -> Void
    var onSettings: () -> Void
    var onHover: (Bool) -> Void
    var onJump: (SessionItem) -> Void = { _ in }

    /// The state the collapsed island shows: whatever most needs attention.
    private var leadingPhase: IslandPhase {
        if !approval.pending.isEmpty { return .waitingForApproval }
        let phases = store.visibleSessions.map(\.phase)
        for wanted in [IslandPhase.question, .waitingForApproval, .failed, .runningTool, .processing, .thinking, .compacting, .waitingForInput] where phases.contains(wanted) { return wanted }
        return .ended
    }

    /// The icon and the count sit in the two areas beside the camera housing, never under it.
    @ViewBuilder private var collapsedFace: some View {
        let notch = presentation.geometry.notchWidth
        HStack(spacing: 0) {
            PixelStatusIcon(phase: leadingPhase).frame(width: notch > 0 ? 28 : 34, height: 18)
                .frame(width: notch > 0 ? IslandMetrics.wing : nil)
            Spacer(minLength: notch)
            collapsedCount.frame(width: notch > 0 ? IslandMetrics.rightWing : nil)
        }.padding(.horizontal, notch > 0 ? 0 : 14)
    }

    @ViewBuilder private var collapsedCount: some View {
        if approval.pending.isEmpty {
            Text("\(store.visibleSessions.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        } else {
            Text("\(approval.pending.count)").font(.system(size: 12, weight: .bold)).foregroundStyle(IslandPhase.waitingForApproval.color)
        }
    }

    private var shape: UnevenRoundedRectangle {
        let bottom: CGFloat = presentation.expanded ? 22 : 15
        return UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: 4)
    }

    var body: some View {
        let expanded = presentation.expanded
        ZStack(alignment: .top) {
            shape.fill(.black)
            // Both faces stay mounted at their final size. The animating shape clips them, so nothing
            // re-lays out during the motion. That re-layout is what made resizing the window stutter.
            IslandView(store: store, sound: sound, approval: approval, usage: usage, geometry: presentation.geometry, onSettings: onSettings, onJump: onJump)
                .frame(width: presentation.expandedWidth, height: presentation.contentHeight, alignment: .top)
                .opacity(expanded ? 1 : 0)
                .animation(.easeOut(duration: expanded ? 0.25 : 0.1), value: expanded)
                .allowsHitTesting(expanded)
            Button(action: onToggle) {
                collapsedFace.frame(width: presentation.geometry.collapsed.width, height: presentation.geometry.collapsed.height).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("展开小岛，\(store.visibleSessions.count) 个会话")
            .opacity(expanded ? 0 : 1)
            .animation(.easeOut(duration: expanded ? 0.1 : 0.2).delay(expanded ? 0 : 0.1), value: expanded)
            .allowsHitTesting(!expanded)
        }
        .frame(width: presentation.size.width, height: presentation.size.height, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .onHover(perform: onHover)
        .compositingGroup()
        // No shadow when collapsed: the window then has no margin that could catch clicks on the menu bar.
        .shadow(color: .black.opacity(expanded ? 0.42 : 0), radius: expanded ? 16 : 0, y: expanded ? 8 : 0)
        .offset(x: presentation.centerOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct IslandView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var sound: SoundManager
    @ObservedObject var approval: ClaudeApprovalBridge
    @ObservedObject var usage: AgentUsageReader
    var geometry = IslandGeometry()
    var onSettings: () -> Void
    var onJump: (SessionItem) -> Void = { _ in }
    @AppStorage("showUsage") private var showUsage = true
    @AppStorage("disableClickToJump") private var clickJumpDisabled = false
    /// Whatever needs the user comes first, then running work. Order is otherwise stable, so rows
    /// do not jump around each time an event arrives.
    private var ordered: [SessionItem] {
        func rank(_ item: SessionItem) -> Int {
            switch item.status {
            case .waiting: return 0
            case .error: return 1
            case .working: return 2
            default: return 3
            }
        }
        return store.visibleSessions.sorted { (rank($0), $0.title, $0.id) < (rank($1), $1.title, $1.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Beside the camera housing there is room only at the sides, so nothing long goes in this row.
            HStack(spacing: 7) {
                if geometry.notchWidth > 0 || !showUsage {
                    Text("\(store.visibleSessions.count) 个会话").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                } else {
                    UsageStrip(usage: usage)
                }
                Spacer(minLength: geometry.notchWidth + 6)
                Button(action: { sound.enabled.toggle() }) {
                    Image(systemName: sound.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.68)).frame(width: 30, height: 30)
                }.buttonStyle(.plain).help(sound.enabled ? "静音" : "启用声音")
                Button(action: onSettings) {
                    Image(systemName: "gearshape.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.68)).frame(width: 30, height: 30)
                }.buttonStyle(.plain).help("设置").accessibilityLabel("打开设置")
            }.padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 2).frame(minHeight: geometry.notchHeight, alignment: .center)
            if geometry.notchWidth > 0 && showUsage {
                HStack { UsageStrip(usage: usage); Spacer(minLength: 0) }.padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 4).frame(height: IslandGeometry.usageRow)
            }
            if store.visibleSessions.isEmpty && approval.pending.isEmpty && approval.lastOutcome == nil {
                let hidden = store.sessions.count - store.visibleSessions.count
                VStack(spacing: 6) {
                    Text(hidden > 0 ? "暂无活动会话" : "暂无会话").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.52))
                    Text(hidden > 0 ? "\(hidden) 个空闲会话已隐藏，有新活动时会重新出现" : "在设置中选择数据来源").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !approval.pending.isEmpty {
                            Text("\(approval.pending.count) 个待审批").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.65)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            ForEach(approval.pending) { request in
                                ApprovalCard(bridge: approval, request: request).padding(.vertical, 6)
                            }
                        }
                        if let outcome = approval.lastOutcome {
                            ApprovalOutcomeLine(outcome: outcome).padding(.vertical, 6)
                        }
                        ForEach(ordered) { session in
                            if clickJumpDisabled {
                                SessionRow(session: session)
                            } else {
                                Button { onJump(session) } label: { SessionRow(session: session) }
                                    .buttonStyle(SessionRowButtonStyle()).help("跳转到这个会话")
                            }
                        }
                    }.padding(.horizontal, 22).padding(.bottom, 12)
                }.scrollIndicators(.hidden)
            }
        }.foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Remaining quota for every agent that reports one, in the island's top bar.
private struct UsageStrip: View {
    @ObservedObject var usage: AgentUsageReader
    @AppStorage("usageShowsUsed") private var showsUsed = false
    private func tint(_ left: Int) -> Color {
        if left <= 10 { return Color(red: 1.0, green: 0.42, blue: 0.40) }
        if left <= 30 { return Color(red: 1.0, green: 0.72, blue: 0.27) }
        return .white.opacity(0.8)
    }
    private func resetText(_ date: Date?) -> String {
        guard let date else { return "" }
        let minutes = Int(date.timeIntervalSinceNow / 60)
        guard minutes > 0 else { return "" }
        let time = minutes >= 1440 ? "\(minutes / 1440) 天 \(minutes % 1440 / 60) 小时" : minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟"
        return "，\(time)后重置"
    }
    var body: some View {
        HStack(spacing: 11) {
            if usage.usages.isEmpty {
                Text("正在读取额度…").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            }
            ForEach(usage.usages) { agent in
                HStack(spacing: 5) {
                    Text(agent.name).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                    if agent.windows.isEmpty {
                        Text(agent.problem ?? "—").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
                    }
                    ForEach(agent.windows, id: \.label) { window in
                        HStack(spacing: 2) {
                            Text(window.label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.42))
                            Text("\(showsUsed ? 100 - window.remainingPercent : window.remainingPercent)%").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(tint(window.remainingPercent))
                        }.help("\(agent.name) \(window.label) 还剩 \(window.remainingPercent)%\(resetText(window.resetsAt))")
                    }
                }
            }
        }.lineLimit(1)
    }
}

/// A row is a button, with a hover so it reads as one. Its text stays where it would be without it.
private struct SessionRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.11 : hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, -8)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private struct SessionRow: View {
    let session: SessionItem
    private var tint: Color { sessionTint(session) }
    private var status: String { session.phase.title }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PixelStatusIcon(phase: session.phase, compact: true).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(session.title.isEmpty ? "未命名会话" : session.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(session.agent).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint).padding(.horizontal, 6).padding(.vertical, 2).background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
                }
                HStack(spacing: 5) {
                    Text(status).foregroundStyle(tint.opacity(0.85)).font(.system(size: 10.5, weight: .medium))
                    if !session.detail.isEmpty {
                        Text("·").foregroundStyle(.white.opacity(0.25))
                        Text(session.detail).foregroundStyle(.white.opacity(0.47)).font(.system(size: 10.5)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if let activity = session.activity { ActivityDetail(activity: activity, tint: tint) }
            }
        }.padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

/// The current task, its plan and its subagents, under a session's status line.
private struct ActivityDetail: View {
    let activity: SessionActivity
    let tint: Color
    @AppStorage("showTasks") private var showTasks = true
    @AppStorage("showSubagents") private var showSubagents = true
    private var doneCount: Int { activity.todos.filter { $0.state == "completed" }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let task = activity.task {
                Text(task).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
            }
            ForEach(Array((showTasks ? visibleTodos : []).enumerated()), id: \.offset) { _, todo in
                HStack(spacing: 5) {
                    Image(systemName: todo.state == "completed" ? "checkmark.circle.fill" : todo.state == "in_progress" ? "circle.dotted" : "circle")
                        .font(.system(size: 9)).foregroundStyle(todo.state == "pending" ? Color.white.opacity(0.3) : tint)
                    Text(todo.text).font(.system(size: 10.5, weight: todo.state == "in_progress" ? .medium : .regular))
                        .foregroundStyle(.white.opacity(todo.state == "pending" ? 0.4 : todo.state == "completed" ? 0.45 : 0.82)).lineLimit(1)
                    if todo.state == "in_progress" { Text("\(doneCount + 1)/\(activity.todos.count)").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.38)) }
                }
            }
            if !activity.subagents.isEmpty {
                let running = activity.subagents.filter(\.running).count
                Text(running > 0 ? "子 Agent · \(running) 运行中" : "子 Agent · \(activity.subagents.count) 完成")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).padding(.top, 2)
                ForEach(showSubagents ? Array(activity.subagents.prefix(3)) : []) { agent in
                    HStack(spacing: 5) {
                        Circle().fill(agent.running ? tint : Color.white.opacity(0.25)).frame(width: 5, height: 5)
                        Text(agent.task.isEmpty ? agent.name : agent.task).font(.system(size: 10.5)).foregroundStyle(.white.opacity(agent.running ? 0.78 : 0.42)).lineLimit(1)
                        if let step = agent.step { Text(step).font(.system(size: 10)).foregroundStyle(.white.opacity(0.38)).lineLimit(1) }
                    }
                }
            }
        }
    }
    /// The active step and its neighbours, when a plan is too long to show whole.
    private var visibleTodos: [SessionTodo] {
        let todos = activity.todos
        guard todos.count > 5, let current = todos.firstIndex(where: { $0.state == "in_progress" }) else { return Array(todos.prefix(5)) }
        let start = max(0, min(current - 1, todos.count - 5))
        return Array(todos[start..<(start + 5)])
    }
}
