import AppKit
import Darwin

/// What the process table says about a session: its terminal device and the app that hosts it.
struct SessionHost: Equatable {
    var tty: String?
    var bundleID: String?
}

/// The process table behind SessionJump, replaceable so the checks can use fictional processes.
struct ProcessLookup {
    var parent: (Int32) -> Int32?
    var name: (Int32) -> String?
    var tty: (Int32) -> String?
    var app: (Int32) -> String?

    private static func info(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    static let system = ProcessLookup(
        parent: { info($0)?.kp_eproc.e_ppid },
        name: { pid in
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, 4096) > 0 else { return nil }
            return (String(cString: buffer) as NSString).lastPathComponent
        },
        tty: { pid in
            guard let device = info(pid)?.kp_eproc.e_tdev, device != -1, let name = devname(device, S_IFCHR) else { return nil }
            return SessionJump.ttyPath(String(cString: name))
        },
        app: { pid in
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return nil }
            return app.bundleIdentifier
        })
}

/// Clicking a session goes to its terminal. iTerm2 and Terminal can select the exact tab by device;
/// for any other app this only brings the app forward, and says so.
enum SessionJump {
    static let iTerm = "com.googlecode.iterm2"
    static let terminal = "com.apple.Terminal"

    /// The device name goes to AppleScript as an argument, and only in this shape.
    static func ttyPath(_ name: String) -> String? {
        guard name.hasPrefix("tty"), name.count > 3, name.count < 32, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "/dev/" + name
    }

    /// iTerm2 keeps a helper process per generation of itself, which outlives an upgrade. Its parent is
    /// then launchd, so the chain never reaches the app (seen on a real session), but the name says whose it is.
    static func host(of pid: Int32, lookup: ProcessLookup = .system) -> SessionHost {
        var result = SessionHost(tty: lookup.tty(pid), bundleID: nil)
        var current = pid
        for _ in 0..<32 {
            if let app = lookup.app(current) { result.bundleID = app; break }
            if lookup.name(current)?.hasPrefix("iTermServer") == true { result.bundleID = iTerm; break }
            guard let next = lookup.parent(current), next > 1, next != current else { break }
            current = next
        }
        return result
    }

    static func script(for bundleID: String) -> String? {
        switch bundleID {
        case iTerm:
            return """
            on run argv
              set target to item 1 of argv
              tell application id "com.googlecode.iterm2"
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if tty of s is target then
                        tell w to select
                        tell t to select
                        tell s to select
                        activate
                        return "found"
                      end if
                    end repeat
                  end repeat
                end repeat
              end tell
              return "missing"
            end run
            """
        case terminal:
            return """
            on run argv
              set target to item 1 of argv
              tell application id "com.apple.Terminal"
                repeat with w in windows
                  repeat with t in tabs of w
                    if tty of t is target then
                      set selected tab of w to t
                      set index of w to 1
                      activate
                      return "found"
                    end if
                  end repeat
                end repeat
              end tell
              return "missing"
            end run
            """
        default:
            return nil
        }
    }

    enum ScriptOutcome: Equatable { case found, missing, denied, failed }

    /// -1743 is macOS refusing the Automation permission.
    static func classify(status: Int32, output: String, errors: String) -> ScriptOutcome {
        if status == 0 { return output.trimmingCharacters(in: .whitespacesAndNewlines) == "found" ? .found : .missing }
        return errors.contains("-1743") ? .denied : .failed
    }

    private static func run(script: String, tty: String) async -> ScriptOutcome {
        await withCheckedContinuation { continuation in
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, tty]
            process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let out = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: classify(status: finished.terminationStatus, output: out, errors: err))
            }
            do { try process.run() } catch { continuation.resume(returning: .failed); return }
            // The first run waits for the user to answer the system's permission prompt.
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if process.isRunning { process.terminate() } }
        }
    }

    private static func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }

    @MainActor private static func bringForward(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Returns nil once the session is in front. Anything else is a sentence for the user.
    @MainActor static func perform(pid: Int32) async -> String? {
        let host = host(of: pid)
        // Without a host, look for the device in the terminals that can be asked.
        let running = [iTerm, terminal].filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        let candidates = host.bundleID.map { [$0] } ?? running
        guard let tty = host.tty, !candidates.isEmpty else {
            if let bundleID = host.bundleID {
                bringForward(bundleID)
                return "已切到 \(appName(bundleID))，这个会话没有终端设备，无法定位到具体位置。"
            }
            return "找不到这个会话所在的终端。"
        }
        var last: ScriptOutcome = .missing
        for bundleID in candidates {
            guard let script = script(for: bundleID) else { continue }
            last = await run(script: script, tty: tty)
            if last == .found { return nil }
            if last == .denied { break }
        }
        guard let bundleID = host.bundleID else { return "找不到这个会话所在的终端。" }
        bringForward(bundleID)
        let name = appName(bundleID)
        if script(for: bundleID) == nil { return "已切到 \(name)，这个应用还不能定位到具体标签页。" }
        switch last {
        case .denied: return "已切到 \(name)。要定位到标签页，请在系统设置的隐私与安全性、自动化里允许 Agent Island 控制它。"
        case .found: return nil
        case .missing: return "已切到 \(name)，但没有找到这个会话的标签页。"
        case .failed: return "已切到 \(name)，定位标签页时出错。"
        }
    }
}
