import SwiftUI

@main
struct DiskSweepApp: App {
    static let mainWindowID = "main"

    @State private var model = Self.makeModel()

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
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
                homeDirectory: model.homeDirectory,
                hasHistoryFile: model.history.hasHistoryFile,
                deleteHistoryFile: model.deleteHistoryFile
            )
            .frame(width: 760, height: 560)
        }

        // The setter only writes real changes. MenuBarExtra writes the current value back
        // while it sets up; writing it unconditionally marks the settings as changed, which
        // rebuilds this scene, which writes again, until the stack overflows at launch.
        MenuBarExtra(isInserted: Binding(
            get: { model.settings.general.showsMenuBarExtra },
            set: { isInserted in
                guard model.settings.general.showsMenuBarExtra != isInserted else { return }
                model.settings.general.showsMenuBarExtra = isInserted
            }
        )) {
            MenuBarContent(model: model)
        } label: {
            Label("DiskSweep", systemImage: "internaldrive")
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
