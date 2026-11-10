import CoreGraphics
import Foundation

/// Tells from one status item's window whether the system's » is open. Measured on Darwin 27.3: an
/// item collapsed behind » reports a stand-in frame right of the notch. It reports its real place,
/// left of the notch, only while » is open. The original learns this through accessibility
/// permission; reading our own item needs none.
struct MenuBarOverflowDetector {
    /// The system closes » by itself within seconds. If this reading ever goes wrong, the island must
    /// come back anyway rather than stay hidden.
    static let limit: TimeInterval = 30
    private var openSince: Date?

    mutating func isOpen(frame: CGRect?, screen: CGRect, now: Date) -> Bool {
        // A new item briefly reports the screen's left edge (measured: [0,16]). The Apple menu is there,
        // so no real item ever is.
        guard let frame, frame.width > 0, frame.minX >= screen.minX + 40, frame.maxX <= screen.midX,
              abs(frame.maxY - screen.maxY) < 2 else {
            openSince = nil
            return false
        }
        let since = openSince ?? now
        openSince = since
        return now.timeIntervalSince(since) < Self.limit
    }
}
