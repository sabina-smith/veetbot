import SwiftUI

@main
struct TopicsApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup("Topics") {
            RootView()
                .environmentObject(app)
                .environmentObject(app.connection)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowToolbarStyle(.unified)

        Settings {
            ConnectionSettingsView()
                .environmentObject(app.connection)
                .frame(width: 460)
                .padding(20)
        }
    }
}
