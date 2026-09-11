import SwiftUI
@main struct FirmApp: App {
    @UIApplicationDelegateAdaptor(Push.self) var push
    init() { Crash.install() }
    var body: some Scene {
        WindowGroup {
            RootView().task { Crash.reportIfAny() }
        }
    }
}
