import SwiftUI

/// The eight session states, in the order the original app declares them. Colours and glyph layouts
/// come from its machine code; see docs/reference/vibe-island-visuals.md for addresses and confidence.
enum IslandPhase: Int {
    case waitingForInput, processing, thinking, runningTool, waitingForApproval, question, compacting, ended
    /// Not a state in the original, which has no separate error colour on this icon.
    case failed

    var color: Color {
        switch self {
        case .waitingForInput: return .green
        case .processing, .runningTool: return .blue
        case .thinking, .compacting: return .purple
        case .waitingForApproval, .question: return .orange
        case .ended: return .gray
        case .failed: return .red
        }
    }

    var title: String {
        switch self {
        case .waitingForInput: return "等待输入"
        case .processing: return "处理中"
        case .thinking: return "思考中"
        case .runningTool: return "执行工具"
        case .waitingForApproval: return "等待审批"
        case .question: return "等待回答"
        case .compacting: return "压缩中"
        case .ended: return "已结束"
        case .failed: return "异常"
        }
    }

    /// Whether the glyph changes from frame to frame.
    var animates: Bool {
        switch self {
        case .waitingForInput, .processing, .thinking, .runningTool, .compacting: return true
        default: return false
        }
    }
}

extension SessionItem {
    var phase: IslandPhase {
        switch status {
        case .idle: return .waitingForInput
        case .waiting: return activity?.step == "提问" ? .question : .waitingForApproval
        case .error: return .failed
        case .unknown: return .ended
        case .working:
            if detail.hasPrefix("压缩中") { return .compacting }
            return activity?.step == nil ? .thinking : .runningTool
        }
    }
}

func sessionTint(_ session: SessionItem?) -> Color { (session?.phase ?? .ended).color }

/// The pixel creature: 8x8 on its own, 13 columns wide with a status glyph to its right.
/// One cell is min(width / columns, height / 8), inset by 0.15 points on every side, as in the original.
struct PixelStatusIcon: View {
    let phase: IslandPhase
    var compact = false

    /// Rectangles (x, y) of the tinted body. Eyes are drawn separately in black.
    private static let body: [(Int, Int)] = [(2, 2), (5, 2), (1, 3), (3, 3), (4, 3), (6, 3), (1, 4), (2, 4), (3, 4), (4, 4), (5, 4), (6, 4)]
    private static let eyes: [(Int, Int)] = [(2, 3), (5, 3)]
    private static let legs: [(Int, Int)] = [(2, 5), (3, 5), (5, 5), (6, 5)]
    private static let cross: [(Int, Int)] = [(9, 2), (12, 2), (10, 3), (11, 3), (10, 4), (11, 4), (9, 5), (12, 5)]
    private static let questionMark: [(Int, Int)] = [(10, 1), (11, 1), (9, 2), (12, 2), (12, 3), (11, 4), (10, 6), (11, 6)]
    /// An approximation: the original walks a table of eight cells, which was not decoded.
    private static let orbit: [(Int, Int)] = [(10, 2), (11, 2), (12, 3), (12, 4), (11, 5), (10, 5), (9, 4), (9, 3)]
    static let frameInterval: TimeInterval = 0.125

    /// The status glyph for one animation frame, as (x, y, opacity).
    static func glyph(_ phase: IslandPhase, frame: Int) -> [(Int, Int, Double)] {
        let step = ((frame % 8) + 8) % 8
        switch phase {
        case .ended, .failed: return cross.map { ($0.0, $0.1, 1) }
        case .waitingForApproval, .question: return questionMark.map { ($0.0, $0.1, 1) }
        case .waitingForInput: return step < 5 ? [(10, 4, 1), (11, 4, 1)] : []
        case .processing, .runningTool:
            var cells: [(Int, Int, Double)] = [(10, 3, 1), (11, 3, 1), (10, 4, 1), (11, 4, 1)]
            for trail in 0..<4 {
                let cell = orbit[((step - trail) % 8 + 8) % 8]
                cells.append((cell.0, cell.1, 1 - Double(trail) * 0.28))
            }
            return cells
        case .thinking:
            // Approximation of the original's six fading cells.
            return [(10, 3), (11, 3), (10, 4), (11, 4), (10, 5), (11, 5)].enumerated().map { index, cell in
                let distance = ((step - index) % 6 + 6) % 6
                return (cell.0, cell.1, max(0.2, 1 - Double(distance) * 0.25))
            }
        case .compacting:
            let rows = 1 + (step / 2)
            return (0..<rows).flatMap { row in [(10, 6 - row, 1.0), (11, 6 - row, 1.0)] }
        }
    }

    var body: some View {
        if phase.animates && !compact {
            TimelineView(.periodic(from: .now, by: Self.frameInterval)) { context in
                canvas(frame: Int(context.date.timeIntervalSinceReferenceDate / Self.frameInterval))
            }
        } else {
            canvas(frame: 0)
        }
    }

    private func canvas(frame: Int) -> some View {
        Canvas { context, size in
            let columns: CGFloat = compact ? 8 : 13
            let pixel = min(size.width / columns, size.height / 8)
            context.translateBy(x: (size.width - columns * pixel) / 2, y: (size.height - 8 * pixel) / 2)
            func draw(_ x: Int, _ y: Int, _ color: Color) {
                let cell = CGRect(x: CGFloat(x) * pixel + 0.15, y: CGFloat(y) * pixel + 0.15, width: pixel - 0.3, height: pixel - 0.3)
                context.fill(Path(cell), with: .color(color))
            }
            for cell in Self.body { draw(cell.0, cell.1, phase.color) }
            for cell in Self.eyes { draw(cell.0, cell.1, .black) }
            for cell in Self.legs { draw(cell.0, cell.1, phase.color) }
            if !compact {
                for cell in Self.glyph(phase, frame: frame) { draw(cell.0, cell.1, phase.color.opacity(cell.2)) }
            }
        }
    }
}
