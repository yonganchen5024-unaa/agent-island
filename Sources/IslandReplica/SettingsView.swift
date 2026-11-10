import SwiftUI

/// The settings window. Page names, their order and the 高级 group come from the original's strings.
/// Its 通行证, SSH 远程 and 实验室 pages are left out because nothing here backs them. Which pages sit
/// in the group, and the icons, are inferred: the original's window has not been compared on screen.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, sound, notifications, display, integrations, usage, shortcuts, diagnostics, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "通用"
        case .sound: return "声音"
        case .notifications: return "通知"
        case .display: return "显示"
        case .integrations: return "集成"
        case .usage: return "用量"
        case .shortcuts: return "快捷键"
        case .diagnostics: return "连接状态"
        case .about: return "关于"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .sound: return "speaker.wave.2.fill"
        case .notifications: return "bell.fill"
        case .display: return "macwindow"
        case .integrations: return "puzzlepiece.extension.fill"
        case .usage: return "chart.bar.doc.horizontal"
        case .shortcuts: return "keyboard"
        case .diagnostics: return "wrench.and.screwdriver"
        case .about: return "info.circle.fill"
        }
    }
    static let groups: [(title: String?, items: [SettingsSection])] = [
        (nil, [.general, .sound, .notifications, .display]),
        ("高级", [.integrations, .usage, .shortcuts, .diagnostics]),
        (nil, [.about]),
    ]
}

struct SettingsView: View {
    @ObservedObject var adapter: CodexSessionAdapter
    @ObservedObject var reader: CodexRolloutReader
    @ObservedObject var claude: ClaudeSessionReader
    @ObservedObject var approval: ClaudeApprovalBridge
    @ObservedObject var observer: ClaudeObserverBridge
    @ObservedObject var spool: ClaudeSpoolReader
    @ObservedObject var sound: SoundManager
    @ObservedObject var hotkeys: HotkeyManager
    @ObservedObject var notifications: NotificationManager
    @ObservedObject var bark: BarkNotifier
    @ObservedObject var usage: AgentUsageReader
    @State var section: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title).font(.system(size: 20, weight: .semibold)).padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 2)
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SettingsSection.groups.enumerated()), id: \.offset) { _, group in
                if let title = group.title {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.top, 12).padding(.bottom, 3)
                } else {
                    Color.clear.frame(height: 6)
                }
                ForEach(group.items) { item in
                    Button { section = item } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.icon).font(.system(size: 13)).frame(width: 18)
                            Text(item.title).font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(section == item ? Color.white : Color.primary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(section == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(item.title)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.top, 38).padding(.bottom, 12)
        .frame(width: 184)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .general: GeneralSettings()
        case .sound: SoundSettings(sound: sound)
        case .notifications: NotificationSettings(notifications: notifications, bark: bark)
        case .display: DisplaySettings()
        case .integrations: IntegrationSettings(approval: approval, spool: spool)
        case .usage: UsageSettings(usage: usage)
        case .shortcuts: ShortcutSettings(hotkeys: hotkeys)
        case .diagnostics: DiagnosticsSettings(adapter: adapter, reader: reader, claude: claude, approval: approval, observer: observer, spool: spool)
        case .about: AboutSettings()
        }
    }
}

/// Whether each agent's own configuration currently points at the island. Read when the page is shown.
private enum AgentLink {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static func file(_ path: String, contains text: String) -> Bool {
        (try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8))?.contains(text) == true
    }
    static var codex: Bool { file(".codex/hooks.json", contains: "claude_approval_hook.py") }
    static var dsh: Bool { file(".dsh/profiles/web/cordis.patch.yml", contains: "agent-island-dsh.mjs") }
    static var opencode: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins/agent-island.js").path) }
}

