import Combine
import CoreGraphics
import CryptoKit
import Foundation

/// Phone notifications through Bark. By default a notification says only what happened, such as
/// "needs approval", and never a command or conversation text. The optional detail adds the session's
/// name, nothing more. Approvals are still answered on the Mac.
struct BarkSettings: Codable, Equatable {
    var enabled = false
    var selfHosted = false
    var server = ""
    var deviceKey = ""
    var approvals = true
    var questions = true
    var completions = true
    var warnings = false
    var awayOnly = true
    var includeSessionName = false
    var encrypted = false
    var encryptionKey = ""
    var encryptionIV = ""
    /// 2: warnings became opt-in. 3: pushes became away-only. Both at the user's request; an older
    /// file's value was only the old default.
    var schema = 3

    var isConfigured: Bool { !deviceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!selfHosted || !server.isEmpty) }

    init() {}

    /// A field added in a later version must not wipe the saved device key, so missing ones take defaults.
    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? saved.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        enabled = read(.enabled, enabled); selfHosted = read(.selfHosted, selfHosted); server = read(.server, server)
        deviceKey = read(.deviceKey, deviceKey); approvals = read(.approvals, approvals); questions = read(.questions, questions)
        completions = read(.completions, completions); warnings = read(.warnings, warnings); awayOnly = read(.awayOnly, awayOnly)
        includeSessionName = read(.includeSessionName, includeSessionName); encrypted = read(.encrypted, encrypted)
        encryptionKey = read(.encryptionKey, encryptionKey); encryptionIV = read(.encryptionIV, encryptionIV)
        let savedBy = read(.schema, 1)
        if savedBy < 2 { warnings = false }
        if savedBy < 3 { awayOnly = true }
    }
}

enum BarkEvent: String { case approval, question, allDone, allStoppedWithFailure, warning, test }

/// "Everyone has stopped", as opposed to "someone finished a turn". People working through several
/// sessions end many turns in a row, and each session's reply wakes the next one, so a turn's end says
/// nothing. This fires once, after nobody has been working for a while, and not again until work resumes.
struct AllDoneGate {
    /// Longer than the gap between one session replying and the next one starting.
    static let settle: TimeInterval = 60
    private var workSeen = false
    private var quietSince: Date?

    mutating func update(anyWorking: Bool, now: Date) -> Bool {
        if anyWorking { workSeen = true; quietSince = nil; return false }
        guard workSeen else { return false }
        let since = quietSince ?? now
        quietSince = since
        guard now.timeIntervalSince(since) >= Self.settle else { return false }
        workSeen = false; quietSince = nil
        return true
    }
}

struct BarkMessage: Equatable {
    let title: String
    let body: String

    static func make(_ event: BarkEvent, session: String?, settings: BarkSettings) -> BarkMessage {
        let title: String, body: String
        switch event {
        case .approval: title = "需要审批"; body = "请回到 Mac 批准或拒绝。"
        case .question: title = "有问题等待回答"; body = "请回到 Mac 回答。"
        case .allDone: title = "全部完工"; body = "所有会话都已停止工作。"
        case .allStoppedWithFailure: title = "工作已全部停止"; body = "其中有任务异常结束，请回 Mac 查看。"
        case .warning: title = "任务需要注意"; body = "请在 Mac 上打开 Agent Island 查看详情。"
        case .test: title = "Agent Island"; body = "Agent Island 可以向这台设备发送 Bark 通知。"
        }
        if settings.includeSessionName, let session, !session.isEmpty, event != .test { return BarkMessage(title: session + " · " + title, body: body) }
        return BarkMessage(title: title, body: body)
    }
}

enum BarkFailure: Error, Equatable {
    case notConfigured, invalidServer, encryptionKey, deviceKey, unauthorized, endpoint, server, certificate, unreachable

    var text: String {
        switch self {
        case .notConfigured: return "还没有填写设备密钥。"
        case .invalidServer: return "服务器地址必须是 HTTPS。"
        case .encryptionKey: return "无法创建加密配置。"
        case .deviceKey: return "Bark 拒绝了这个设备密钥。"
        case .unauthorized: return "服务器拒绝了凭据。请检查地址中 user:pass@ 的部分。"
        case .endpoint: return "该地址上没有 Bark 的 /push 接口。"
        case .server: return "Bark 服务器返回了错误。"
        case .certificate: return "无法验证服务器的 HTTPS 证书。"
        case .unreachable: return "无法连接到服务器。"
        }
    }
}

