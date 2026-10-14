import Foundation
import Security
import UIKit

// Tradster is its own device to the server: its own id and secret in the Keychain, approved
// once in the dashboard like any other phone. No password anywhere.
// URLSession keeps the returned cookie, so every later call is already authenticated.
enum DeviceAuth {
    static let base = "https://getstubbie.com/dashboard/auth/device"
    static var deviceId: String {
        if let v = kc("tradster.device_id") { return v }
        let v = UUID().uuidString.replacingOccurrences(of: "-", with: ""); kcSet("tradster.device_id", v); return v
    }
    static var secret: String {
        if let v = kc("tradster.secret") { return v }
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let v = String((0..<48).map { _ in chars.randomElement()! }); kcSet("tradster.secret", v); return v
    }
    /// true once this device has a live session
    static func session() async -> Bool {
        await withCheckedContinuation { c in
            post("\(base)/session", ["device_id": deviceId, "secret": secret]) { j, status in
                c.resume(returning: status == 200 && (j?["ok"] as? Bool) == true)
            }
        }
    }
    static func requestCode() async -> String? {
        let name = await MainActor.run { UIDevice.current.name }
        return await withCheckedContinuation { c in
            post("\(base)/request", ["device_id": deviceId, "secret": secret, "name": name]) { j, _ in
                c.resume(returning: j?["code"] as? String)
            }
        }
    }
    static func post(_ url: String, _ body: [String: Any], _ done: @escaping ([String: Any]?, Int) -> Void) {
        var r = URLRequest(url: URL(string: url)!); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: r) { d, resp, _ in
            let j = d.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            done(j, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }.resume()
    }
    static func kc(_ k: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: k, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func kcSet(_ k: String, _ v: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: k]
        SecItemDelete(q as CFDictionary)
        var a = q; a[kSecValueData as String] = v.data(using: .utf8)!
        a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(a as CFDictionary, nil)
    }
}
