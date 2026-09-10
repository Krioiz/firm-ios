import Foundation
import Security
import WebKit
import UIKit

// The phone proves itself with a secret in the Keychain. No password, ever.
enum DeviceAuth {
    static let base = "https://getstubbie.com/dashboard/auth/device"
    static var deviceId: String { kc("firm.device_id") ?? { let v = UUID().uuidString.replacingOccurrences(of: "-", with: ""); kcSet("firm.device_id", v); return v }() }
    static var secret: String { kc("firm.secret") ?? { let v = (0..<48).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! }.map(String.init).joined(); kcSet("firm.secret", v); return v }() }

    // Ask the server for a session. Success -> cookie into the web view -> true.
    static func session(_ done: @escaping (Bool) -> Void) {
        post("\(base)/session", ["device_id": deviceId, "secret": secret]) { j, status in
            guard status == 200, let tok = j?["token"] as? String else { done(false); return }
            let c = HTTPCookie(properties: [.domain: "getstubbie.com", .path: "/dashboard", .name: "firm_session", .value: tok,
                                            .secure: "TRUE", .expires: Date(timeIntervalSinceNow: 30 * 86400)])!
            DispatchQueue.main.async { WKWebsiteDataStore.default().httpCookieStore.setCookie(c) { done(true) } }
        }
    }
    static func requestCode(_ done: @escaping (String?) -> Void) {
        post("\(base)/request", ["device_id": deviceId, "secret": secret, "name": UIDevice.current.name]) { j, _ in done(j?["code"] as? String) }
    }
    static func post(_ url: String, _ body: [String: Any], _ done: @escaping ([String: Any]?, Int) -> Void) {
        var r = URLRequest(url: URL(string: url)!); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.setValue("FirmApp/2.1", forHTTPHeaderField: "User-Agent")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: r) { d, resp, _ in
            let j = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done(j, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }.resume()
    }
    // minimal Keychain
    static func kc(_ k: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: k, kSecReturnData as String: true]
        var out: AnyObject?; guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func kcSet(_ k: String, _ v: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: k]
        SecItemDelete(q as CFDictionary)
        var a = q; a[kSecValueData as String] = v.data(using: .utf8)!; a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(a as CFDictionary, nil)
    }
}
