// In-process GUI harness for the real SwiftUI approval card and the real ClaudeApprovalBridge.
// It delivers real mouse-down/up events to the card's window, so SwiftUI's own hit-testing picks
// the button. This needs no system permission but is not an on-screen pointer click. It is compiled
// only by Tests/e2e/run_gui_approval.py, so the shipped app has no way to click its own buttons.
import AppKit
import Combine
import SwiftUI

func emitLine(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) {
        print(text); fflush(stdout)
    }
}

@MainActor final class Harness: NSObject, NSApplicationDelegate {
    let args: [String: [String]]
    let bridge: ClaudeApprovalBridge
    let store = SessionStore(demo: false)
    let presentation = IslandPresentation()
    var window: NSPanel?
    var host: NSHostingView<AnyView>?
    var bag = Set<AnyCancellable>()
    var handled = Set<String>()
    var snapshotCount = 0
    /// The real notifier and event mapping. The transport only reports what would have left this Mac.
    lazy var bark: BarkNotifier = {
        let notifier = BarkNotifier(file: nil, away: { false }, send: { request in
            emitLine(["event": "bark", "url": request.url?.absoluteString ?? "", "body": String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""])
            return 200
        })
        notifier.settings.deviceKey = "FICTIONALKEY"; notifier.settings.enabled = true
        notifier.settings.awayOnly = false  // this harness checks the event mapping, not presence
        return notifier
    }()

    init(args: [String: [String]]) {
        self.args = args
        bridge = ClaudeApprovalBridge(script: URL(fileURLWithPath: args["broker"]![0]), arguments: ["--runtime-dir", args["runtime"]![0]])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let panel = NSPanel(contentRect: NSRect(x: -4000, y: -4000, width: 652, height: 430), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = true; panel.backgroundColor = .black
        let bridge = self.bridge
        // The island's real root view, with the sound manager muted and a pinned expanded state.
        let defaults = UserDefaults(suiteName: "island.gui.harness.\(UUID().uuidString)")!
        let sound = SoundManager(store: store, defaults: defaults, play: { _, _ in })
        presentation.expanded = true
        presentation.size = CGSize(width: 652, height: 430)
        presentation.contentHeight = 430
        let root = AnyView(RootIsland(store: store, sound: sound, approval: bridge, presentation: presentation, usage: AgentUsageReader(), onToggle: {}, onSettings: {}, onHover: { _ in }).frame(width: 652, height: 430).background(Color.gray.opacity(0.35)))
        let view = NSHostingView(rootView: root)
        panel.contentView = view
        panel.orderFrontRegardless()
        window = panel; host = view
        bridge.$state.sink { state in emitLine(["event": "state", "state": String(describing: state)]) }.store(in: &bag)
        bridge.$pending.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] list in self?.pendingChanged(list) }.store(in: &bag)
        bridge.$lastOutcome.dropFirst().receive(on: DispatchQueue.main).sink { outcome in
            if let outcome { emitLine(["event": "outcome", "text": outcome.text]) }
        }.store(in: &bag)
        bridge.onRequest = { [weak self] request in self?.bark.notify(request, session: "虚构会话名") }
        bridge.onLifecycle = { [weak self] event in self?.bark.notify(event, session: "虚构会话名") }
        bridge.start()
        FileHandle.standardInput.readabilityHandler = { handle in
            if handle.availableData.isEmpty { DispatchQueue.main.async { bridge.stop(); NSApp.terminate(nil) } }
        }
    }

    func pendingChanged(_ list: [ClaudeApprovalRequest]) {
        emitLine(["event": "pending", "count": list.count, "tools": list.map(\.toolName), "inputs": list.map(\.toolInputText),
                  "modes": list.map { $0.permissionMode ?? "" }, "hints": list.map { $0.hint?.removals.map(\.statement) ?? [] },
                  "hintTitles": list.map { $0.hint?.title ?? "" }])
        guard let request = list.first, !handled.contains(request.id) else { return }
        handled.insert(request.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.act(on: request) }
    }

    func snapshot() {
        guard let view = host, let path = args["snapshot"]?.first else { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let name = path + "-\(snapshotCount).png"; snapshotCount += 1
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: name))
        emitLine(["event": "snapshot", "path": name])
    }

    func act(on request: ClaudeApprovalRequest) {
        snapshot()
        guard let panel = window else { return }
        // --click "label@x,y": points measured from the card window's top-left, read off a snapshot.
        for item in args["click"] ?? [] {
            let parts = item.split(separator: "@")
            let xy = parts[1].split(separator: ",").compactMap { Double($0) }
            let point = NSPoint(x: xy[0], y: panel.frame.height - xy[1])
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    panel.sendEvent(event)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            }
            emitLine(["event": "pressed", "label": String(parts[0]), "ok": true])
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
        snapshot()
    }
}

var parsed: [String: [String]] = [:]
var index = 1
let all = CommandLine.arguments
while index + 1 < all.count { parsed[String(all[index].dropFirst(2)), default: []].append(all[index + 1]); index += 2 }
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { Harness(args: parsed) }
app.delegate = delegate
app.run()
