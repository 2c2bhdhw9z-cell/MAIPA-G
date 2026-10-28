import SwiftUI

@main
struct MAIPAGApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(app.preferredColorScheme)
                .task { await app.start() }
                .onOpenURL { _ in
                    // Sign-ins come back through iOS's sign-in sheet, which hands the answer over
                    // directly. A maipag:// link opened any other way just opens the app.
                }
        }
        .onChange(of: scenePhase) { _, phase in
            app.scenePhaseChanged(phase)
        }
    }
}
