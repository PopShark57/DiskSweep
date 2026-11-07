import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var permissions: PermissionManager
    /// The home folder project folders are checked against. Debug builds can override it
    /// with a fixture home; see `DebugLaunchEnvironment`.
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Whether a cleanup history file exists, and how to delete it when history is turned off.
    var hasHistoryFile: Bool = false
    var deleteHistoryFile: () -> Void = {}

    @State private var offersHistoryDeletion = false

    @State private var selectedTab: SettingsTab = .general
    @State private var folderPickerPurpose: FolderPickerPurpose?

    /// One file importer serves both folder lists; SwiftUI does not reliably support
    /// more than one `fileImporter` on the same view.
    enum FolderPickerPurpose {
        case exclusion
        case projectFolder
        case androidSDK
        case androidAVD
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general
        case scan
        case exclusions
        case developer
        case privacy

        var id: String { rawValue }
        var title: String { rawValue.capitalized }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .scan: "magnifyingglass"
            case .exclusions: "folder.badge.minus"
            case .developer: "hammer"
            case .privacy: "hand.raised"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .frame(width: 172)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(
                        title: selectedTab.title,
                        subtitle: subtitle(for: selectedTab),
                        symbol: selectedTab.symbol
                    )

                    if let error = settings.lastPersistenceError {
                        PersistenceErrorBanner(message: error)
                    }

                    switch selectedTab {
                    case .general: generalSettings
                    case .scan: scanSettings
                    case .exclusions: exclusionSettings
                    case .developer: developerSettings
                    case .privacy: privacySettings
                    }
                }
                .padding(28)
                .frame(maxWidth: 820, alignment: .leading)
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .fileImporter(
            isPresented: Binding(
                get: { folderPickerPurpose != nil },
                set: { isPresented in
                    if !isPresented { folderPickerPurpose = nil }
                }
            ),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            let purpose = folderPickerPurpose
            folderPickerPurpose = nil
            guard case .success(let urls) = result else { return }
            for url in urls {
                switch purpose {
                case .exclusion: settings.addExclusion(url)
                case .projectFolder: settings.addProjectFolder(url)
                case .androidSDK: settings.developer.androidSDKFolder = url.standardizedFileURL
                case .androidAVD: settings.developer.androidAVDFolder = url.standardizedFileURL
                case nil: break
                }
            }
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsToggle(
                "Confirm before cleanup",
                detail: "Always show the exact items and total before changing files.",
                isOn: $settings.general.confirmBeforeCleanup
            )
            Divider()
            settingsToggle(
                "Prefer Move to Trash",
                detail: "Use recoverable deletion for user-created files whenever possible.",
                isOn: $settings.general.preferMoveToTrash
            )
            Divider()
            settingsToggle(
                "Show hidden files",
                detail: "Include hidden items in analysis views. Protected locations remain excluded.",
                isOn: $settings.general.showHiddenFiles
            )
            Divider()
            settingsToggle(
                "Automatically scan on launch",
                detail: "Start a cleanup-location scan after DiskSweep opens.",
                isOn: $settings.general.automaticallyScanOnLaunch
            )
            Divider()
            settingsToggle(
                "Show in menu bar",
                detail: "Show free space and a Scan command in the menu bar. Free space refreshes every 15 minutes.",
                isOn: $settings.general.showsMenuBarExtra
            )
            Divider()
            settingsToggle(
                "Notify when free space is low",
                detail: "Post a notification once when free space drops below the amount you choose. Checked every 15 minutes.",
                isOn: $settings.general.notifiesWhenSpaceIsLow
            )
            .onChange(of: settings.general.notifiesWhenSpaceIsLow) { _, isOn in
                if isOn { Task { _ = await LowSpaceMonitor.requestAuthorization() } }
            }
            if settings.general.notifiesWhenSpaceIsLow {
                Picker("Warn below", selection: $settings.general.lowSpaceThresholdGB) {
                    ForEach(GeneralSettings.lowSpaceThresholdOptions, id: \.self) { gigabytes in
                        Text("\(gigabytes) GB").tag(gigabytes)
                    }
                }
                .frame(width: 220)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .cardSurface(padding: 0)
    }

    private var scanSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(CleanupLocation.allCases.filter { !$0.isDeveloperCategory && $0 != .downloads }) { location in
                settingsToggle(
                    location.name,
                    detail: location.explanation,
                    isOn: Binding(
                        get: { settings.scan.includedLocations.contains(location) },
                        set: { settings.setScanLocation(location, isEnabled: $0) }
                    )
                )
                if location != CleanupLocation.allCases.filter({ !$0.isDeveloperCategory && $0 != .downloads }).last {
                    Divider()
                }
            }
        }
        .cardSurface(padding: 0)
    }

    private var exclusionSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                settingsToggle(
                    "Version-control metadata",
                    detail: "Skip .git and .svn folders in analysis views. Cleanup never removes folders that contain them, except Git clones that Xcode DerivedData and package-manager caches keep for themselves.",
                    isOn: $settings.exclusions.excludeVersionControlMetadata
                )
                Divider()
                settingsToggle(
                    "node_modules in deep scans",
                    detail: "Avoid expensive duplicate analysis of dependency folders.",
                    isOn: $settings.exclusions.excludeNodeModulesFromDeepScans
                )
                Divider()
                settingsToggle(
                    "Cloud placeholder files",
                    detail: "Do not download cloud-only content just to analyze it.",
                    isOn: $settings.exclusions.excludeCloudPlaceholders
                )
                Divider()
                settingsToggle(
                    "Photos libraries",
                    detail: "Treat photo-library bundles as protected content.",
                    isOn: $settings.exclusions.excludePhotoLibraries
                )
                Divider()
                settingsToggle(
                    "Time Machine backups",
                    detail: "Never traverse backup stores or snapshots.",
                    isOn: $settings.exclusions.excludeTimeMachineBackups
                )
                Divider()
                settingsToggle(
                    "Treat bundles as single items",
                    detail: "Show apps, virtual machines, media libraries, and other bundles as one item with their total size, instead of listing the files inside them.",
                    isOn: $settings.exclusions.excludePackageContents
                )
            }
            .cardSurface(padding: 0)

            HStack {
                Text("Custom Exclusions")
                    .font(.headline)
                Spacer()
                Button("Add Folder…") { folderPickerPurpose = .exclusion }
            }

            if settings.exclusions.customURLs.isEmpty {
                Text("No custom excluded folders.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
            } else {
                VStack(spacing: 0) {
                    ForEach(settings.exclusions.customURLs, id: \.standardizedFileURL.path) { url in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(url.path(percentEncoded: false))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                settings.removeExclusion(url)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(url.lastPathComponent) from exclusions")
                        }
                        .padding(12)
                        if url != settings.exclusions.customURLs.last { Divider() }
                    }
                }
                .cardSurface(padding: 0)
            }
        }
    }

    private var developerSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsToggle(
                "Enable developer cleanup",
                detail: "Show Xcode, simulator, package manager, Homebrew, IDE, Android, and project build-artifact cleanup locations.",
                isOn: $settings.developer.isEnabled
            )
            .cardSurface(padding: 0)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(CleanupLocation.allCases.filter(\.isDeveloperCategory)) { location in
                    settingsToggle(
                        location.name,
                        detail: location.explanation,
                        isOn: Binding(
                            get: { settings.developer.includedLocations.contains(location) },
                            set: { settings.setDeveloperLocation(location, isEnabled: $0) }
                        )
                    )
                    .disabled(!settings.developer.isEnabled)
                    if location != CleanupLocation.allCases.filter(\.isDeveloperCategory).last { Divider() }
                }
            }
            .cardSurface(padding: 0)

            projectFolderSettings
                .disabled(!settings.developer.isEnabled)

            androidLocationSettings
                .disabled(!settings.developer.isEnabled)
        }
    }

    private var androidLocationSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Android locations")
                .font(.headline)
            Text("If you moved the Android SDK or your virtual devices, choose their folders so unused system images can be found. The SDK folder must contain platform-tools, licenses, or emulator, and be inside your home folder outside protected locations.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            androidLocationRow(
                title: "SDK",
                value: settings.developer.androidSDKFolder,
                placeholder: "~/Library/Android/sdk",
                choose: { folderPickerPurpose = .androidSDK },
                reset: { settings.developer.androidSDKFolder = nil }
            )
            if let sdk = settings.developer.androidSDKFolder,
               !AndroidSystemImageRules.isSDKImagesRoot(sdk.appendingPathComponent("system-images")) {
                Label("This folder doesn't look like an Android SDK, so DiskSweep will skip it.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            androidLocationRow(
                title: "Virtual devices",
                value: settings.developer.androidAVDFolder,
                placeholder: "~/.android/avd",
                choose: { folderPickerPurpose = .androidAVD },
                reset: { settings.developer.androidAVDFolder = nil }
            )
        }
        .cardSurface()
    }

    private func androidLocationRow(
        title: String,
        value: URL?,
        placeholder: String,
        choose: @escaping () -> Void,
        reset: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 110, alignment: .leading)
            Text(value?.path(percentEncoded: false) ?? placeholder)
                .foregroundStyle(value == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…", action: choose)
            if value != nil {
                Button("Use Default", action: reset)
            }
        }
    }

    private var projectFolderSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Project Folders")
                        .font(.headline)
                    Text("DiskSweep looks here for virtual environments, node_modules, and tagged build caches, and offers them only when their project has been idle. Nothing is selected automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Add Folder…") { folderPickerPurpose = .projectFolder }
            }

            Picker("Offer artifacts from projects unchanged for", selection: $settings.developer.projectIdleDays) {
                ForEach(DeveloperSettings.projectIdleDayOptions, id: \.self) { days in
                    Text("\(days) days").tag(days)
                }
            }
            .frame(maxWidth: 420)

            if settings.developer.projectFolders.isEmpty {
                Text("No project folders. Add the folder where you keep your code, such as ~/Developer.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
            } else {
                VStack(spacing: 0) {
                    ForEach(settings.developer.projectFolders, id: \.standardizedFileURL.path) { url in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(url.path(percentEncoded: false))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    settings.removeProjectFolder(url)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(url.lastPathComponent) from project folders")
                            }
                            if let reason = ProjectArtifactsProvider.refusalReason(for: url, homeDirectory: homeDirectory) {
                                Label(reason, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12)
                        if url != settings.developer.projectFolders.last { Divider() }
                    }
                }
                .cardSurface(padding: 0)
            }
        }
    }

    private var privacySettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(PrivacySettings.localOnlyNotice, systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .cardSurface()

            settingsToggle(
                "Keep local cleanup history",
                detail: "Store the date, recovered size, item count, and categories in Application Support on this Mac.",
                isOn: $settings.privacy.keepLocalCleanupHistory
            )
            .cardSurface(padding: 0)
            .onChange(of: settings.privacy.keepLocalCleanupHistory) { _, keeps in
                if !keeps, hasHistoryFile { offersHistoryDeletion = true }
            }
            .confirmationDialog(
                "Delete the existing cleanup history?",
                isPresented: $offersHistoryDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete History", role: .destructive, action: deleteHistoryFile)
                Button("Keep File", role: .cancel) {}
            } message: {
                Text("New cleanups won't be recorded. The history already saved on this Mac stays unless you delete it.")
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(permissions.statusTitle, systemImage: permissionSymbol)
                        .font(.headline)
                    Spacer()
                    Button("Check Again") { permissions.refreshStatus() }
                }
                Text(permissions.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Full Disk Access Settings") {
                        _ = permissions.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
            .cardSurface()

            Text("DiskSweep does not require root access, install privileged daemons, bypass macOS permissions, or ask you to disable SIP.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionSymbol: String {
        switch permissions.fullDiskAccessStatus {
        case .likelyGranted: "checkmark.shield.fill"
        case .likelyRestricted: "lock.trianglebadge.exclamationmark"
        case .unknown: "questionmark.shield"
        }
    }

    private func settingsToggle(
        _ title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(16)
    }

    private func subtitle(for tab: SettingsTab) -> String {
        switch tab {
        case .general: "Choose how DiskSweep behaves during everyday cleanup."
        case .scan: "Control the recognized cleanup locations included in scans."
        case .exclusions: "Keep chosen folders out of analysis and duplicate scans."
        case .developer: "Configure conservative developer-tool cleanup categories."
        case .privacy: "Understand local processing and macOS file permissions."
        }
    }
}
