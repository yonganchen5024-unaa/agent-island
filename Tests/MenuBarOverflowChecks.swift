import Foundation
// Compile with MenuBarOverflow.swift. The frames are the ones measured on the 1512-wide notched screen.
@main struct MenuBarOverflowChecks {
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let now = Date()
        var d = MenuBarOverflowDetector()
        func rect(_ a: CGFloat, _ b: CGFloat) -> CGRect { CGRect(x: a, y: 949, width: b - a, height: 33) }
        // Closed: the stand-in frame, right of the notch, whatever the run's width is at the moment.
        precondition(!d.isOpen(frame: rect(879, 895), screen: screen, now: now))
        precondition(!d.isOpen(frame: rect(872, 910), screen: screen, now: now))
        // Open: the real place, left of the notch.
        precondition(d.isOpen(frame: rect(502, 540), screen: screen, now: now))
        // Frames seen while an item is being created, and no frame at all, are not "open".
        var e = MenuBarOverflowDetector()
        precondition(!e.isOpen(frame: CGRect(x: 0, y: -33, width: 16, height: 33), screen: screen, now: now))
        precondition(!e.isOpen(frame: CGRect(x: 0, y: 982, width: 16, height: 33), screen: screen, now: now))
        precondition(!e.isOpen(frame: CGRect(x: 0, y: 949, width: 0, height: 33), screen: screen, now: now))
        // Seen in the real app's log for 4 ms when the item was created.
        precondition(!e.isOpen(frame: rect(0, 16), screen: screen, now: now))
        precondition(!e.isOpen(frame: nil, screen: screen, now: now))
        // Another display's menu bar is not this one's.
        let other = CGRect(x: -1920, y: 949, width: 16, height: 33)
        precondition(!e.isOpen(frame: other, screen: screen, now: now))
        precondition(!e.isOpen(frame: CGRect(x: 500, y: 2000, width: 16, height: 33), screen: screen, now: now))
        // A reading stuck on open gives up, so the island cannot stay hidden, and closing resets it.
        var f = MenuBarOverflowDetector()
        precondition(f.isOpen(frame: rect(502, 540), screen: screen, now: now))
        precondition(f.isOpen(frame: rect(502, 540), screen: screen, now: now.addingTimeInterval(29)))
        precondition(!f.isOpen(frame: rect(502, 540), screen: screen, now: now.addingTimeInterval(31)))
        precondition(!f.isOpen(frame: rect(872, 910), screen: screen, now: now.addingTimeInterval(32)))
        precondition(f.isOpen(frame: rect(502, 540), screen: screen, now: now.addingTimeInterval(33)))
        print("MenuBarOverflowChecks passed")
    }
}
