import AppKit
import SwiftUI
import Combine
import QuartzCore
import Darwin

@MainActor
final class IslandController: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var codexLive: CodexLiveSessionReader?
    private var workTimer: Timer?
    /// See installOverflowTracer.
    private var overflowTracer: NSStatusItem?
    private var tracerMoveObserver: NSObjectProtocol?
    private var overflowTimer: Timer?
    private var overflowDetector = MenuBarOverflowDetector()
    private var yieldingToOverflow = false
    private var lastOverflowState = ""
    private var overflowLogLines = 0
    private let store = SessionStore(demo: CommandLine.arguments.contains("--demo"))
    private let presentation = IslandPresentation()
    private var server: LocalEventServer?
    private var codexAdapter: CodexSessionAdapter?
    private var rolloutReader: CodexRolloutReader?
    private var claudeReader: ClaudeSessionReader?
    private var soundManager: SoundManager?
    private var notifications: NotificationManager?
    private var hotkeys: HotkeyManager?
    private var claudeApproval: ClaudeApprovalBridge?
    private var claudeObserver: ClaudeObserverBridge?
    private var claudeSpool: ClaudeSpoolReader?
    private var claudeLive: ClaudeLiveSessionReader?
    private let bark = BarkNotifier(file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Island/bark.json"))
    private let usage = AgentUsageReader(debugLog: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Island/usage-debug.ndjson"))
    private var hoverWork: DispatchWorkItem?
    private var subscription: AnyCancellable?
    private var approvalSubscription: AnyCancellable?
    private var outcomeSubscription: AnyCancellable?
    private var defaultsSubscription: AnyCancellable?
    private var expandedForApproval = false
    /// Opened only because the pointer rested on it, so a right-click may close it again.
    private var expandedByHover = false
    /// Set by a right-click: resting on the island does not open it until the pointer has left.
    private var hoverSuppressed = false
    private var layoutGeneration = 0
    private var rightClickMonitor: Any?
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Login start and a manual open can overlap. Two islands would sit on top of each other.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        // pkill, shutdown and updates quit cleanly with status 0, so launchd does not restart the app.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        terminationSource = termination
        UserDefaults.standard.register(defaults: ["hoverExpand": true, "hoverDelay": 0.2, "autoCollapse": true, "islandSoundEnabled": true, "claudeLogEnabled": false, "maxPanelWidth": 652.0, "maxPanelHeight": 700.0, "claudeApprovalEnabled": true, "claudeSpoolEnabled": true])
        codexAdapter = CodexSessionAdapter(store: store, transport: CodexProcessTransport(executable: Self.findCodex()))
        rolloutReader = CodexRolloutReader(store: store, inspectOpenFiles: true)
        codexLive = CodexLiveSessionReader(store: store)
        codexLive?.start()
        if UserDefaults.standard.bool(forKey: "codexLogEnabled") { rolloutReader?.start() }
        claudeReader = ClaudeSessionReader(store: store)
        if UserDefaults.standard.bool(forKey: "claudeLogEnabled") { claudeReader?.start() }
        let brokerURL = Bundle.main.resourceURL?.appendingPathComponent("claude_approval_broker.py") ?? URL(fileURLWithPath: "/nonexistent/claude_approval_broker.py")
        let supportDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Island", isDirectory: true)
        claudeApproval = ClaudeApprovalBridge(script: brokerURL, arguments: ["--runtime-dir", "/private/tmp/cc-socks/agent-island-\(getuid())-approval"], auditLog: supportDirectory.appendingPathComponent("approval-audit.ndjson"))
        let observerURL = Bundle.main.resourceURL?.appendingPathComponent("claude_observe_broker.py") ?? URL(fileURLWithPath: "/nonexistent/claude_observe_broker.py")
        claudeObserver = ClaudeObserverBridge(store: store, script: observerURL, runtime: URL(fileURLWithPath:"/private/tmp/agent-island-\(getuid())-events"))
        if UserDefaults.standard.bool(forKey:"claudeObserverEnabled") { claudeObserver?.start() }
        let sounds = SoundManager(store: store)
        soundManager = sounds
        let notificationManager = NotificationManager()
        notifications = notificationManager
        claudeApproval?.onRequest = { [weak sounds, weak self] request in
            sounds?.emit(request.isQuestion ? .question : .waiting)
            self?.bark.notify(request, session: self?.sessionName(request.source, request.sessionID))
        }
        claudeApproval?.onLifecycle = { [weak sounds, weak store, weak self] event in
            if event.source == "claude", ClaudeProbeSessions.isProbe(event.sessionID) { return }
            if event.name == "PreCompact" { sounds?.emit(.resourceLimit) }
            self?.bark.notify(event, session: self?.sessionName(event.source, event.sessionID))
            guard !event.isSubagent else { return }
            // Claude's sounds come from the observation spool, which also carries SessionStart.
            if event.source == "claude" {
                store?.observeClaude(sessionID: event.sessionID, event: event.name, notification: event.notification, at: Date())
                return
            }
            // Codex already has its rows, read from its logs. A hook row would be a duplicate.
            if event.source == "codex" { return }
            store?.observeAgent(source: event.source, name: agentDisplayName(event.source), sessionID: event.sessionID, event: event.name, cwd: event.cwd, pid: event.pid)
            sounds?.emitClaudeObservation(event: event.name, detail: event.notification == "idle_prompt" ? "收到空闲提醒" : "收到提问")
        }
        claudeApproval?.onRequestEnded = { [weak store, weak self] source, session, reason in
            if self?.claudeApproval?.pending.contains(where: { $0.source == source && $0.sessionID == session }) != true {
                self?.bark.cancelHeld(sessionKey: source + ":" + session)
            }
            // Claude ends a pending hook on Esc and sends no other event, so the state must be reset here.
            if source == "claude", reason == "hook-gone" { store?.observeClaude(sessionID: session, event: "Interrupted", notification: nil, at: Date()) }
        }
        // If the original is running, both would wait on each other's hook. Leave requests to it.
        // Agent HUD holds Codex's request as well, and Codex waits for every hook, so a decision here would be stuck behind it.
        claudeApproval?.shouldYieldRequests = { source in
            func running(_ id: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
            if running("app.vibeisland.macos") { return "原版 Vibe Island" }
            if source == "codex", running("app.agenthud.open") { return "Agent HUD" }
            return nil
        }
        // Hooks stay inert until this service is up, and fall back to the terminal if it stops.
        if UserDefaults.standard.bool(forKey: "claudeApprovalEnabled") { claudeApproval?.start() }
        let spoolRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Island", isDirectory:true)
        claudeSpool = ClaudeSpoolReader(store:store, root:spoolRoot, spool:spoolRoot.appendingPathComponent("claude-spool-v1",isDirectory:true))
        claudeSpool?.onEvent = { [weak sounds, weak notificationManager] event, detail, id, date in
            sounds?.emitClaudeObservation(event:event, detail:detail)
            notificationManager?.emitObservedClaudeEvent(id:id, event:event, detail:detail, happenedAt:date)
        }
        if UserDefaults.standard.bool(forKey:"claudeSpoolEnabled") { claudeSpool?.start() }
        claudeLive = ClaudeLiveSessionReader(store: store)
        claudeLive?.start()
        usage.start()
        let shortcuts = HotkeyManager { [weak self] in self?.toggle() }
        hotkeys = shortcuts
        if UserDefaults.standard.bool(forKey: "islandHotkeyEnabled") { shortcuts.start() }
        if CommandLine.arguments.contains("--listen") {
            let receiver = LocalEventServer(store: store)
            do { try receiver.start(); server = receiver } catch { NSLog("事件接收器启动失败: %@", String(describing: error)) }
        }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        // The window shadow would be computed once and go stale during the motion. SwiftUI draws it instead.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = Self.spaces()
        panel.isMovable = false
        guard let claudeApproval else { return }
        panel.contentView = makeIslandContainer(root: RootIsland(store: store, sound: sounds, approval: claudeApproval, presentation: presentation, usage: usage, onToggle: { [weak self] in self?.toggle() }, onSettings: { [weak self] in self?.showSettings() }, onHover: { [weak self] in self?.hoverChanged($0) }, onJump: { [weak self] in self?.jump(to: $0) }), windowSize: IslandGeometry().collapsed)
        self.panel = panel
        installIslandMenu()
        layoutPanel(animated: false)
        panel.orderFrontRegardless()
        subscription = store.$visibleSessions.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.presentation.expanded else { return }
            self.layoutPanel(animated: true)
        }
        approvalSubscription = claudeApproval.$pending.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] requests in
            guard let self else { return }
            self.store.setCodexWaiting(Set(requests.filter { $0.source == "codex" }.map(\.sessionID)))
            // Opening for a request is automatic; closing again only undoes what opening did.
            if !requests.isEmpty && !self.presentation.expanded { self.expandedForApproval = true; self.setExpanded(true) }
            else if requests.isEmpty && self.expandedForApproval { self.expandedForApproval = false; self.collapseAfterApproval() }
            else if self.presentation.expanded { self.layoutPanel(animated: true) }
        }
        outcomeSubscription = claudeApproval.$lastOutcome.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.presentation.expanded else { return }
            self.layoutPanel(animated: true)
        }
        // Display settings apply at once. The layout call does nothing unless a size really changed.
        defaultsSubscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.layoutPanel(animated: true)
            if self.panel?.collectionBehavior != Self.spaces() { self.panel?.collectionBehavior = Self.spaces() }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◈"
        let menu = NSMenu()
        menu.addItem(withTitle: "展开 / 收起", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        item.menu = menu; statusItem = item
        installOverflowTracer()
        let work = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bark.observeWork(anyWorking: self.store.hasWorkInProgress || self.claudeApproval?.pending.isEmpty == false)
            }
        }
        RunLoop.main.add(work, forMode: .common)
        workTimer = work
    }
    /// Menu bar items that do not fit right of the notch are collapsed behind the system's » button.
    /// Opened, they appear right beside the notch, under the left wing. A placeholder cannot prevent
    /// that: measured, the system's order puts a new item last and shifts as other items change width.
    /// So, like the original, the island yields: it draws back into the notch until » closes.
    /// This invisible item only tells when. It asks to be last, so it is collapsed whenever anything is.
    private func installOverflowTracer() {
        let name = "AgentIslandOverflowTracer", key = "NSStatusItem Preferred Position "
        UserDefaults.standard.removeObject(forKey: key + "AgentIslandLeftWing")
        UserDefaults.standard.set(1400.0, forKey: key + "Item-1")
        UserDefaults.standard.set(1400.0, forKey: key + name)
        let tracer = NSStatusBar.system.statusItem(withLength: 0)
        tracer.autosaveName = name
        overflowTracer = tracer
        // The window reports every move at once. The timer ends a stuck reading and covers a missed one.
        tracerMoveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: tracer.button?.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOverflow(via: "move") }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkOverflow(via: "timer") } }
        RunLoop.main.add(timer, forMode: .common)
        overflowTimer = timer
    }
    private func checkOverflow(via source: String) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let wanted = UserDefaults.standard.object(forKey: "enableMenuBarOverflowYield") as? Bool ?? true
        let frame = overflowTracer?.button?.window?.frame
        let open = overflowDetector.isOpen(frame: frame, screen: screen.frame, now: Date()) && wanted && presentation.geometry.notchWidth > 0
        logOverflow(frame: frame, open: open, via: source)
        guard open != yieldingToOverflow else { return }
        yieldingToOverflow = open
        layoutPanel(animated: true)
    }
    /// Coordinates only, written when they change, to check this against the real menu bar.
    private func logOverflow(frame: NSRect?, open: Bool, via source: String) {
        let place = frame.map { "[\($0.minX),\($0.maxX)]" } ?? "null"
        let state = "\"tracer\":\(place),\"open\":\(open)"
        guard state != lastOverflowState, overflowLogLines < 500 else { return }
        lastOverflowState = state; overflowLogLines += 1
        let line = "{\"at\":\(Date().timeIntervalSince1970),\(state),\"via\":\"\(source)\"}\n"
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Island/menubar-debug.ndjson")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            FileManager.default.createFile(atPath: file.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
    @objc private func toggle() { expandedForApproval = false; expandedByHover = false; setExpanded(!presentation.expanded) }
    /// Leave the outcome line readable for a moment, unless the pointer is using the island.
    private func collapseAfterApproval() {
        layoutPanel(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.expandedForApproval, self.claudeApproval?.pending.isEmpty != false,
                  !self.pointerIsOverIsland() else { return }
            self.setExpanded(false)
        }
    }
    private func setExpanded(_ value: Bool) {
        hoverWork?.cancel()
        guard presentation.expanded != value else { return }
        if value { usage.refreshIfStale() }
        layoutPanel(animated: true, expanded: value)
    }
    private func pointerIsOverIsland() -> Bool {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return false }
        let size = presentation.size
        let island = NSRect(x: screen.frame.midX + presentation.centerOffset - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        return island.contains(NSEvent.mouseLocation)
    }
    private func hoverChanged(_ hovering: Bool) {
        hoverWork?.cancel()
        if hovering && hoverSuppressed { return }
        let settings = UserDefaults.standard
        let target = hovering
        // A pending request must stay readable, so moving the pointer away never hides it.
        if !hovering && claudeApproval?.pending.isEmpty == false { return }
        guard (hovering && !presentation.expanded && settings.bool(forKey: "hoverExpand")) || (!hovering && presentation.expanded && settings.bool(forKey: "autoCollapse")) else { return }
        let delay = hovering ? max(0.05, settings.double(forKey: "hoverDelay")) : 0.3
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pointerIsOverIsland() == target else { return }
            if target { self.expandedByHover = true }
            self.setExpanded(target)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { hoverWork?.cancel(); server?.stop(); codexAdapter?.stop(); rolloutReader?.stop(); claudeReader?.stop(); claudeApproval?.stop(); claudeObserver?.stop(); claudeSpool?.stop(); claudeLive?.stop(); usage.stop(); hotkeys?.stop(); notifications?.disable() }
    @objc private func showSettings() {
        hoverWork?.cancel()
        if let w = settingsWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "设置"
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.minSize = NSSize(width: 680, height: 460)
        guard let codexAdapter, let rolloutReader, let claudeReader, let claudeApproval, let claudeObserver, let claudeSpool, let soundManager, let hotkeys, let notifications else { return }
        claudeObserver.refreshConfiguration()
        w.contentView = NSHostingView(rootView: SettingsView(adapter: codexAdapter, reader: rolloutReader, claude: claudeReader, approval: claudeApproval, observer: claudeObserver, spool: claudeSpool, sound: soundManager, hotkeys: hotkeys, notifications: notifications, bark: bark, usage: usage))
        w.center(); w.isReleasedWhenClosed = false; settingsWindow = w
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    /// The window only ever changes while its contents hold still: it grows to fit before the motion
    /// and shrinks back after it, so clicks elsewhere are not swallowed. All visible motion is the
    /// SwiftUI shape, which redraws every frame without resizing the window.
    private func layoutPanel(animated: Bool, expanded: Bool? = nil) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let opening = expanded ?? presentation.expanded
        let defaults = UserDefaults.standard
        let geometry = IslandGeometry(screen: screen, widthOffset: defaults.double(forKey: "notchWidthOffset"), heightOffset: defaults.double(forKey: "notchHeightOffset"))
        let panelWidth = min(max(480, defaults.double(forKey: "maxPanelWidth")), screen.frame.width - 40)
        if panelWidth != presentation.expandedWidth { presentation.expandedWidth = panelWidth }
        if geometry != presentation.geometry { presentation.geometry = geometry }
        // Sized to what the rows need now, up to most of the screen. Anything more scrolls.
        let rowsHeight = store.visibleSessions.reduce(CGFloat(0)) { $0 + $1.expandedHeight + 0 }
        let ordinaryHeight = min(max(100 + geometry.headerHeight - 36, geometry.headerHeight + rowsHeight + 14), screen.frame.height * 0.72, max(300, defaults.double(forKey: "maxPanelHeight")))
        let pendingCount = claudeApproval?.pending.count ?? 0
        let outcomeHeight: CGFloat = claudeApproval?.lastOutcome == nil ? 0 : 26
        let hintHeight = claudeApproval?.pending.compactMap { $0.hint?.estimatedHeight }.max() ?? 0
        let approvalHeight: CGFloat = (pendingCount > 1 ? 580 : 430) + geometry.headerHeight - 36 + hintHeight
        let wanted: CGFloat = pendingCount > 0 ? max(ordinaryHeight, approvalHeight) : ordinaryHeight + outcomeHeight
        let expandedHeight = min(wanted, screen.frame.height - 10)
        // An open panel stays: a pending approval must not vanish because » was clicked. While it is
        // drawn back, clicks must reach the menu bar items beside the notch.
        let yielding = yieldingToOverflow && !opening
        panel.ignoresMouseEvents = yielding
        let target = opening ? CGSize(width: panelWidth, height: expandedHeight) : yielding ? CGSize(width: geometry.notchWidth, height: geometry.notchHeight) : geometry.collapsed
        let targetOffset = opening || yielding ? 0 : geometry.collapsedOffset
        func islandRect(_ size: CGSize, _ offset: CGFloat) -> NSRect {
            NSRect(x: screen.frame.midX + offset - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        }
        /// A window around the island. The margin is room for the shadow; a collapsed island has none.
        func place(_ rect: NSRect, margin: CGFloat, display: Bool) {
            let frame = NSRect(x: rect.minX - margin, y: rect.minY - margin, width: rect.width + margin * 2, height: rect.height + margin)
            (panel.contentView as? IslandContainerView)?.hostCenterX = screen.frame.midX - frame.minX
            panel.setFrame(frame, display: display)
        }
        // Sessions change every couple of seconds. Only a real change of size or state may animate.
        if animated && target == presentation.size && opening == presentation.expanded && expandedHeight == presentation.contentHeight { return }
        presentation.contentHeight = expandedHeight
        layoutGeneration += 1
        guard animated else {
            presentation.expanded = opening; presentation.size = target; presentation.centerOffset = targetOffset
            place(islandRect(target, targetOffset), margin: opening ? IslandMetrics.shadowMargin : 0, display: true)
            return
        }
        // The window covers both the start and the end of the motion, then settles around the end.
        place(islandRect(presentation.size, presentation.centerOffset).union(islandRect(target, targetOffset)), margin: IslandMetrics.shadowMargin, display: true)
        withAnimation(opening ? IslandMetrics.open : presentation.expanded ? IslandMetrics.close : .easeOut(duration: 0.18)) {
            presentation.expanded = opening
            presentation.size = target
            presentation.centerOffset = targetOffset
        }
        let generation = layoutGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + IslandMetrics.settle) { [weak self] in
            guard let self, self.layoutGeneration == generation else { return }
            place(islandRect(target, targetOffset), margin: opening ? IslandMetrics.shadowMargin : 0, display: false)
        }
    }
    /// Right-click, or control-click: settings and quit. Text in a card keeps its own copy menu.
    private func installIslandMenu() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
            if let hit = panel.contentView?.hitTest(event.locationInWindow), hit is NSTextView { return event }
            self.showIslandMenu(with: event)
            return nil
        }
    }
    /// Without .fullScreenAuxiliary, macOS keeps the panel out of other apps' full-screen spaces.
    private static func spaces() -> NSWindow.CollectionBehavior {
        UserDefaults.standard.bool(forKey: "hideInFullscreen") ? [.canJoinAllSpaces, .stationary] : [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
    private func sessionName(_ source: String, _ session: String) -> String? {
        let id = source == "claude" ? "claude:" + session.lowercased() : source + ":" + session
        return store.sessions.first { $0.id == id }?.title
    }
    /// Goes to the session's terminal. The panel closes once that worked, and stays open to say so if not.
    private func jump(to session: SessionItem) {
        if let link = session.jumpURL, let url = URL(string: link) {
            if NSWorkspace.shared.open(url) { collapseAfterJump() } else { claudeApproval?.notice("无法打开这个对话，请确认对应的应用已安装。") }
            return
        }
        guard let pid = session.pid else {
            claudeApproval?.notice("这个会话没有进程信息，无法跳转。")
            return
        }
        Task { [weak self] in
            let problem = await SessionJump.perform(pid: pid)
            guard let self else { return }
            if let problem { self.claudeApproval?.notice(problem) } else { self.collapseAfterJump() }
        }
    }
    /// The pointer is still over the island, and must not reopen it. A pending request stays visible.
    private func collapseAfterJump() {
        guard claudeApproval?.pending.isEmpty != false else { return }
        hoverWork?.cancel()
        hoverSuppressed = true
        expandedByHover = false
        setExpanded(false)
        releaseHoverWhenPointerLeaves()
    }
    private func releaseHoverWhenPointerLeaves() {
        if !pointerIsOverIsland() { hoverSuppressed = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.releaseHoverWhenPointerLeaves() }
    }
    private func showIslandMenu(with event: NSEvent) {
        guard let view = panel?.contentView else { return }
        // A right-click means the menu, not the panel. Stop a hover that is about to open it, and undo
        // one that just did. An island opened on purpose, or showing a request, stays as it is.
        hoverWork?.cancel()
        hoverSuppressed = true
        if presentation.expanded && expandedByHover && claudeApproval?.pending.isEmpty != false {
            expandedByHover = false
            setExpanded(false)
        }
        defer { releaseHoverWhenPointerLeaves() }
        let menu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Agent Island", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
    private static func findCodex() -> URL {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        let candidates = paths + ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
        return URL(fileURLWithPath: candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/codex")
    }
}



MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = IslandController()
    app.delegate = delegate
    app.run()
}
