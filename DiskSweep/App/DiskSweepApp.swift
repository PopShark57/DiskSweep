import SwiftUI

@main
struct DiskSweepApp: App {
    @State private var model = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            DiskSweepCommands()
        }

        Settings {
            SettingsView(settings: model.settings, permissions: model.permissions)
                .frame(width: 760, height: 560)
        }
    }
}
