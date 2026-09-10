import SwiftUI
@main struct FirmApp: App {
    @UIApplicationDelegateAdaptor(Push.self) var push
    var body: some Scene { WindowGroup { RootView() } }
}