enum BarkRequest {
    static let publicServer = "https://api.day.app"

    /// Builds the POST to <server>/push. Pure, so tests can inspect exactly what would leave the Mac.
    static func make(_ message: BarkMessage, settings: BarkSettings, event: BarkEvent, randomIV: String = BarkKeys.iv()) throws -> URLRequest {
        guard settings.isConfigured else { throw BarkFailure.notConfigured }
        let base = settings.selfHosted ? settings.server.trimmingCharacters(in: .whitespacesAndNewlines) : publicServer
        guard var parts = URLComponents(string: base), parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false else { throw BarkFailure.invalidServer }
        // Credentials in the address go in a header, so they never appear in a URL that gets logged.
        let user = parts.user, password = parts.password
        parts.user = nil; parts.password = nil
        parts.path = parts.path.hasSuffix("/") ? parts.path + "push" : parts.path + "/push"
        guard let url = parts.url else { throw BarkFailure.invalidServer }
        var content: [String: Any] = ["title": message.title, "body": message.body, "group": "Agent Island"]
        // A request for a decision may break through Focus. Everything else is ordinary.
        if event == .approval || event == .question { content["level"] = "timeSensitive" }
        var payload: [String: Any] = ["device_key": settings.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)]
        if settings.encrypted {
            payload["ciphertext"] = try encrypt(content, key: settings.encryptionKey, iv: randomIV)
            payload["iv"] = randomIV
        } else {
            payload.merge(content) { first, _ in first }
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let user {
            let pair = Data((user + ":" + (password ?? "")).utf8).base64EncodedString()
            request.setValue("Basic " + pair, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// AES-256-GCM over the JSON content, with the tag after the ciphertext, base64 encoded.
    static func encrypt(_ content: [String: Any], key: String, iv: String) throws -> String {
        guard let keyData = key.data(using: .utf8), keyData.count == 32, let nonceData = iv.data(using: .utf8), nonceData.count == 12,
              let nonce = try? AES.GCM.Nonce(data: nonceData) else { throw BarkFailure.encryptionKey }
        let plain = try JSONSerialization.data(withJSONObject: content)
        let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: keyData), nonce: nonce)
        return (sealed.ciphertext + sealed.tag).base64EncodedString()
    }

    static func classify(status: Int) -> BarkFailure? {
        switch status {
        case 200..<300: return nil
        case 400: return .deviceKey
        case 401, 403: return .unauthorized
        case 404, 405: return .endpoint
        default: return .server
        }
    }

    static func classify(error: Error) -> BarkFailure {
        guard let code = (error as? URLError)?.code else { return .unreachable }
        switch code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .secureConnectionFailed: return .certificate
        default: return .unreachable
        }
    }
}

enum BarkKeys {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    private static func random(_ count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in alphabet.randomElement(using: &generator)! })
    }
    static func key() -> String { random(32) }
    static func iv() -> String { random(12) }
}

func macIdleSeconds() -> TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

/// True if nobody is at this Mac: screen locked or asleep, or no input for two minutes.
func macLooksAway() -> Bool {
    if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
    if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true { return true }
    return macIdleSeconds() >= 120
}

@MainActor final class BarkNotifier: ObservableObject {
    @Published var settings: BarkSettings { didSet { if settings != oldValue { save() } } }
    @Published private(set) var testResult: String?
    @Published private(set) var testing = false
    @Published private(set) var lastFailure: String?

    private let file: URL?
    private let send: (URLRequest) async throws -> Int
    private let away: () -> Bool
    private let idle: () -> TimeInterval
    /// Away-only: an event that came while the Mac still counts as attended. Someone who walked off a
    /// minute ago does not count as away yet, so the push waits to see which it was.
    private struct HeldPush { let event: BarkEvent; let session: String?; let sessionKey: String?; let at: Date }
    private var held: [HeldPush] = []
    private var lastSent: [String: Date] = [:]
    private var gate = AllDoneGate()
    private var failureSeen = false

