// Renders the real RootIsland through its open and close animations into one contact sheet, so the
// motion can be inspected frame by frame. Off-screen and in-process: it does not measure frame rate.
import AppKit
import SwiftUI

@MainActor final class Motion: NSObject, NSApplicationDelegate {
    let store = SessionStore(demo: false)
    let presentation = IslandPresentation()
    var host: NSView?
    let reader = AgentUsageReader()
    /// How far each frame's island is from the window's centre, in pixels. The collapsed shift is 5 points,
    /// which is 10 pixels here: anything well above that means the island slid.
    var offCentre: [Double] = []
    /// Whether a 200-point housing at the window's centre stayed completely covered in every frame.
    var coveredNotch = true
    func frame(for size: CGSize) -> NSRect {
        let m = IslandMetrics.shadowMargin
        return NSRect(x: -4000 - (size.width + m * 2) / 2, y: -4000, width: size.width + m * 2, height: size.height + m)
    }
    var window: NSPanel?
    var frames: [NSBitmapImageRep] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.syncClaudeLive([
            ClaudeLiveSession(sessionID: "aaaaaaaa-1", cwd: "/fictional/示例项目", startedAt: Date(), name: "接口重构"),
            ClaudeLiveSession(sessionID: "bbbbbbbb-2", cwd: "/fictional/示例项目", startedAt: Date(), name: "界面调整"),
            ClaudeLiveSession(sessionID: "cccccccc-3", cwd: "/fictional/agent-island", startedAt: Date()),
        ])
        store.observeClaude(sessionID: "aaaaaaaa-1", event: "PreToolUse", notification: nil, at: Date())
        store.observeClaude(sessionID: "bbbbbbbb-2", event: "PermissionRequest", notification: nil, at: Date())
        store.updateClaudeActivity(["aaaaaaaa-1": SessionActivity(task: "把虚构页面改好", step: "运行 跑虚构测试",
                                                                   todos: [SessionTodo(text: "看代码", state: "completed"), SessionTodo(text: "正在改页面", state: "in_progress"), SessionTodo(text: "跑测试", state: "pending")],
                                                                   subagents: [SessionSubagent(id: "s1", name: "Explore", task: "查虚构资料", step: "读取 a.swift", running: true)])])
        let defaults = UserDefaults(suiteName: "island.motion.\(UUID().uuidString)")!
        let sound = SoundManager(store: store, defaults: defaults, play: { _, _ in })
        let approval = ClaudeApprovalBridge(script: URL(fileURLWithPath: "/nonexistent"))
        presentation.contentHeight = 400
        let width: CGFloat = 708, height: CGFloat = 428
        let panel = NSPanel(contentRect: NSRect(x: -4000, y: -4000, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        // A notched screen's real numbers, and a window that resizes exactly as the app's does.
        presentation.geometry = IslandGeometry(notchWidth: 200, notchHeight: 37)
        presentation.size = presentation.geometry.collapsed
        presentation.centerOffset = presentation.geometry.collapsedOffset
        panel.setFrame(frame(for: presentation.size), display: false)
        let view = makeIslandContainer(root: RootIsland(store: store, sound: sound, approval: approval, presentation: presentation, usage: reader, onToggle: {}, onSettings: {}, onHover: { _ in }), windowSize: panel.frame.size)
        panel.contentView = view
        panel.orderFrontRegardless()
        host = view; window = panel
        Task { await self.run() }
    }

    func capture() {
        guard let view = host, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        frames.append(rep)
        // Find the black island in the top pixel row of the bitmap.
        var first: Int?, last: Int?
        for x in 0..<rep.pixelsWide {
            if let colour = rep.colorAt(x: x, y: 2), colour.alphaComponent > 0.5, colour.brightnessComponent < 0.05 {
                if first == nil { first = x }
                last = x
            }
        }
        if let first, let last {
            let centre = Double(rep.pixelsWide - 1) / 2, scale = Double(rep.pixelsWide) / Double(view.bounds.width)
            offCentre.append(abs(Double(first + last) / 2 - centre))
            if Double(first) > centre - 100 * scale + 1 || Double(last) < centre + 100 * scale - 1 { coveredNotch = false }
        }
    }

    func run() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        capture()
        window?.setFrame(frame(for: CGSize(width: 652, height: 400)), display: true)
        withAnimation(IslandMetrics.open) { presentation.expanded = true; presentation.size = CGSize(width: 652, height: 400); presentation.centerOffset = 0 }
        for _ in 0..<7 { try? await Task.sleep(nanoseconds: 80_000_000); capture() }
        withAnimation(IslandMetrics.close) { presentation.expanded = false; presentation.size = presentation.geometry.collapsed; presentation.centerOffset = presentation.geometry.collapsedOffset }
        for _ in 0..<7 { try? await Task.sleep(nanoseconds: 60_000_000); capture() }
        let columns = 4, scale: CGFloat = 0.5
        let cellW = CGFloat(frames.map(\.pixelsWide).max() ?? 0) * scale / 2, cellH = CGFloat(frames.map(\.pixelsHigh).max() ?? 0) * scale / 2
        let rows = Int(ceil(Double(frames.count) / Double(columns)))
        let sheet = NSImage(size: NSSize(width: cellW * CGFloat(columns), height: cellH * CGFloat(rows)))
        sheet.lockFocus()
        for (index, rep) in frames.enumerated() {
            let x = CGFloat(index % columns) * cellW, y = sheet.size.height - CGFloat(index / columns + 1) * cellH
            let w = CGFloat(rep.pixelsWide) * scale / 2, h = CGFloat(rep.pixelsHigh) * scale / 2
            NSColor.darkGray.setFill(); NSRect(x: x, y: y, width: cellW - 2, height: cellH - 2).fill()
            rep.draw(in: NSRect(x: x + (cellW - w) / 2, y: y + cellH - h, width: w, height: h))
        }
        sheet.unlockFocus()
        if let tiff = sheet.tiffRepresentation, let out = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? out.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        let worst = offCentre.max() ?? -1
        print("frames:", frames.count, "worst off-centre px:", worst, "samples:", offCentre.count)
        // Beside a 200-wide housing: 36 on the left, 26 on the right, and the housing always covered.
        let collapsed = presentation.geometry.collapsed
        guard offCentre.count == frames.count, worst <= 12, coveredNotch, collapsed.width == 262, collapsed.height == 37, presentation.geometry.collapsedOffset == -5 else {
            print("FAILED: island is off-centre, wrongly sized, or uncovered the housing", collapsed, coveredNotch); exit(1)
        }
        print("housing covered in every frame:", coveredNotch)
        // The settled state the app ends in: a window exactly the island's size, off-centre by the shift.
        let middle: CGFloat = -4000
        let settled = NSRect(x: middle + presentation.centerOffset - collapsed.width / 2, y: -4000, width: collapsed.width, height: collapsed.height)
        (host as? IslandContainerView)?.hostCenterX = middle - settled.minX
        window?.setFrame(settled, display: true)
        host?.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let view = host, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        var filled = 0
        for x in 0..<rep.pixelsWide { if let c = rep.colorAt(x: x, y: rep.pixelsHigh / 2), c.alphaComponent > 0.5 { filled += 1 } }
        print("settled window", Int(rep.pixelsWide), "px; opaque px in the middle row:", filled)
        guard filled == rep.pixelsWide else { print("FAILED: the settled island does not fill its window"); exit(1) }
        // Drawn back for the system's »: nothing beside the housing, in a window wider than the island.
        presentation.size = CGSize(width: presentation.geometry.notchWidth, height: presentation.geometry.notchHeight)
        presentation.centerOffset = 0
        let wider: CGFloat = 320
        (host as? IslandContainerView)?.hostCenterX = wider / 2
        window?.setFrame(NSRect(x: middle - wider / 2, y: -4000, width: wider, height: collapsed.height), display: true)
        host?.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let view2 = host, let rep2 = view2.bitmapImageRepForCachingDisplay(in: view2.bounds) else { exit(1) }
        view2.cacheDisplay(in: view2.bounds, to: rep2)
        var drawn: [Int] = []
        for x in 0..<rep2.pixelsWide { if let c = rep2.colorAt(x: x, y: rep2.pixelsHigh / 2), c.alphaComponent > 0.5 { drawn.append(x) } }
        let drawnScale = rep2.pixelsWide / Int(wider), edge = (rep2.pixelsWide - Int(presentation.geometry.notchWidth) * drawnScale) / 2
        print("drawn back: opaque px", drawn.first ?? -1, "...", drawn.last ?? -1, "of", rep2.pixelsWide)
        guard let low = drawn.first, let high = drawn.last, low >= edge - 2, high <= rep2.pixelsWide - edge + 2 else {
            print("FAILED: the island shows beside the housing while drawn back"); exit(1)
        }
        NSApp.terminate(nil)
    }
}
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { Motion() }
app.delegate = delegate
app.run()
