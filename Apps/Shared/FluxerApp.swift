import SwiftUI

@main
struct FluxerApp: App {
    @State private var session = AppSession()

    init() {
        NotificationManager.shared.setUp()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task {
                    NotificationManager.shared.onOpenChannel = { [weak session] channelId in
                        guard let session else { return }
                        if let channel = session.findChannel(channelId) {
                            session.channelJump = channel
                        }
                    }
                }
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 480)
                #endif
        }
        #if os(macOS)
        .windowStyle(.automatic)
        #endif
    }
}
