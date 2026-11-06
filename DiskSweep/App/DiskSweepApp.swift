import SwiftUI

@main
struct DiskSweepApp: App {
    @State private var model = Self.makeModel()

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
            SettingsView(
                settings: model.settings,
                permissions: model.permissions,
                homeDirectory: model.homeDirectory
            )
            .frame(width: 760, height: 560)
        }
    }

    @MainActor
    private static func makeModel() -> AppViewModel {
        #if DEBUG
        if let home = DebugLaunchEnvironment.homeOverride() {
            return DebugLaunchEnvironment.makeFixtureModel(home: home)
        }
        #endif
        return AppViewModel()
    }
}