    /// The device key lives in an owner-only file. The Keychain would re-prompt after every rebuild,
    /// because this app is signed ad hoc and its signature changes each time.
    init(file: URL?, away: @escaping () -> Bool = macLooksAway, idle: @escaping () -> TimeInterval = macIdleSeconds, send: ((URLRequest) async throws -> Int)? = nil) {
        self.file = file; self.away = away; self.idle = idle
        self.send = send ?? { request in
            let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(BarkSettings.self, from: data) { settings = saved }
        else { settings = BarkSettings() }
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(settings) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    func wants(_ event: BarkEvent) -> Bool {
        switch event {
        case .approval: return settings.approvals
        case .question: return settings.questions
        case .allDone, .allStoppedWithFailure: return settings.completions
        case .warning: return settings.warnings
        case .test: return true
        }
    }

    /// Called for real events only. It never blocks the island, and a failed send changes nothing else.
    func notify(_ event: BarkEvent, session: String?, sessionKey: String? = nil, now: Date = Date()) {
        guard settings.enabled, settings.isConfigured, wants(event) else { return }
        guard !settings.awayOnly || away() else { hold(event, session: session, sessionKey: sessionKey, now: now); return }
        push(event, session: session, sessionKey: sessionKey, now: now)
    }

    private func hold(_ event: BarkEvent, session: String?, sessionKey: String?, now: Date) {
        held.removeAll { $0.event == event && $0.sessionKey == sessionKey }
        if held.count >= 64 { held.removeFirst() }
        // "All done" fires a minute after the work stopped. Touching the Mac in that minute counts.
        let completed = event == .allDone || event == .allStoppedWithFailure
        held.append(HeldPush(event: event, session: session, sessionKey: sessionKey, at: completed ? now.addingTimeInterval(-AllDoneGate.settle) : now))
    }

    /// Any input since the event means the user was here for it, so the island and sound did the job.
    /// No input, and it becomes "away": they had already left, so the push goes. At most two minutes.
    private func settleHeld(now: Date) {
        guard !held.isEmpty else { return }
        guard settings.enabled, settings.awayOnly else { held.removeAll(); return }
        if away() {
            let due = held
            held.removeAll()
            for item in due where wants(item.event) { push(item.event, session: item.session, sessionKey: item.sessionKey, now: now) }
            return
        }
        let idleFor = idle()
        held.removeAll { idleFor < now.timeIntervalSince($0.at) }
    }

    /// The request was resolved some other way, so there is nothing left to come back for.
    func cancelHeld(sessionKey: String) {
        held.removeAll { $0.sessionKey == sessionKey && ($0.event == .approval || $0.event == .question) }
    }

    private func push(_ event: BarkEvent, session: String?, sessionKey: String?, now: Date) {
        // Parallel tools ask for approval in a burst. One buzz covers them; the island shows every request.
        if let sessionKey {
            let key = event.rawValue + ":" + sessionKey
            let quiet: TimeInterval = event == .approval || event == .question ? 5 : 30
            if let last = lastSent[key], now.timeIntervalSince(last) < quiet { return }
            if lastSent.count > 512 { lastSent.removeAll() }
            lastSent[key] = now
        }
        let message = BarkMessage.make(event, session: session, settings: settings)
        Task { await deliver(message, event: event) }
    }

    @discardableResult private func deliver(_ message: BarkMessage, event: BarkEvent) async -> BarkFailure? {
        let failure: BarkFailure?
        do {
            let request = try BarkRequest.make(message, settings: settings, event: event)
            do { failure = BarkRequest.classify(status: try await send(request)) }
            catch { failure = BarkRequest.classify(error: error) }
        } catch { failure = error as? BarkFailure ?? .notConfigured }
        lastFailure = failure?.text
        return failure
    }

    func sendTest() {
        guard !testing else { return }
        testing = true; testResult = nil
        Task {
            let failure = await deliver(BarkMessage.make(.test, session: nil, settings: settings), event: .test)
            testResult = failure?.text ?? "Bark 已接受，请检查设备。"
            testing = false
        }
    }

    /// Called regularly with whether any session is working. See AllDoneGate.
    func observeWork(anyWorking: Bool, now: Date = Date()) {
        if anyWorking { held.removeAll { $0.event == .allDone || $0.event == .allStoppedWithFailure } }
        settleHeld(now: now)
        guard gate.update(anyWorking: anyWorking, now: now) else { return }
        let failed = failureSeen
        failureSeen = false
        notify(failed ? .allStoppedWithFailure : .allDone, session: nil, now: now)
    }

    /// A failed turn is mentioned when everything has stopped. It only buzzes by itself if asked to.
    func recordFailure(session: String?, sessionKey: String?) {
        failureSeen = true
        notify(.warning, session: session, sessionKey: sessionKey)
    }

    func generateEncryptionKeys() {
        settings.encryptionKey = BarkKeys.key(); settings.encryptionIV = BarkKeys.iv()
    }
}
