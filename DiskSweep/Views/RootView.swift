import QuickLook
import SwiftUI

extension Notification.Name {
    static let diskSweepFocusSearch = Notification.Name("DiskSweep.FocusSearch")
}

struct RootView: View {
    @Bindable var model: AppViewModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .environment(\.inUseItemNames, model.inUseItemNames)
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(
            \.diskSweepCommandActions,
            DiskSweepCommandActions(
                isScanning: model.isCleanupScanning,
                scan: model.startCleanupScan,
                cancelScan: model.cancelCleanupScan,
                focusSearch: {
                    NotificationCenter.default.post(name: .diskSweepFocusSearch, object: nil)
                },
                quickLook: model.quickLookSelectedFile,
                revealInFinder: model.revealSelectedFile
            )
        )
        .sheet(isPresented: $model.showsCleanupReview) {
            CleanupReviewView(
                items: model.cleanupItems(in: model.pendingReviewScope),
                isCleaning: model.isCleaning,
                preferredUserFileDisposition: model.preferredUserFileDisposition,
                clean: model.performCleanup(disposition:)
            )
        }
        .sheet(
            isPresented: Binding(
                get: { model.cleanupResult != nil },
                set: { isPresented in
                    if !isPresented { model.cleanupResult = nil }
                }
            )
        ) {
            if let result = model.cleanupResult {
                CleanupCompleteView(
                    result: result,
                    done: model.dismissCleanupResult,
                    reveal: model.revealInFinder,
                    undo: model.undoLastCleanup,
                    undoSummary: model.restoreSummary
                )
            }
        }
        .alert(
            "DiskSweep",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented { model.clearError() }
                }
            )
        ) {
            Button("OK") { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "An unexpected error occurred.")
        }
        .quickLookPreview($model.quickLookURL)
        .task { await model.startup() }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            sidebarSection(.overview, title: nil)
            sidebarSection(.cleanup, title: "Cleanup")
            sidebarSection(.analyze, title: "Analyze")
            sidebarSection(.activity, title: nil)
        }
        .listStyle(.sidebar)
        .navigationTitle("DiskSweep")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Divider()
                // Settings live in their own window (⌘,), not in the detail column.
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                HStack(spacing: 7) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.diskStatistics.volumeName)
                            .font(.caption.weight(.medium))
                        Text("\(FileSizeFormatter.string(fromByteCount: model.diskStatistics.available)) available")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }

    @ViewBuilder
    private func sidebarSection(_ group: SidebarDestination.Group, title: String?) -> some View {
        let items = SidebarDestination.allCases.filter { $0.group == group }
        if let title {
            Section(title) {
                ForEach(items) { item in sidebarRow(item) }
            }
        } else {
            Section {
                ForEach(items) { item in sidebarRow(item) }
            }
        }
    }

    private func sidebarRow(_ item: SidebarDestination) -> some View {
        Label(item.title, systemImage: item.symbolName)
            .tag(item)
            .accessibilityLabel(item.title)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .overview {
        case .overview:
            OverviewView(
                statistics: model.diskStatistics,
                categories: model.categories,
                selectedItemIDs: $model.selectedCleanupItemIDs,
                progress: model.cleanupScanProgress,
                lastScanDate: model.lastScanDate,
                scanWasCancelled: model.lastScanWasCancelled,
                scan: model.startCleanupScan,
                cancelScan: model.cancelCleanupScan,
                reviewCleanup: { model.requestCleanupReview(scope: .locations(CleanupScope.allScanLocations)) }
            )

        case .smartCleanup:
            CleanupListView(
                title: "Smart Cleanup",
                subtitle: "Low-risk items are recommended; everything else remains unselected for review.",
                symbol: "sparkles",
                categories: model.categories,
                selectedItemIDs: $model.selectedCleanupItemIDs,
                isScanning: model.isCleanupScanning,
                scan: model.startCleanupScan,
                reviewCleanup: { model.requestCleanupReview(scope: .locations(CleanupScope.allScanLocations)) },
                quickLook: model.quickLook,
                reveal: model.revealInFinder
            )

        case .applicationCaches:
            CleanupListView(
                title: "Application Caches",
                subtitle: "Disposable caches only—never profiles, sessions, preferences, cookies, or application support data.",
                symbol: "app.badge",
                categories: model.categories.filter {
                    CleanupScope.applicationCacheLocations.contains($0.location)
                },
                selectedItemIDs: $model.selectedCleanupItemIDs,
                isScanning: model.isCleanupScanning,
                scan: model.startCleanupScan,
                reviewCleanup: { model.requestCleanupReview(scope: .locations(CleanupScope.applicationCacheLocations)) },
                quickLook: model.quickLook,
                reveal: model.revealInFinder
            )

        case .developerFiles:
            CleanupListView(
                title: "Developer Files",
                subtitle: "Xcode, simulator, package manager, Homebrew, old IDE versions, Android images, and idle project build artifacts with conservative defaults.",
                symbol: "hammer",
                categories: model.categories.filter { $0.location.isDeveloperCategory },
                selectedItemIDs: $model.selectedCleanupItemIDs,
                isScanning: model.isCleanupScanning,
                scan: model.startCleanupScan,
                reviewCleanup: { model.requestCleanupReview(scope: .locations(CleanupScope.developerLocations)) },
                quickLook: model.quickLook,
                reveal: model.revealInFinder
            )

        case .downloads:
            DownloadsView(
                analysis: model.downloadsAnalysis,
                selectedFileIDs: $model.selectedDownloadFileIDs,
                isScanning: model.isAnalyzing(.downloads),
                scan: model.startDownloadsAnalysis,
                cancel: model.cancelAnalysis,
                reviewCleanup: { model.requestCleanupReview(scope: .downloads) },
                reveal: model.revealInFinder,
                quickLook: model.quickLook,
                reportVisibleFileIDs: { model.downloadsVisibleFileIDs = $0 }
            )

        case .trash:
            TrashCleanupView(
                category: model.categories.first { $0.location == .trash },
                selectedItemIDs: $model.selectedCleanupItemIDs,
                isScanning: model.isCleanupScanning,
                scan: model.startCleanupScan,
                reviewCleanup: { model.requestCleanupReview(scope: .locations([.trash])) },
                quickLook: model.quickLook,
                reveal: model.revealInFinder
            )

        case .largeFiles:
            LargeFilesView(
                files: model.largeFiles,
                threshold: $model.largeFileThreshold,
                selectedFileID: $model.selectedLargeFileID,
                isScanning: model.isAnalyzing(.largeFiles),
                scan: model.startLargeFileAnalysis,
                cancel: model.cancelAnalysis,
                reveal: model.revealInFinder,
                quickLook: model.quickLook
            )

        case .duplicates:
            DuplicatesView(
                groups: model.duplicateGroups,
                selectedFileIDs: $model.selectedDuplicateFileIDs,
                isScanning: model.isAnalyzing(.duplicates),
                scan: model.startDuplicateAnalysis,
                cancel: model.cancelAnalysis,
                reveal: model.revealInFinder,
                quickLook: model.quickLook
            )

        case .diskUsage:
            DiskUsageView(
                root: model.largeFolderRoot,
                isScanning: model.isAnalyzing(.folders),
                scan: model.startFolderAnalysis,
                cancel: model.cancelAnalysis,
                reveal: model.revealInFinder
            )

        case .history:
            HistoryView(
                entries: model.history.entries,
                persistenceError: model.history.lastPersistenceError,
                deleteEntry: model.deleteHistoryEntry,
                clearHistory: model.clearHistory,
                putBack: model.putBack
            )
        }
    }
}
