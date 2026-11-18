import SwiftUI
import Foundation
import Security
import CryptoKit
import AuthenticationServices
import UIKit
import UserNotifications

// MARK: - JSON
// ACT's API is plain FastAPI dicts whose shape shifts as the web page grows. A dynamic value is
// sturdier here than a Codable struct per endpoint: a new or missing key never breaks a screen.
enum JSON: Decodable, Hashable {
    case null, bool(Bool), num(Double), str(String), arr([JSON]), obj([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .num(n) }
        else if let s = try? c.decode(String.self) { self = .str(s) }
        else if let a = try? c.decode([JSON].self) { self = .arr(a) }
        else { self = .obj(try c.decode([String: JSON].self)) }
    }

    static func parse(_ data: Data) -> JSON? { try? JSONDecoder().decode(JSON.self, from: data) }

    subscript(_ k: String) -> JSON { if case .obj(let o) = self { return o[k] ?? .null }; return .null }
    subscript(_ i: Int) -> JSON { if case .arr(let a) = self, i >= 0, i < a.count { return a[i] }; return .null }

    var string: String? {
        switch self {
        case .str(let s): return s
        case .num(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var text: String { string ?? "" }
    var int: Int? { if case .num(let n) = self { return Int(n) }; if case .str(let s) = self { return Int(s) }; return nil }
    var double: Double? { if case .num(let n) = self { return n }; if case .str(let s) = self { return Double(s) }; return nil }
    var bool: Bool { if case .bool(let b) = self { return b }; return false }
    var array: [JSON] { if case .arr(let a) = self { return a }; return [] }
    var object: [String: JSON] { if case .obj(let o) = self { return o }; return [:] }
    var isNull: Bool { if case .null = self { return true }; return false }
    var date: Date? { string.flatMap(ACTDate.parse) }
}

enum ACTDate {
    private static let cph = TimeZone(identifier: "Europe/Copenhagen")
    private static let full: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let plain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static func fmt(_ p: String, _ loc: String = "en_US_POSIX") -> DateFormatter {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: loc); f.timeZone = cph; f.dateFormat = p; return f
    }
    private static let day = fmt("yyyy-MM-dd")
    private static let local = [fmt("yyyy-MM-dd'T'HH:mm:ss.SSSSSS"), fmt("yyyy-MM-dd'T'HH:mm:ss")]
    private static let short = fmt("d. MMM", "da_DK")
    private static let clock = fmt("HH:mm", "da_DK")
    /// Python's isoformat writes six decimals ("...:33.123456+00:00"); cut to three before the ISO parser.
    private static let micro = try? NSRegularExpression(pattern: "(\\.\\d{3})\\d+")

    // Formatters are built once: a list of rows used to build several per row on every render.
    static func parse(_ s: String) -> Date? {
        if let d = full.date(from: s) ?? plain.date(from: s) { return d }
        if let re = micro {
            let t = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
            if t != s, let d = full.date(from: t) { return d }
        }
        // Python's isoformat without a zone, or a bare date
        if s.count == 10 { return day.date(from: s) }
        for f in local { if let d = f.date(from: s) { return d } }
        return nil
    }
    static func dayText(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "i dag" }
        if cal.isDateInTomorrow(d) { return "i morgen" }
        if cal.isDateInYesterday(d) { return "i går" }
        return short.string(from: d)
    }
    static func time(_ d: Date) -> String { clock.string(from: d) }
    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "lige nu" }
        if s < 3600 { return "\(s / 60) min siden" }
        if s < 86400 { return "\(s / 3600) t siden" }
        return dayText(d)
    }
}

/// "KAN-123", as the web page writes it.
func kode(_ c: JSON) -> String {
    guard let nr = c["nr"].int else { return c["kode"].text }
    let p = c["projekt"].string ?? "K"
    return String(p.prefix(3)).uppercased() + "-\(nr)"
}