private struct GeneralSettings: View {
    @AppStorage("hoverExpand") private var hoverExpand = true
    @AppStorage("hoverDelay") private var hoverDelay = 0.2
    @AppStorage("autoCollapse") private var autoCollapse = true
    @AppStorage("hideInFullscreen") private var hideInFullscreen = false
    @AppStorage("enableMenuBarOverflowYield") private var overflowYield = true
    @AppStorage("disableClickToJump") private var clickJumpDisabled = false
    @AppStorage(SessionStore.idleTimeoutKey) private var idleTimeout = SessionStore.idleTimeoutDefault
    @State private var launchAtLogin = LoginItem.isEnabled
    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时打开", isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, value in LoginItem.set(value); launchAtLogin = LoginItem.isEnabled }
            }
            Section("展开") {
                Toggle("悬停时展开面板", isOn: $hoverExpand)
                LabeledContent("悬停延迟") {
                    HStack {
                        Slider(value: $hoverDelay, in: 0.1...2, step: 0.1).disabled(!hoverExpand).frame(width: 180)
                        Text(String(format: "%.1f 秒", hoverDelay)).monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                }
            }
            Section("收起") { Toggle("鼠标离开时自动收起", isOn: $autoCollapse) }
            Section("交互") {
                Toggle(isOn: $clickJumpDisabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("禁用点击跳转")
                        Text("开启后，点击会话不会自动切换到对应的终端或 IDE。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("显隐") {
                Picker(selection: $idleTimeout) {
                    Text("30 分钟").tag(1800.0)
                    Text("1 小时").tag(3600.0)
                    Text("2 小时（默认）").tag(7200.0)
                    Text("4 小时").tag(14400.0)
                    Text("8 小时").tag(28800.0)
                    Text("24 小时").tag(86400.0)
                    Text("永不清理").tag(0.0)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("空闲会话自动清理")
                        Text("只管 Claude 会话：超过这个时长没有新活动就隐藏，有新活动时重新出现。其他应用的会话固定空闲 10 分钟后隐藏。工作中和等待审批的会话不隐藏。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("全屏时隐藏", isOn: $hideInFullscreen)
                Toggle(isOn: $overflowYield) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("为隐藏的菜单栏图标让位")
                        Text("点开菜单栏的 » 时，小岛收回刘海内，露出旁边的图标。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

/// The login item is a plain launchd agent file. Removing it takes effect at the next login.
enum LoginItem {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.agentisland.app.plist")
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: file.path) }
    static func set(_ enabled: Bool) {
        if !enabled { try? FileManager.default.removeItem(at: file); return }
        let executable = Bundle.main.executablePath ?? "/Applications/Agent Island.app/Contents/MacOS/IslandReplica"
        let plist: [String: Any] = ["Label": "local.agentisland.app", "ProgramArguments": [executable], "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false],
                                    "ThrottleInterval": 10, "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive"]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) { try? data.write(to: file, options: .atomic) }
    }
}

private struct SoundSettings: View {
    @ObservedObject var sound: SoundManager
    var body: some View {
        Form {
            Section {
                Toggle("启用提示音", isOn: $sound.enabled)
                LabeledContent("音量") { Slider(value: $sound.volume, in: 0...1).frame(width: 220) }
            }
            Section("事件") {
                ForEach(IslandSoundCue.allCases) { cue in
                    HStack {
                        Toggle(cue.title, isOn: Binding(get: { sound.isEnabled(cue) }, set: { sound.setEnabled($0, for: cue) }))
                        Spacer()
                        Button { sound.preview(cue) } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).help("试听")
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    @ObservedObject var notifications: NotificationManager
    @ObservedObject var bark: BarkNotifier
    @State private var configuring = false
    /// Turning it on before there is a key goes straight to where the key is entered.
    private var enabledBinding: Binding<Bool> {
        Binding(get: { bark.settings.enabled }, set: { on in
            bark.settings.enabled = on
            if on && !bark.settings.isConfigured { configuring = true }
        })
    }
    private var statusText: String {
        if !bark.settings.isConfigured { return "未配置" }
        return bark.lastFailure == nil ? "" : "需要重新连接"
    }
    var body: some View {
        Form {
            Section("系统通知") {
                LabeledContent("macOS 通知") {
                    HStack {
                        switch notifications.state {
                        case .disabled: Text("未启用").foregroundStyle(.secondary)
                        case .requesting: Text("等待授权").foregroundStyle(.secondary)
                        case .enabled: Text("已启用").foregroundStyle(.secondary)
                        case .denied: Text("系统未授权").foregroundStyle(.secondary)
                        case .failed(let message): Text(message).foregroundStyle(.secondary)
                        }
                        Button(notifications.enabled ? "停用" : "启用") {
                            if notifications.enabled { notifications.disable() } else { notifications.requestPermissionAndEnable() }
                        }.disabled(notifications.state == .requesting)
                    }
                }
            }
            Section("移动通知") {
                Toggle(isOn: enabledBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("通知我的 iPhone")
                        Text("需要在 iPhone 上安装免费的 Bark App。审批和回复仍然在 Mac 上进行。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Bark") {
                    HStack {
                        if !statusText.isEmpty { Text(statusText).foregroundStyle(.secondary) }
                        Button("配置…") { configuring = true }
                    }
                }
                if let failure = bark.lastFailure { Text(failure).font(.caption).foregroundStyle(.orange) }
            }
            Section("通知事件") {
                Toggle("审批请求", isOn: $bark.settings.approvals)
                Toggle("需要我回答的问题", isOn: $bark.settings.questions)
                Toggle(isOn: $bark.settings.completions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全部完工")
                        Text("所有会话都停止工作 1 分钟后通知一次。单轮结束和会话之间的对话不通知。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $bark.settings.warnings) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("每次异常结束")
                        Text("默认关闭。全部停止时的通知里会提到有异常。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $bark.settings.awayOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("仅在离开这台 Mac 时通知")
                        Text("屏幕锁定、熄灭或 Mac 闲置 2 分钟即视为离开。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.disabled(!bark.settings.enabled)
        }
        .formStyle(.grouped)
        .sheet(isPresented: $configuring) { BarkSetupSheet(bark: bark) }
    }
}

struct BarkSetupSheet: View {
    @ObservedObject var bark: BarkNotifier
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("连接 Bark、测试投递，并按需加密通知文字。").font(.callout).foregroundStyle(.secondary)
                }
                Section("连接") {
                    Picker("服务器", selection: $bark.settings.selfHosted) {
                        Text("Bark 公共服务").tag(false)
                        Text("自托管").tag(true)
                    }
                    if bark.settings.selfHosted {
                        TextField("地址", text: $bark.settings.server, prompt: Text("https://push.example.com"))
                        Text("使用 HTTPS Bark 服务器。地址里可以带 user:pass@，会作为 HTTP 基本认证发送。").font(.caption).foregroundStyle(.secondary)
                    }
                    SecureField("设备密钥", text: $bark.settings.deviceKey)
                    Text("在 Bark 首页的测试链接里，复制中间那一段（https://…/这段密钥/Body Text）。不是设置里的 Device Token。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(bark.testing ? "发送中…" : "发送测试") { bark.sendTest() }.disabled(bark.testing || !bark.settings.isConfigured)
                        if let result = bark.testResult { Text(result).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("隐私") {
                    Toggle(isOn: $bark.settings.includeSessionName) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("包含会话名称")
                            Text("默认只发事件类型。开启后加上会话名称，没有名称时用文件夹名。名称可能是 Claude 根据对话生成的。不会发送命令和对话正文。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: Binding(get: { bark.settings.encrypted }, set: { on in
                        if on && bark.settings.encryptionKey.isEmpty { bark.generateEncryptionKeys() }
                        bark.settings.encrypted = on
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("加密通知内容")
                            Text("标题和正文会在这台 Mac 上加密。Bark 服务器仍可看到设备密钥和投递元数据。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if bark.settings.encrypted {
                        Text("「推送加密」在 Bark 首页（第一个标签页）往下拉，不在设置页。选择 AES256、GCM、NoPadding，然后粘贴下面的 Key 和 IV。").font(.caption).foregroundStyle(.secondary)
                        CopyRow(title: "Key", value: bark.settings.encryptionKey)
                        CopyRow(title: "IV", value: bark.settings.encryptionIV)
                    } else if bark.settings.includeSessionName {
                        Text("未启用加密时，会话名称会以可读形式经过 Bark 服务器。它不会公开发布，但服务器运营者可能读取。").font(.caption).foregroundStyle(.orange)
                    }
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(14)
        }.frame(width: 500, height: 560).background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct CopyRow: View {
    let title: String
    let value: String
    @State private var copied = false
    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                Button(copied ? "已复制" : "复制") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); copied = true
                }
            }
        }
    }
}

private struct DisplaySettings: View {
    @AppStorage("notchWidthOffset") private var notchWidthOffset = 0.0
    @AppStorage("notchHeightOffset") private var notchHeightOffset = 0.0
    @AppStorage("maxPanelWidth") private var maxPanelWidth = 652.0
    @AppStorage("maxPanelHeight") private var maxPanelHeight = 700.0
    @AppStorage("showTasks") private var showTasks = true
    @AppStorage("showSubagents") private var showSubagents = true
    @AppStorage("showProjectName") private var showProjectName = true
    private func row(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, signed: Bool = false) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 200)
                Text(signed && value.wrappedValue > 0 ? "+\(Int(value.wrappedValue))" : "\(Int(value.wrappedValue))").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
        }
    }
    var body: some View {
        Form {
            Section("会话卡片") {
                Toggle("显示任务清单", isOn: $showTasks)
                Toggle(isOn: $showSubagents) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示子 Agent")
                        Text("关闭后改为显示运行中数量；审批和提问始终可见。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("显示项目名称", isOn: $showProjectName)
            }
            Section("面板尺寸") {
                row("最大面板宽度", $maxPanelWidth, 480...900, 4)
                row("最大面板高度", $maxPanelHeight, 300...900, 10)
            }
            Section {
                row("刘海宽度", $notchWidthOffset, -40...40, 1, signed: true)
                row("刘海高度", $notchHeightOffset, -10...10, 1, signed: true)
                Button("恢复默认") { notchWidthOffset = 0; notchHeightOffset = 0; maxPanelWidth = 652; maxPanelHeight = 700 }
            } header: { Text("微调") } footer: { Text("如果小岛和刘海贴合不完美，可在此微调刘海尺寸。0 表示使用 macOS 报告的尺寸。").font(.caption) }
        }.formStyle(.grouped)
    }
}

private struct IntegrationSettings: View {
    @ObservedObject var approval: ClaudeApprovalBridge
    @ObservedObject var spool: ClaudeSpoolReader
    private func row(_ name: String, _ status: String, _ ok: Bool) -> some View {
        LabeledContent(name) {
            HStack(spacing: 6) {
                Circle().fill(ok ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text(status).foregroundStyle(.secondary)
            }
        }
    }
    private var approvalStatus: String {
        switch approval.state {
        case .ready: return "审批已就绪"
        case .starting: return "启动中"
        case .stopped: return "审批已停止"
        case .failed(let message): return message
        }
    }
    var body: some View {
        Form {
            Section("Agent") {
                row("Claude Code", approvalStatus, approval.state == .ready)
                row("Codex", AgentLink.codex ? "显示会话和用量，可审批（完全访问模式下 Codex 不询问）" : "显示运行中的会话和用量，审批未接入", true)
                row("Kimi", "只读显示用量，会话和审批未接入", false)
                row("OpenCode", AgentLink.opencode ? "显示会话，可审批和回答提问（权限全部放行时不询问）" : "未接入", AgentLink.opencode)
                row("DSH", AgentLink.dsh ? "显示会话，沙箱提权时可审批（完全访问模式下不询问）" : "未接入", AgentLink.dsh)
                row("Gemini", "未接入", false)
            }
            Section {
                Text("使用审批需要以询问模式启动 Claude：claude --permission-mode default").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.formStyle(.grouped)
    }
}

private struct UsageSettings: View {
    @ObservedObject var usage: AgentUsageReader
    @AppStorage("showUsage") private var showUsage = true
    @AppStorage("usageShowsUsed") private var showsUsed = false
    private func reset(_ date: Date?) -> String {
        guard let date, date > Date() else { return "" }
        let minutes = Int(date.timeIntervalSinceNow / 60)
        if minutes >= 1440 { return "\(minutes / 1440) 天 \(minutes % 1440 / 60) 小时后重置" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟后重置" }
        return "\(minutes) 分钟后重置"
    }
    var body: some View {
        Form {
            Section {
                Toggle("显示用量限额", isOn: $showUsage)
                Picker("显示数值", selection: $showsUsed) {
                    Text("剩余量").tag(false)
                    Text("已用量").tag(true)
                }
            }
            Section("订阅用量") {
                if usage.usages.isEmpty { Text("正在读取…").foregroundStyle(.secondary) }
                ForEach(usage.usages) { agent in
                    if agent.windows.isEmpty {
                        LabeledContent(agent.name) { Text(agent.problem ?? "—").foregroundStyle(.secondary) }
                    }
                    ForEach(agent.windows, id: \.label) { window in
                        LabeledContent(agent.name + " · " + window.label) {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(showsUsed ? "已用 \(100 - window.remainingPercent)%" : "还剩 \(window.remainingPercent)%").monospacedDigit()
                                if !reset(window.resetsAt).isEmpty { Text(reset(window.resetsAt)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            Section { Text("约每 5 分钟刷新一次，打开面板时如果数据已旧也会刷新。").font(.callout).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    @ObservedObject var hotkeys: HotkeyManager
    var body: some View {
        Form {
            Section("全局快捷键") {
                LabeledContent("打开或收起面板（⌥⌘I）") {
                    HStack {
                        Text(hotkeys.message).font(.callout).foregroundStyle(.secondary)
                        Button(hotkeys.enabled ? "停用" : "启用") {
                            if hotkeys.enabled { hotkeys.stop() } else { hotkeys.start() }
                            UserDefaults.standard.set(hotkeys.enabled, forKey: "islandHotkeyEnabled")
                        }
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
    var body: some View {
        Form {
            Section {
                LabeledContent("Agent Island") { Text("版本 \(version)").foregroundStyle(.secondary) }
                Text("独立实现，界面和行为参考 Vibe Island。").font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

/// The lower-level channels, for diagnosis. Everyday use does not need this page.
private struct DiagnosticsSettings: View {
    @ObservedObject var adapter: CodexSessionAdapter
    @ObservedObject var reader: CodexRolloutReader
    @ObservedObject var claude: ClaudeSessionReader
    @ObservedObject var approval: ClaudeApprovalBridge
    @ObservedObject var observer: ClaudeObserverBridge
    @ObservedObject var spool: ClaudeSpoolReader
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            ClaudeApprovalView(bridge: approval)
            Divider()
            Text("Claude 历史会话").font(.headline)
            Text("实时会话列表不需要它。开启后会额外列出最近 7 天的历史会话。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(claude.status).font(.callout)
                Spacer()
                Button(claude.enabled ? "断开" : "连接") {
                    if claude.enabled { claude.stop() } else { claude.start() }
                    UserDefaults.standard.set(claude.enabled, forKey: "claudeLogEnabled")
                }
            }
            HStack {
                switch observer.state {
                case .stopped: Text("实时事件桥未启动")
                case .starting: Text("实时事件桥启动中…")
                case .ready: Text(observer.hookConfigured ? "实时事件桥已启动；Hook 已配置" : "实时事件桥已启动；需配置 Claude Hook")
                case .failed(let message): Text(message).foregroundStyle(.red)
                }
                Spacer()
                Button(observer.state == .ready || observer.state == .starting ? "停止" : "启动") {
                    if observer.state == .ready || observer.state == .starting {
                        observer.stop(); UserDefaults.standard.set(false, forKey:"claudeObserverEnabled")
                    } else {
                        observer.start(); UserDefaults.standard.set(true, forKey:"claudeObserverEnabled")
                    }
                }
            }.font(.callout)
            if observer.managedHooksOnly {
                Text("当前 Claude 策略仅允许运行受管 Hook，用户级实时 Hook 不会生效。")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text("受管文件观察：\(spool.status)")
                Spacer()
                Button(spool.enabled ? "停止" : "启用") {
                    if spool.enabled { spool.stop() } else { spool.start() }
                    UserDefaults.standard.set(spool.enabled, forKey:"claudeSpoolEnabled")
                }
            }.font(.callout)
            Text(spool.managedInstalled ? "受管观察 Hook 已配置；事件未经进程身份认证，不可用于审批。" : "此通道尚未加入受管 Hook；事件未经进程身份认证，不可用于审批。")
                .font(.caption).foregroundStyle(.secondary)
            if observer.hookConfigured {
                Button("移除 Claude 观察 Hook") { observer.removeConfiguredHooks() }.disabled(observer.configurationBusy)
                    .font(.callout)
            }
            if observer.receivedCount > 0 {
                Text("本次启动已接收 \(observer.receivedCount) 个事件；最近：\(observer.lastEventName ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = observer.configurationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            Divider()
            Text("Codex 本地会话日志").font(.headline)
            Text("读取最近的会话元数据和任务事件；运行状态根据日志推断，可能不准确。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(reader.status).font(.callout)
                Spacer()
                Button(reader.enabled ? "断开" : "读取") {
                    if reader.enabled {
                        reader.stop(); UserDefaults.standard.set(false, forKey: "codexLogEnabled")
                    } else {
                        adapter.stop(); reader.start(); UserDefaults.standard.set(true, forKey: "codexLogEnabled")
                    }
                }
            }
            Divider()
            Text("Codex 本地只读接入（实验）").font(.headline)
            Text("启用后读取本机 Codex 会话列表和状态，不展示消息内容。服务响应可能包含会话预览及路径，但本程序不显示或记录这些字段。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                switch adapter.state {
                case .stopped: Text("未连接")
                case .connecting: Text("连接中…")
                case .connected: Text("已连接")
                case .failed(let message): Text(message).foregroundStyle(.red)
                }
                Spacer()
                switch adapter.state {
                case .stopped, .failed: Button("连接") { reader.stop(); UserDefaults.standard.set(false, forKey: "codexLogEnabled"); adapter.start() }
                case .connecting, .connected: Button("断开") { adapter.stop() }
                }
            }.font(.callout)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
