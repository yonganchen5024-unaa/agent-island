import CryptoKit
import Foundation
// Compile with BarkNotifier.swift. Fictional keys only, and a fake transport: nothing leaves this Mac.
@main struct BarkChecks {
    static func json(_ request: URLRequest) -> [String: Any] { (try! JSONSerialization.jsonObject(with: request.httpBody!)) as! [String: Any] }
    @MainActor static func main() async throws {
        var s = BarkSettings(); s.deviceKey = "FICTIONALKEY"
        // Default message: the event only, never a session name.
        let plain = BarkMessage.make(.approval, session: "接口重构", settings: s)
        precondition(plain.title == "需要审批" && plain.body == "请回到 Mac 批准或拒绝。")
        var named = s; named.includeSessionName = true
        precondition(BarkMessage.make(.approval, session: "接口重构", settings: named).title == "接口重构 · 需要审批")
        precondition(BarkMessage.make(.test, session: "x", settings: named).title == "Agent Island")
        // The request: public server, /push, JSON, and only the expected fields.
        let request = try BarkRequest.make(plain, settings: s, event: .approval)
        precondition(request.url?.absoluteString == "https://api.day.app/push" && request.httpMethod == "POST")
        let body = json(request)
        precondition(Set(body.keys) == ["device_key", "title", "body", "group", "level"] && body["device_key"] as? String == "FICTIONALKEY" && body["level"] as? String == "timeSensitive")
        let ordinary = try BarkRequest.make(plain, settings: s, event: .allDone); precondition(json(ordinary)["level"] == nil)
        // Self-hosted: HTTPS only, and credentials go to a header, not the URL.
        var hosted = s; hosted.selfHosted = true; hosted.server = "https://user:secret@push.example.com/base/"
        let viaHost = try BarkRequest.make(plain, settings: hosted, event: .warning)
        precondition(viaHost.url?.absoluteString == "https://push.example.com/base/push")
        precondition(viaHost.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("user:secret".utf8).base64EncodedString())
        hosted.server = "http://push.example.com"
        do { _ = try BarkRequest.make(plain, settings: hosted, event: .warning); preconditionFailure("http must be refused") } catch { precondition(error as? BarkFailure == .invalidServer) }
        var empty = BarkSettings(); empty.deviceKey = "   "
        do { _ = try BarkRequest.make(plain, settings: empty, event: .warning); preconditionFailure() } catch { precondition(error as? BarkFailure == .notConfigured) }
        // Encryption: no readable text in the request, and the ciphertext decrypts with key and IV.
        var secret = s; secret.encrypted = true; secret.encryptionKey = BarkKeys.key(); secret.encryptionIV = BarkKeys.iv()
        precondition(secret.encryptionKey.utf8.count == 32 && secret.encryptionIV.utf8.count == 12)
        let sealed = try BarkRequest.make(plain, settings: secret, event: .approval, randomIV: "FICTIONALIV1")
        let fields = json(sealed)
        precondition(Set(fields.keys) == ["device_key", "ciphertext", "iv"] && fields["iv"] as? String == "FICTIONALIV1")
        let raw = Data(base64Encoded: fields["ciphertext"] as! String)!
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data("FICTIONALIV1".utf8)), ciphertext: raw.dropLast(16), tag: raw.suffix(16))
        let opened = try AES.GCM.open(box, using: SymmetricKey(data: Data(secret.encryptionKey.utf8)))
        let decoded = try JSONSerialization.jsonObject(with: opened) as! [String: Any]; precondition(decoded["title"] as? String == "需要审批")
        var bad = secret; bad.encryptionKey = "short"
        do { _ = try BarkRequest.make(plain, settings: bad, event: .warning); preconditionFailure() } catch { precondition(error as? BarkFailure == .encryptionKey) }
        // Failures map to the messages shown in settings.
        precondition(BarkRequest.classify(status: 200) == nil && BarkRequest.classify(status: 400) == .deviceKey && BarkRequest.classify(status: 401) == .unauthorized && BarkRequest.classify(status: 404) == .endpoint && BarkRequest.classify(status: 500) == .server)
        precondition(BarkRequest.classify(error: URLError(.serverCertificateUntrusted)) == .certificate && BarkRequest.classify(error: URLError(.cannotConnectToHost)) == .unreachable)
        // Gating, through a fake transport.
        var sent: [URLRequest] = []
        var away = false
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bark-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let notifier = BarkNotifier(file: file, away: { away }, send: { request in sent.append(request); return 200 })
        func settle() async { try? await Task.sleep(nanoseconds: 80_000_000) }
        notifier.notify(.approval, session: nil); await settle()
        precondition(sent.isEmpty, "disabled and unconfigured must send nothing")
        notifier.settings.deviceKey = "FICTIONALKEY"; notifier.settings.enabled = true; notifier.settings.awayOnly = false
        notifier.notify(.approval, session: nil); await settle()
        precondition(sent.count == 1)
        notifier.settings.approvals = false
        notifier.notify(.approval, session: nil); await settle()
        precondition(sent.count == 1, "a switched-off event sends nothing")
        notifier.settings.warnings = true
        notifier.notify(.warning, session: nil, sessionKey: "a"); notifier.notify(.warning, session: nil, sessionKey: "a"); notifier.notify(.warning, session: nil, sessionKey: "b"); await settle()
        precondition(sent.count == 3, "one warning per session per 30 seconds")
        // A burst of parallel approvals buzzes once. Off-by-default fields would not survive this otherwise.
        notifier.settings.approvals = true
        notifier.notify(.approval, session: nil, sessionKey: "a"); notifier.notify(.approval, session: nil, sessionKey: "a"); await settle()
        precondition(sent.count == 4, "one approval per session per 5 seconds")
        sent.removeLast()
        notifier.settings.awayOnly = true; notifier.settings.warnings = true
        notifier.notify(.warning, session: nil); await settle()
        precondition(sent.count == 3, "at the Mac: nothing")
        away = true
        notifier.notify(.warning, session: nil); await settle()
        precondition(sent.count == 4, "away: delivered")
        notifier.sendTest(); await settle()
        precondition(notifier.testResult == "Bark 已接受，请检查设备。" && sent.count == 5)
        // All done: two sessions talking to each other, with short gaps, must stay silent.
        let t0 = Date()
        var gate = AllDoneGate()
        func at(_ working: Bool, _ s: TimeInterval) -> Bool { gate.update(anyWorking: working, now: t0.addingTimeInterval(s)) }
        precondition(!at(false, 0) && !at(false, 500), "nothing has happened yet: starting up with idle sessions is silent")
        precondition(!at(true, 600))
        for (working, s) in [(false, 630.0), (true, 640), (false, 700), (true, 710), (false, 765), (true, 770)] { precondition(!at(working, s), "\(s)") }
        precondition(!at(false, 800) && !at(false, 859))
        precondition(at(false, 860), "a full minute of quiet")
        precondition(!at(false, 900) && !at(false, 5000), "once, not repeatedly")
        precondition(!at(true, 5100) && !at(false, 5110) && at(false, 5171), "work resumed, so once more")
        // Through the notifier, with the words the phone shows, and a failed turn only mentioned.
        var words: [String] = []
        let quiet = BarkNotifier(file: nil, away: { false }, send: { request in words.append(json(request)["title"] as! String); return 200 })
        quiet.settings.deviceKey = "FICTIONALKEY"; quiet.settings.enabled = true; quiet.settings.awayOnly = false
        precondition(!quiet.settings.warnings && quiet.settings.completions, "defaults: only all done, approvals and questions")
        quiet.observeWork(anyWorking: true, now: t0)
        quiet.recordFailure(session: nil, sessionKey: "a"); await settle()
        precondition(words.isEmpty, "a failed turn does not buzz by itself")
        quiet.observeWork(anyWorking: false, now: t0.addingTimeInterval(1))
        quiet.observeWork(anyWorking: false, now: t0.addingTimeInterval(62)); await settle()
        precondition(words == ["工作已全部停止"], "\(words)")
        quiet.observeWork(anyWorking: true, now: t0.addingTimeInterval(100))
        quiet.observeWork(anyWorking: false, now: t0.addingTimeInterval(101))
        quiet.observeWork(anyWorking: false, now: t0.addingTimeInterval(162)); await settle()
        precondition(words == ["工作已全部停止", "全部完工"], "\(words)")
        quiet.settings.completions = false
        quiet.observeWork(anyWorking: true, now: t0.addingTimeInterval(200))
        quiet.observeWork(anyWorking: false, now: t0.addingTimeInterval(201))
        quiet.observeWork(anyWorking: false, now: t0.addingTimeInterval(262)); await settle()
        precondition(words.count == 2, "can be switched off")
        // Away only. Fake clock and fake input; nothing leaves this process.
        var idleFor: TimeInterval = 0, gone = false, pushed: [String] = []
        let desk = BarkNotifier(file: nil, away: { gone }, idle: { idleFor }, send: { request in pushed.append(json(request)["title"] as! String); return 200 })
        desk.settings.deviceKey = "FICTIONALKEY"; desk.settings.enabled = true
        precondition(desk.settings.awayOnly, "away-only is the default")
        func finish(from t: Date, idleAtFire: TimeInterval) {
            desk.observeWork(anyWorking: true, now: t); desk.observeWork(anyWorking: false, now: t.addingTimeInterval(1))
            idleFor = idleAtFire; desk.observeWork(anyWorking: false, now: t.addingTimeInterval(62))
        }
        // At the desk: touched the Mac after the work stopped. Leaving later must not bring the push back.
        finish(from: t0, idleAtFire: 10); await settle()
        desk.observeWork(anyWorking: false, now: t0.addingTimeInterval(64)); await settle()
        gone = true; desk.observeWork(anyWorking: false, now: t0.addingTimeInterval(300)); await settle()
        precondition(pushed.isEmpty, "at the desk for it: \(pushed)")
        gone = false
        // Walked off shortly before it finished: not "away" yet when it fires, so it waits, then goes.
        let t2 = t0.addingTimeInterval(1000)
        finish(from: t2, idleAtFire: 70); await settle()
        precondition(pushed.isEmpty, "held, not sent yet")
        idleFor = 72; desk.observeWork(anyWorking: false, now: t2.addingTimeInterval(64)); await settle()
        precondition(pushed.isEmpty, "still held")
        idleFor = 120; gone = true; desk.observeWork(anyWorking: false, now: t2.addingTimeInterval(112)); await settle()
        precondition(pushed == ["全部完工"], "left before it finished: \(pushed)")
        desk.observeWork(anyWorking: false, now: t2.addingTimeInterval(200)); await settle()
        precondition(pushed.count == 1, "sent once")
        gone = false; pushed = []
        // New work while held: that completion no longer holds.
        let t3 = t0.addingTimeInterval(2000)
        finish(from: t3, idleAtFire: 70); gone = true
        desk.observeWork(anyWorking: true, now: t3.addingTimeInterval(64)); await settle()
        precondition(pushed.isEmpty, "work resumed: \(pushed)")
        desk.observeWork(anyWorking: false, now: t3.addingTimeInterval(65)); gone = false
        // An approval right after the user walked off comes through once they count as away.
        let t4 = t0.addingTimeInterval(3000)
        idleFor = 30; desk.notify(.approval, session: nil, sessionKey: "a", now: t4)
        idleFor = 40; desk.observeWork(anyWorking: true, now: t4.addingTimeInterval(10)); await settle()
        precondition(pushed.isEmpty, "not away yet")
        gone = true; desk.observeWork(anyWorking: true, now: t4.addingTimeInterval(90)); await settle()
        precondition(pushed == ["需要审批"], "\(pushed)")
        gone = false; pushed = []
        // Input after the request, or a request that ended elsewhere: nothing to send.
        let t5 = t0.addingTimeInterval(4000)
        idleFor = 30; desk.notify(.question, session: nil, sessionKey: "b", now: t5)
        idleFor = 2; desk.observeWork(anyWorking: true, now: t5.addingTimeInterval(10))
        gone = true; desk.observeWork(anyWorking: true, now: t5.addingTimeInterval(200)); await settle()
        precondition(pushed.isEmpty, "the user came back: \(pushed)")
        gone = false; idleFor = 30; desk.notify(.approval, session: nil, sessionKey: "c", now: t5.addingTimeInterval(300))
        desk.cancelHeld(sessionKey: "c"); gone = true
        desk.observeWork(anyWorking: true, now: t5.addingTimeInterval(400)); await settle()
        precondition(pushed.isEmpty, "the request already ended: \(pushed)")
        // Switched off: back to pushing at once, and nothing held comes out later.
        gone = false; idleFor = 30; desk.notify(.approval, session: nil, sessionKey: "d", now: t5.addingTimeInterval(500))
        desk.settings.awayOnly = false; desk.observeWork(anyWorking: true, now: t5.addingTimeInterval(501))
        desk.settings.awayOnly = true; gone = true; desk.observeWork(anyWorking: true, now: t5.addingTimeInterval(600)); await settle()
        precondition(pushed.isEmpty, "held push cleared: \(pushed)")
        // A settings file from an older version keeps its key, and new fields take their defaults.
        let older = FileManager.default.temporaryDirectory.appendingPathComponent("bark-old-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: older) }
        try Data(#"{"enabled":true,"deviceKey":"OLDKEY","warnings":true}"#.utf8).write(to: older)
        let upgraded = BarkNotifier(file: older, send: { _ in 200 })
        precondition(upgraded.settings.deviceKey == "OLDKEY" && upgraded.settings.enabled && upgraded.settings.completions && !upgraded.settings.encrypted)
        precondition(!upgraded.settings.warnings, "the old default gives way; a value saved from now on is kept")
        precondition(upgraded.settings.awayOnly, "the old default gives way here too")
        upgraded.settings.warnings = true; upgraded.settings.awayOnly = false
        let reloaded = BarkNotifier(file: older, send: { _ in 200 }).settings
        precondition(reloaded.warnings && !reloaded.awayOnly, "a value saved from now on is kept")
        // Settings survive a restart, in a file only this user can read.
        let again = BarkNotifier(file: file, send: { _ in 200 })
        precondition(again.settings.deviceKey == "FICTIONALKEY" && again.settings.awayOnly)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600, "\(mode)")
        print("BarkChecks passed")
    }
}