// MARK: - Keychain
enum Keychain {
    private static let service = "com.getstubbie.kaneoact"
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ account: String, _ value: String) {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - API
struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }

    /// URLSession's own errors come in the phone's language and mean little to Marco: say it in Danish.
    /// A cancelled request (pull to refresh let go, the screen closed) stays a cancellation.
    static func from(_ e: Error) -> Error {
        guard let u = e as? URLError else { return e }
        switch u.code {
        case .cancelled: return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return APIError(status: 0, message: "Ingen forbindelse. Prøv igen, når telefonen er online.")
        case .timedOut: return APIError(status: 0, message: "ACT svarede ikke i tide. Prøv igen.")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed:
            return APIError(status: 0, message: "ACT kan ikke nås lige nu. Prøv igen om lidt.")
        default: return APIError(status: 0, message: "Netværksfejl. Prøv igen.")
        }
    }
}

extension Error {
    /// Not worth a red line: the request was called off, not refused.
    var isCancellation: Bool { self is CancellationError || (self as? URLError)?.code == .cancelled }
}

@MainActor final class API: ObservableObject {
    static let shared = API()
    static let base = URL(string: "https://act.kaneo.ai")!

    @Published private(set) var token: String? = Keychain.get("token")
    @Published var email: String = UserDefaults.standard.string(forKey: "email") ?? ""
    @Published var name: String = UserDefaults.standard.string(forKey: "name") ?? ""
    @Published var expires: String = UserDefaults.standard.string(forKey: "expires") ?? ""

    var loggedIn: Bool { token != nil }

    func store(token: String, email: String, name: String, expires: String) {
        Keychain.set("token", token)
        self.token = token; self.email = email; self.name = name; self.expires = expires
        let d = UserDefaults.standard
        d.set(email, forKey: "email"); d.set(name, forKey: "name"); d.set(expires, forKey: "expires")
        Push.shared?.uploadPending()
    }

    /// Forget the token here. The server copy is deleted by logout(); a 401 means it is already gone.
    func forget() {
        Keychain.delete("token"); token = nil
    }

    /// Every call goes through here, so network errors are Danish everywhere.
    static func wrap<T>(_ f: () async throws -> T) async throws -> T {
        do { return try await f() } catch { throw APIError.from(error) }
    }
    private func load(_ r: URLRequest) async throws -> (Data, URLResponse) {
        try await API.wrap { try await URLSession.shared.data(for: r) }
    }

    func logout() async {
        if let t = token {
            var r = URLRequest(url: API.base.appendingPathComponent("auth/app-logout"))
            r.httpMethod = "POST"; r.setValue("Bearer " + t, forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: r)
        }
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        forget()
    }

