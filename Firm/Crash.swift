import Foundation
import UIKit

/// The app was dying on the phone with nothing to show for it. This catches the death,
/// writes it to disk before the process goes, and posts it on the next launch — so a
/// crash Marco hits once becomes a stack trace we can actually read.
enum Crash {
    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-crash.txt")
    }

    /// Written from a signal handler, so this must stay async-signal-safe: no Foundation
    /// allocation, no Swift runtime calls that can take a lock. Raw POSIX write only.
    private static func writeRaw(_ s: String) {
        let path = file.path
        path.withCString { cpath in
            let fd = open(cpath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else { return }
            _ = s.utf8CString.withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress, strlen(buf.baseAddress!))
            }
            close(fd)
        }
    }

    static func install() {
        NSSetUncaughtExceptionHandler { ex in
            let body = """
            kind: exception
            name: \(ex.name.rawValue)
            reason: \(ex.reason ?? "—")
            stack:
            \(ex.callStackSymbols.joined(separator: "\n"))
            """
            Crash.writeRaw(body)
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                Crash.writeRaw("kind: signal\nsignal: \(s)\nstack:\n"
                               + Thread.callStackSymbols.joined(separator: "\n"))
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    /// Send whatever the last death left behind, then clear it.
    static func reportIfAny() {
        guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { return }
        try? FileManager.default.removeItem(at: file)
        var r = URLRequest(url: URL(string: "\(Store.base)/crash")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "version": v,
            "os": UIDevice.current.systemVersion,
            "text": String(text.prefix(20_000)),
        ])
        URLSession.shared.dataTask(with: r).resume()
    }
}
