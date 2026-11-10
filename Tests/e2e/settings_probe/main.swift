// Renders every settings page to a PNG, with fictional state, so the layout can be looked at.
// Compile with every file in Sources/IslandReplica except main.swift. Nothing is started and no
// real setting is read: the Bark file is a temporary one and defaults belong to this probe.
import AppKit
import SwiftUI

struct SilentNotifications: IslandNotificationTransport {
    func requestPermission() async throws -> Bool { false }
    func send(body: String) async throws {}
}

@MainActor func render(_ section: SettingsSection, to directory: String) {
    let store = SessionStore(demo: false)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("settings-probe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let bark = BarkNotifier(file: nil, away: { false }, send: { _ in 200 })
    bark.settings.deviceKey = "FICTIONALKEY"; bark.settings.enabled = true
    let view = SettingsView(
        adapter: CodexSessionAdapter(store: store, transport: CodexProcessTransport(executable: URL(fileURLWithPath: "/nonexistent"))),
        reader: CodexRolloutReader(store: store, root: scratch, inspectOpenFiles: false),
        claude: ClaudeSessionReader(store: store, root: scratch),
        approval: ClaudeApprovalBridge(script: URL(fileURLWithPath: "/nonexistent"), arguments: []),
        observer: ClaudeObserverBridge(store: store, script: URL(fileURLWithPath: "/nonexistent"), runtime: scratch),
        spool: ClaudeSpoolReader(store: store, root: scratch, spool: scratch),
        sound: SoundManager(store: store, defaults: UserDefaults(suiteName: "island.settings.probe")!, play: { _, _ in }),
        hotkeys: HotkeyManager(onActivate: {}),
        notifications: NotificationManager(transport: SilentNotifications()),
        bark: bark, usage: AgentUsageReader(), section: section)
    let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 760, height: 560), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "设置"
    window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view)
    window.contentView = host
    window.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    host.layoutSubtreeIfNeeded()
    guard let frameView = host.superview ?? window.contentView, let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory + "/" + section.rawValue + ".png"))
    window.close()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let directory = CommandLine.arguments[1]
MainActor.assumeIsolated {
    NSApp.appearance = NSAppearance(named: .darkAqua)
    for section in SettingsSection.allCases { render(section, to: directory) }
    // The Bark sheet, on its own.
    let bark = BarkNotifier(file: nil, away: { false }, send: { _ in 200 })
    bark.settings.deviceKey = "FICTIONALKEY"; bark.settings.includeSessionName = true
    bark.generateEncryptionKeys(); bark.settings.encrypted = true
    let host = NSHostingView(rootView: BarkSetupSheet(bark: bark))
    let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 500, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory + "/bark-sheet.png"))
    }
}
print("rendered")
