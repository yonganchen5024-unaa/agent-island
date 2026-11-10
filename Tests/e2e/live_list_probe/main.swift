// Prints the Claude rows the island would show, from the real registry and real spool-less state.
// Output is only folder name, session prefix and state, never conversation content.
import Foundation
@main struct Probe {
    @MainActor static func main() async throws {
        let store = SessionStore(demo: false)
        let live = ClaudeLiveScan.scan(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions"))
        store.syncClaudeLive(live)
        print("rows:", store.sessions.count)
        for row in store.sessions { print(" ", row.title, "|", row.agent, "|", row.status.rawValue, "|", row.detail) }
    }
}
