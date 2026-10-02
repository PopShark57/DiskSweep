import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var permissions: PermissionManager

    @State private var selectedTab: SettingsTab = .general
    @State private var isChoosingExclusion = false

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
            isPresented: $isChoosingExclusion,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { settings.addExclusion(url) }
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
                    detail: "Exclude .git and .svn folders.",
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
                    "Package contents",
                    detail: "Skip application and document bundle internals where unnecessary.",
                    isOn: $settings.exclusions.excludePackageContents
                )
            }
            .cardSurface(padding: 0)

            HStack {
                Text("Custom Exclusions")
                    .font(.headline)
                Spacer()
                Button("Add Folder…") { isChoosingExclusion = true }
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
                detail: "Show Xcode, Swift Package Manager, simulator, and Homebrew cleanup locations.",
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