    private func request(_ path: String, method: String = "GET", json: Any? = nil) -> URLRequest {
        // A path with a space or æøå (an agent's name) is encoded instead of crashing on a nil URL.
        let url = URL(string: path, relativeTo: API.base)?.absoluteURL
            ?? path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { URL(string: $0, relativeTo: API.base)?.absoluteURL }
            ?? API.base
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 60
        if let t = token { r.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            r.httpBody = try? JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func check(_ data: Data, _ resp: URLResponse) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { forget(); throw APIError(status: 401, message: "Log ind igen") }
        if !(200..<300).contains(code) {
            let detail = JSON.parse(data)?["detail"]
            throw APIError(status: code, message: detail?.string ?? "Det gik ikke (\(code))")
        }
    }

    func get(_ path: String) async throws -> JSON {
        let (d, r) = try await load(request(path))
        try check(d, r)
        return JSON.parse(d) ?? .null
    }

    @discardableResult
    func send(_ path: String, method: String = "POST", _ body: [String: Any] = [:]) async throws -> JSON {
        let (d, r) = try await load(request(path, method: method, json: body))
        try check(d, r)
        return JSON.parse(d) ?? .null
    }

    func download(_ path: String) async throws -> (Data, String?) {
        let (d, r) = try await load(request(path))
        try check(d, r)
        return (d, (r as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"))
    }

    /// multipart/form-data upload to /api/chat/fil, the same field name ("fil") as the web page.
    func uploadChatFile(_ data: Data, name: String, mime: String) async throws -> JSON {
        let boundary = "act-" + UUID().uuidString
        var r = request("api/chat/fil", method: "POST")
        r.timeoutInterval = 300
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        let safe = name.replacingOccurrences(of: "\"", with: "_")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"fil\"; filename=\"\(safe)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (d, resp) = try await API.wrap { try await URLSession.shared.upload(for: r, from: body) }
        try check(d, resp)
        return JSON.parse(d) ?? .null
    }

    /// Neo's answer: one JSON object per line (NDJSON), exactly as the web page reads it.
    func stream(_ path: String, _ body: [String: Any]) -> AsyncThrowingStream<JSON, Error> {
        let req = request(path, method: "POST", json: body)
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 401 { await MainActor.run { self.forget() } }
                    guard (200..<300).contains(code) else { throw APIError(status: code, message: "Neo svarede ikke (\(code))") }
                    for try await line in bytes.lines {
                        if line.isEmpty { continue }
                        if let j = JSON.parse(Data(line.utf8)) { cont.yield(j) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: APIError.from(error)) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Login
// ASWebAuthenticationSession on ACT's own login. ACT runs the normal Kaneo login (its OIDC client is
// unchanged), then hands a 60-second one-time code to kaneoact://login. The code is only worth
// something together with the verifier, which never leaves this object.
final class WebLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first.map { UIWindow(windowScene: $0) } ?? UIWindow()
    }

    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func random(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return b64url(Data(b))
    }

    @MainActor
    func login() async throws {
        let verifier = Self.random(48)                     // 64 characters
        let challenge = Self.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.random(16)
        var c = URLComponents(url: API.base.appendingPathComponent("auth/login"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "app", value: "1"), URLQueryItem(name: "challenge", value: challenge),
                        URLQueryItem(name: "app_state", value: state)]
        let url = c.url!
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "kaneoact") { u, err in
                if let u { cont.resume(returning: u) }
                else { cont.resume(throwing: err ?? APIError(status: 0, message: "Login afbrudt")) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false   // reuse the Kaneo login Safari already has
            self.session = s
            if !s.start() { cont.resume(throwing: APIError(status: 0, message: "Kunne ikke åbne login")) }
        }
        session = nil
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value,
              items.first(where: { $0.name == "state" })?.value == state else {
            throw APIError(status: 0, message: "Ugyldigt svar fra login")
        }
        var r = URLRequest(url: API.base.appendingPathComponent("auth/app-token"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "verifier": verifier])
        let (d, resp) = try await API.wrap { try await URLSession.shared.data(for: r) }
        let j = JSON.parse(d) ?? .null
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let tok = j["token"].string else {
            throw APIError(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, message: j["detail"].string ?? "Login fejlede")
        }
        API.shared.store(token: tok, email: j["email"].text, name: j["navn"].text, expires: j["udloeber"].text)
    }
}

// MARK: - Toast (with an optional "Fortryd")
@MainActor final class Toast: ObservableObject {
    static let shared = Toast()
    @Published var text: String?
    @Published var undo: (() -> Void)?
    private var task: Task<Void, Never>?
    func show(_ t: String, undo: (() -> Void)? = nil, seconds: Double = 2.2) {
        text = t; self.undo = undo; task?.cancel()
        // VoiceOver hears the toast too; with "Fortryd" it says how to undo.
        UIAccessibility.post(notification: .announcement, argument: undo == nil ? t : t + ". Fortryd findes nederst på skærmen.")
        task = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { text = nil; self.undo = nil }
        }
    }
    func dismiss() { task?.cancel(); text = nil; undo = nil }
}

// MARK: - Brands
// The same table as BRANDS in ACT's index.html: text -> the service's own logo from /icons/brands/
// (bundled in the asset catalog as brand-<key>). The first rule that matches wins; the title is
// checked before labels/agent/source/project, and those before the first lines of the text.
struct Brand { let key: String; let name: String; let asset: String?; let tint: Color? }

enum Brands {
    private struct Rule { let brand: Brand; let strong: NSRegularExpression?; let weak: NSRegularExpression? }
    private static func rx(_ p: String?) -> NSRegularExpression? { p.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) } }
    private static func r(_ k: String, _ n: String, _ a: String?, _ tint: Color? = nil, _ s: String?, _ w: String?) -> Rule {
        Rule(brand: Brand(key: k, name: n, asset: a.map { "brand-" + $0 }, tint: tint), strong: rx(s), weak: rx(w))
    }
    private static let rules: [Rule] = [
        r("gmail", "Gmail", "gmail", nil, "gmail", "^(mail|re|sv|fw|vs):|\\bmail(s|en)?\\b|e-?mail|svarvagt|postmand|indbakke|faktura-?mail"),
        r("facebook", "Facebook", "facebook", nil, "facebook|\\bfb\\b|fb-|messenger|\\bmeta\\b", "\\bgruppe|gruppe-agent"),
        r("instagram", "Instagram", "instagram", nil, "instagram|\\binsta\\b", nil),
        r("linkedin", "LinkedIn", "linkedin", nil, "linked-?in", nil),
        r("googleads", "Google Ads", "googleads", nil, "google[ -]?ads|adwords", nil),
        r("stripe", "Stripe", "stripe", nil, "stripe", nil),
        r("postiz", "Postiz", "postiz", nil, "postiz", nil),
        r("dinero", "Dinero", "dinero", nil, "dinero", "\\bbilag|bogf(ø|oe)r|bogholderi|\\bmoms\\b|faktura"),
        r("kaneosign", "KaneoSign", "kaneo", nil, "kaneo-?sign", "kontrakt|underskrift"),
        r("googleplay", "Google Play", "googleplay", nil, "google[ -]?play|play store", nil),
        r("appstore", "App Store", "appstore", nil, "app[ -]?store|testflight|app store connect", nil),
        r("apple", "Apple", "apple", nil, "\\bapple\\b|\\bios\\b", nil),
        r("google", "Google", "google", nil, "google|gemini", nil),
        r("runpod", "RunPod", "runpod", nil, "run-?pod", nil),
        r("openrouter", "OpenRouter", "openrouter", nil, "open-?router", nil),
        r("claude", "Claude", "claude", nil, "claude", nil),
        r("anthropic", "Anthropic", "anthropic", nil, "anthropic", nil),
        r("vipps", "Vipps MobilePay", "vipps", nil, "vipps|mobile-?pay", nil),
        r("telnyx", "Telnyx", "telnyx", nil, "telnyx", nil),
        r("gatewayapi", "GatewayAPI", "gatewayapi", nil, "gateway-?api", nil),
        r("contabo", "Contabo", "contabo", Color(hex: 0x00AAEB), "contabo", nil),
        r("digitalocean", "DigitalOcean", "digitalocean", Color(hex: 0x0080FF), "digital-?ocean", nil),
        r("github", "GitHub", "github", nil, "github", nil),
        r("kaneo", "Kaneo", "kaneo", nil, "kaneo[- ]?app|act\\.kaneo|\\bneo\\b", nil),
        r("jura", "Advokat / jura", nil, nil, nil, "advokat|\\bjura|juridisk|gdpr|retssag"),
    ]
    private static func hit(_ re: NSRegularExpression?, _ t: String) -> Bool {
        guard let re else { return false }
        return re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }
    static func of(_ c: JSON) -> Brand? {
        let t1 = c["navn"].text
        var parts = c["labels"].array.map { $0.text }
        parts += [c["ansvarlig"].text, c["kilde"].text, c["projekt"].text == "Kaneo" ? "" : c["projekt"].text]
        let t2 = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        let t3 = c["tekst"].text.split(separator: "\n", omittingEmptySubsequences: false).prefix(3).joined(separator: " ")
        for (t, weak) in [(t1, true), (t2, true), (t3, false)] where !t.isEmpty {
            if let r = rules.first(where: { hit($0.strong, t) || (weak && hit($0.weak, t)) }) { return r.brand }
        }
        return nil
    }
}
