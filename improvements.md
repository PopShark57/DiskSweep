# DiskSweep — Architecture and Code-Quality Review

Review of the `main` branch at `b8606cd` (PR #2 merged). Read-only: no application source was changed. The only uncommitted changes in the working tree are the existing `DiskSweep.xcodeproj` edits (see M6).

The phased, dependency-ordered plan for these findings is in [implementation_plan.md](implementation_plan.md).

## Scope and method

- **Platform:** macOS app only (deployment target **macOS 15.0**, Swift 6 language mode, Xcode 27, SwiftUI + Observation). There are no iOS, watchOS, or extension targets, so cross-platform integration items don't apply.
- **Read:** every file in `DiskSweep/` (~10.4k lines) and the test list in `DiskSweepTests/` (~2.5k lines), plus `project.yml`, the `.pbxproj` build settings, and the shared scheme.
- **Verified:** each finding was traced through the actual call path. Where I could check against real data on this Mac, I did (see D1). Findings that depend on AppKit runtime behavior I couldn't exercise without running the app are listed separately as **Likely** and say how to confirm them.
- **API availability:** every recommended API is available at macOS 15 (`Mutex` from Synchronization, `onKeyPress`, `Table(sortOrder:)`, Swift Charts `SectorMark`, `FormatStyle.byteCount`). `@concurrent` is a Swift 6.2 compiler feature with no OS requirement.

### Rating scale

| Rating | Meaning |
| --- | --- |
| **Impact** | High: wrong results, data loss, or a core feature not working. Medium: noticeable UX, performance, or reliability cost. Low: polish. |
| **Effort** | S: under 1 hour. M: half a day. L: one day or more. |
| **Confidence** | High: confirmed in code (and on disk where noted). Medium: code path confirmed, real-world trigger depends on environment. Low: plausible, verify first. |

---

## Summary (ranked)

### A. Confirmed defects

| # | Finding | Impact | Effort | Confidence |
| --- | --- | --- | --- | --- |
| D1 | DerivedData folders for any project with Swift packages can never be cleaned (nested `.git`) | High | S–M | High (seen on disk) |
| D2 | Cancelling and restarting a scan or analysis lets the old task wipe the new one's state | High | S | High |
| D3 | Packages (`.app`, VM bundles, Final Cut libraries, `.sparsebundle`) are dropped from all size analyses | High | M | High |
| D4 | Selections from different screens are merged into one cleanup; the review sheet hides items and disposition | Med–High | M | High |
| D5 | Cleanup history and settings are silently replaced when the file can't be decoded | Medium | S | High |
| D6 | Cleanup failure reasons, scan issues, and "not deletable" reasons are never shown; no logging | Medium | S–M | High |
| D7 | Main-thread filesystem I/O on every provider during a scan (`removeProviderOverlaps`) | Medium | S | High |
| D8 | "Cancel Scan" with no scan running marks a completed scan as "Partial" | Medium | S | High |
| D9 | Poetry virtual environments in `~/Library/Caches` are preselected and permanently deleted | Medium | S | Medium–High |
| D10 | Computed `selectedCleanupItems` writes to the snapshot registry on every read (unbounded growth) | Low–Med | S | High |
| D11 | Large Files threshold picker starts with no valid selection and shows the wrong custom value | Low–Med | S | High |
| D12 | Hard-link handling drops real duplicates that share a size group with a hard-linked pair | Low | S | High |
| D13 | Trash-first folders default to permanent deletion when "Prefer Move to Trash" is off | Low | S | High |

### B. Likely defects (verify at runtime)

| # | Finding | Impact | Effort | Confidence |
| --- | --- | --- | --- | --- |
| L1 | Bare-key menu shortcuts (Space, Esc) intercept typing in the toolbar search fields | Medium | S | Medium |
| L2 | Strict directory identity makes cleaning caches of running apps fail with "target changed" | Medium | M | Medium |
| L3 | "Recovered" bytes are measured against a noisy capacity value | Low–Med | S | Low–Med |

### C. Optional improvements

| # | Area | Finding | Impact | Effort |
| --- | --- | --- | --- | --- |
| P1 | Performance | Scanner resolves symlinks and re-fetches resource values for every entry | Medium | S |
| P2 | Performance | Pre-delete validation allocates ~25 URLs and calls `realpath` per descendant | Medium | S |
| P3 | Performance | Duplicate confirmation reads every candidate twice (SHA-256, then byte compare) | Medium | S |
| P4 | Performance/UI | Non-lazy lists and repeated per-render grouping/sorting | Medium | M |
| P5 | Performance | A `ByteCountFormatter` is created for every size label | Low | S |
| P6 | Performance | Providers scan strictly one after another | Low–Med | M |
| C1 | Concurrency | Global `@unchecked Sendable` snapshot registry; use `Mutex` and inject it | Medium | M |
| C2 | Concurrency | Provider scans stay off the main actor only because `NonisolatedNonsendingByDefault` is off | Medium (latent) | S |
| C3 | Concurrency | `FinderService` sets the Quick Look data source without taking panel control | Low | S |
| M1 | Maintainability | Duplicated path-containment, error-mapping, and sizing/snapshot boilerplate | Medium | M |
| M2 | Maintainability | Dead or unreachable code | Low | S |
| M3 | UX/Architecture | Settings appears twice; Large Folders and Disk Usage share one scan | Low | S |
| M4 | UX | The "Version-control metadata" toggle doesn't affect cleanup providers | Low | S |
| M5 | UX | Disk Usage hides files stored directly in a folder | Low | S |
| M6 | Build | `project.pbxproj` has drifted from `project.yml` (XcodeGen source of truth) | Low | S |
| M7 | Localization | Display strings from model enums aren't localizable | Low | M |
| U1 | Accessibility | Cleanup, Downloads, and Duplicates lists have no keyboard navigation or selection | Medium | M |
| S1 | Security | Path-based removal after validation leaves a small same-user TOCTOU window | Low | M |
| T1 | Testing | No tests for `AppViewModel` orchestration or for the defects above | Medium | M |
| T2 | Testing | Tests share global state, so parallel testing isn't safe | Low | S |

### D. Feature ideas

F1 Duplicates cleanup flow · F2 Large Files cleanup · F3 Undo / Put Back for Trash moves · F4 APFS clone-aware sizes · F5 Running-app awareness for caches · F6 Unavailable simulators and runtimes via `simctl` · F7 Custom Android SDK location · F8 History management · F9 Low-space menu bar extra · F10 Disk Usage chart

---

## A. Confirmed defects

### D1 — DerivedData for projects with Swift packages can never be cleaned

**Impact High · Effort S–M · Confidence High (seen on this Mac)**

**Where**
- `DiskSweep/Services/Providers/ProviderSupport.swift:100-124`: each child of a cache root is sized with `DirectorySizer` using the default `excludedNames`. If anything is excluded, the item becomes `isDeletable = false`.
- `DiskSweep/Services/DirectorySizer.swift:29` and `DiskSweep/Services/FileSystemScanner.swift:6-9`: the default excluded names include `.git` and `node_modules`.
- `DiskSweep/Services/CleanupEngine.swift:248-254`: `permittedNestedNames` is empty for every location except `.projectArtifacts` and `.staleIDEVersions`.
- `DiskSweep/Services/SafetyValidator.swift:244-253`: even if an item got through, `validateDirectoryContents` would refuse it because of the nested `.git`.

**What happens.** Xcode clones Swift package dependencies into `DerivedData/<Project>-<hash>/SourcePackages/checkouts/<Package>/`, and those clones contain `.git`. On this Mac, `~/Library/Developer/Xcode/DerivedData/MacPhone-…/SourcePackages/checkouts/Sparkle/.git` exists. As a result, the DerivedData folder of every project that uses Swift packages is shown with a disabled checkbox. The reason only appears in a hover tooltip (see D6). DerivedData is usually the biggest "safe" developer category, so for most modern projects that category does nothing.

The same rule probably also blocks two package-manager caches, since both are Git clones:
- `~/.cargo/git/checkouts/*/*`
- `~/.cocoapods/repos/*` (the legacy `master` specs repo)

Both are listed in `DiskSweep/Services/Providers/DeveloperToolCacheProvider.swift:48,51`.

**Fix**
1. Make `permittedNestedNames` a per-location property, alongside `CleanupLocation.defaultsToTrash`. For `.xcodeDerivedData`, return `[".git"]`. For `.developerToolCaches`, return `[".git"]`, or limit it to the Cargo checkouts and CocoaPods repos roots.
2. Pass the same set to the sizer in `ProviderSupport.scanChildren`, as `scanDirectoryCandidates` already does with `FileSystemSafetyPolicy.excludedNames.subtracting(permittedNestedNames)`.
3. `CleanupEngine.permittedNestedNames(for:)` then reads the property, so scan time and delete time follow the same rule.

The `.git` rule exists to protect user repositories. A repository can't legitimately live inside DerivedData or a package-manager checkout cache, so these exceptions don't weaken that protection.

**Test.** Build a `DerivedData/App-x/SourcePackages/checkouts/Pkg/.git/HEAD` fixture. Assert that the scan marks the item deletable and that `CleanupEngine` removes it.

---

### D2 — Cancelling and restarting a scan lets the old task wipe the new one's state

**Impact High · Effort S · Confidence High**

**Where**
- `DiskSweep/ViewModels/AppViewModel.swift:212-217`: `cancelCleanupScan()` sets `cleanupScanTask = nil` straight away, while the task is still running until it notices the cancellation.
- `AppViewModel.swift:200-208`: when the old task finishes, it unconditionally sets `cleanupScanProgress = nil` and `cleanupScanTask = nil`.
- The same pattern is in `cancelAnalysis()` (`AppViewModel.swift:328-333`) and the end of `beginAnalysis` (`AppViewModel.swift:384-386`).

**What happens.** Cancelling (Esc or the Cancel button) and then starting a new scan (⌘R) can leave two tasks running. The new scan starts because the handle is already `nil`. The old task then reaches its tail and clears the new scan's handle and progress. Effects:
- The progress UI disappears mid-scan.
- `isCleanupScanning` reports `false` while a scan is running, so a third scan can start.
- Two live scans both append to `categories`. `CleanupCategory.id` is its `location`, so SwiftUI gets duplicate IDs and the list behaves unpredictably.
- For analyses, starting Large Files while Duplicates is finishing clears `analysisActivity`, so the new analysis runs with no progress shown.
- A cancelled provider calls `CleanupSnapshotRegistry.shared.replace(providerID:snapshots: [:])` (for example `ProviderSupport.swift:193-196`). That can erase snapshots the new scan just recorded for the same provider. This fails safe ("Rescan before cleaning"), but it is confusing.

**Fix.** Only let a task clear state that belongs to it, using a generation counter or a task identity check:

```swift
@ObservationIgnored private var scanGeneration = 0

func startCleanupScan() {
    guard cleanupScanTask == nil, !isCleaning else { return }
    scanGeneration += 1
    let generation = scanGeneration
    cleanupScanTask = Task { [weak self] in
        // … existing loop, using `guard generation == self.scanGeneration` before each mutation …
        guard let self, generation == self.scanGeneration else { return }
        self.cleanupScanProgress = nil
        self.cleanupScanTask = nil
    }
}
```

Alternatively, keep the handle until the task finishes and have `startCleanupScan` wait for the previous task with `await previous?.value` before starting. Apply the same change to `beginAnalysis`.

---

### D3 — Packages are dropped from all size analyses

**Impact High · Effort M · Confidence High**

**Where**
- `DiskSweep/Services/Analyzers/AnalyzerFileSystem.swift:257-261`: `shouldExclude` returns `true` for any package when `excludePackageContents` is on, which is the default.
- Callers skip excluded entries entirely: `AnalyzerFileSystem.swift:134-142` (Large Files, Downloads, Duplicates) and `DiskSweep/Services/Analyzers/LargeFolderAnalyzer.swift:164-172` (Large Folders and Disk Usage). The package's bytes are never added to its parent folder.
- The Settings label says "Skip application and document bundle internals" (`DiskSweep/Views/Settings/SettingsView.swift:176-178`), but the code skips the whole bundle.

**What happens.** Some of the largest consumers on a Mac are packages, and none of them show up:
- Virtual machines (`.pvm`, `.utm`, `.vmwarevm`)
- Final Cut and iMovie libraries, and Logic projects (`.fcpbundle`, `.imovielibrary`, `.logicx`)
- `.xcarchive` bundles outside Xcode's Archives folder
- `.app` bundles left in Downloads
- `.sparsebundle` disk images

Folder totals in Large Folders and Disk Usage under-count by the size of every package below them. The Downloads "Disk Images" category lists `sparsebundle` (`DiskSweep/Services/Analyzers/DownloadsAnalyzer.swift:39`), but because sparse bundles are packages, that entry can never match.

**Fix.** Treat a package as one opaque item instead of excluding it:
- **Large Folders / Disk Usage:** size the package recursively (reuse `DirectorySizer` with `skipPackages: false`), add the bytes to its parent, and show it as a leaf node.
- **Large Files / Downloads:** emit a `FileItem` with `kind: .directory` (or a new `.package` kind) for the package's total size. Downloads already classifies by extension.
- **Duplicates:** keep packages excluded.
- **Settings:** rename the toggle to "Treat bundles as single items".

Package sizing is the expensive part. Bound it with cancellation checks, and consider using `URLResourceKey.totalFileAllocatedSizeKey` per file.

---

### D4 — Selections from different screens are merged into one cleanup

**Impact Medium–High · Effort M · Confidence High**

**Where**
- `DiskSweep/ViewModels/AppViewModel.swift:91-106`: `selectedCleanupItems` merges the scan-category selection with the Downloads selection.
- `DiskSweep/Views/Cleanup/DownloadsView.swift:175`: "Review Selected Files" calls the shared `requestCleanupReview`.
- `AppViewModel.swift:182-184`: a completed scan preselects every `.safe` item.
- `DiskSweep/Views/Cleanup/DownloadsView.swift:70-94`: the age, size, and search filters only hide rows. Hidden files stay selected, and the footer's `selectedSize` still counts them.
- `DiskSweep/Views/Cleanup/CleanupReviewView.swift:68-87`: the review sheet shows only a total per category, with no item names.
- `DiskSweep/Services/CleanupEngine.swift:237-246`: `.safe` locations are always deleted permanently, and the sheet doesn't say so.

**What happens.** After a scan, the user goes to Downloads, picks one installer, and clicks "Review Selected Files". The sheet now includes every preselected cache category, which will be deleted permanently, even though the Downloads footer showed only the installer's size. Similarly, Downloads files the user selected and then filtered out are still cleaned. Neither problem is visible in the review sheet.

**Fix**
- Scope review to the screen the user started from. For example, `requestCleanupReview(scope: .downloads | .categories(Set<CleanupLocation>))`. Or clear the other selection when switching flows.
- Prune selections that the current filter or search hides (or show a "N hidden files selected" warning).
- In the review sheet, make each group expandable to list item names, and give each group a disposition label ("Deleted permanently", "Moved to Trash").

---

### D5 — History and settings are silently replaced when they can't be decoded

**Impact Medium · Effort S · Confidence High**

**Where**
- `DiskSweep/Services/CleanupHistoryStore.swift:118-124`: if `reload()` fails, `loadWithoutThrowing()` sets `entries = []`. The next `add(_:)` (`:61-73`) persists that list over the unreadable file (`:139-155`).
- `DiskSweep/Services/SettingsStore.swift:197-205`: a decode failure loads defaults, and the next property change overwrites the stored data (`:328-347`).
- Both decode `CleanupLocation` collections strictly: `DiskSweep/Models/CleanupResult.swift:131`, and `SettingsStore.swift:19` and `:54`. One unknown raw value fails the entire decode. This happens after a downgrade, a renamed or removed case, or a branch build that added a category.
- `lastPersistenceError` is set in both stores but never displayed (grep finds no use outside the stores).

**Fix**
- Before falling back, copy the unreadable file or defaults blob aside (for example `cleanup-history.corrupt-<date>.json`).
- Decode location collections tolerantly. Decode `[String]`, then use `compactMap(CleanupLocation.init(rawValue:))`, so an unknown category is dropped instead of the whole file.
- Show `lastPersistenceError` in the UI, for example as a banner in History and Settings.

---

### D6 — Failure reasons, scan issues, and "not deletable" reasons are never shown

**Impact Medium · Effort S–M · Confidence High**

**Where**
- `DiskSweep/Views/Cleanup/CleanupCompleteView.swift:71-78`: shows only "N items could not be cleaned". `CleanupFailure.reason` and `.path` are never displayed.
- `DiskSweep/Views/Components/CleanupCategoryCard.swift:43-51`: shows only "N locations could not be read". `ScanIssue.kind`, `.path`, and `.message` are never displayed.
- `CleanupCategoryCard.swift:124,156`: a non-deletable item gets a disabled checkbox, and its reason ("contains excluded or uninspected content…") only appears in a `.help` tooltip.
- There is no `os.Logger` anywhere in the app, so these failures leave nothing to diagnose later.

The engine and providers already produce good, specific messages. Users just never see them, and D1 and L2 hit users constantly.

**Fix**
- Add a "Show Details" disclosure that lists failures with their path and reason, and offer Reveal in Finder for each.
- Show the non-deletable reason inline under the item, not only on hover.
- Add `Logger(subsystem: "com.disksweep.DiskSweep", category: "cleanup")` and log validation refusals and cleanup outcomes. Log paths with `privacy: .private` so they don't appear in sysdiagnose.

---

### D7 — Main-thread filesystem I/O on every provider during a scan

**Impact Medium · Effort S · Confidence High**

**Where**
- `DiskSweep/ViewModels/AppViewModel.swift:449-464`: `removeProviderOverlaps` is MainActor-isolated and is called once for each provider (17–18 times per scan). Each call evaluates `providers.flatMap(\.allowedRoots)`.
- `allowedRoots` is computed, and several implementations do filesystem I/O:
  - `ProviderPaths.applicationCacheRoots` lists all of `~/Library/Containers` and `~/Library/Group Containers` and calls `lstat` on each (`DiskSweep/Services/Providers/ProviderSupport.swift:466-497`). That is often hundreds of entries.
  - `simulatorCacheRoots` lists `CoreSimulator/Devices` (`ProviderSupport.swift:551-567`).
  - `ElectronAppCacheRules.applicationDirectories` lists Application Support (`DiskSweep/Services/Providers/ElectronAppCacheProvider.swift:28-35`).
  - `ProjectArtifactsProvider.allowedRoots` preflights each project folder (`DiskSweep/Services/Providers/ProjectArtifactsProvider.swift:135-139`).
- `AppViewModel.swift:191` also calls `provider.allowedRoots.first`.

**What happens.** Thousands of directory reads and `lstat` calls run on the main thread during a scan, which can cause visible hitches, especially on network-mounted or slow home folders.

**Fix.** Compute the overlap roots once per scan, off the main actor. For example, gather `[(id, roots)]` in a `Task.detached` at scan start, or move overlap filtering into the provider pipeline. Use the cached value for the `currentPath` too. In general, make `allowedRoots` cheap by caching it on the provider at scan time, because `CleanupAuthorization.init(provider:)` evaluates it again at cleanup time.

---

### D8 — "Cancel Scan" with no scan running marks a completed scan as "Partial"

**Impact Medium · Effort S · Confidence High**

**Where**
- `DiskSweep/ViewModels/AppViewModel.swift:212-217`: `cancelCleanupScan()` sets `lastScanWasCancelled = true` without checking that a scan is running.
- `DiskSweep/App/DiskSweepCommands.swift:36-38`: the command is bound to Esc (`.cancelAction`) and is enabled whenever the window is focused (`actions != nil`).
- `DiskSweep/Views/OverviewView.swift:128-161`: when that flag is set, Overview shows "Partial scan results" and a Rescan button.

**What happens.** Pressing Esc in the main window, for example to dismiss a search field, after a scan has finished relabels the results as partial.

**Fix**
- Add `guard cleanupScanTask != nil else { return }`.
- Add `isScanning: Bool` to `DiskSweepCommandActions` and disable "Cancel Scan" unless a scan is running.
- Consider ⌘. for Cancel Scan (see L1).

---

### D9 — Poetry virtual environments are preselected and permanently deleted

**Impact Medium · Effort S · Confidence Medium–High**

**Where:** `DiskSweep/Services/Providers/UserCacheProvider.swift:22-33` offers each top-level child of `~/Library/Caches` as a single `.safe` item. Safe items are preselected (`DiskSweep/Models/CleanupRisk.swift:35`) and deleted permanently (`DiskSweep/Services/CleanupEngine.swift:237-246`).

**What happens.** Poetry's default `virtualenvs.path` on macOS is `~/Library/Caches/pypoetry/virtualenvs`, so a "Pypoetry" item contains every Poetry-managed environment. Project Artifacts deliberately treats virtual environments as review-recommended and moves them to the Trash, because they can hold packages installed by hand. Here they are preselected and deleted permanently. (No `pypoetry` folder exists on this Mac, so the risk comes from Poetry's documented default.)

**Fix.** Add `pypoetry` to `excludedChildNames` and offer only `pypoetry/cache` and `pypoetry/artifacts` (as the Homebrew and SwiftPM caches already have their own handling). Or mark it `.reviewRecommended` and Trash-first. Consider a small table of cache children that hold environments rather than downloads, to grow over time.

---

### D10 — Computed `selectedCleanupItems` writes to the snapshot registry on every read

**Impact Low–Medium · Effort S · Confidence High**

**Where**
- `DiskSweep/Services/Providers/DownloadsProvider.swift:44-69`: `cleanupItem(for:)` creates a `CleanupItem` with a new `UUID()` and records a new registry snapshot each time it is called.
- It is called from the computed `AppViewModel.selectedCleanupItems` (`DiskSweep/ViewModels/AppViewModel.swift:102-104`).
- That property is read by `selectedCleanupSize`, by `commandFileURL` (`:495`), by `requestCleanupReview` and `performCleanup`, and by the review sheet's content closure (`DiskSweep/Views/RootView.swift:31`), which re-runs whenever SwiftUI re-evaluates it.

**What happens.** The registry gains N entries for each read while Downloads files are selected. Entries are removed only when they are cleaned, so they accumulate for the life of the app. The review sheet and the cleanup run also use different item IDs. That works today, but it is fragile.

**Fix.** Derive the Downloads `CleanupItem`s once per selection change, or once per analysis, with a stable ID (for example `id: file.id`), and record each snapshot only once. Keep computed properties free of side effects.

---

### D11 — Large Files threshold picker starts with no valid selection

**Impact Low–Medium · Effort S · Confidence High**

**Where**
- `DiskSweep/ViewModels/AppViewModel.swift:28` initializes the threshold from `LargeFileAnalyzer.defaultThreshold`, which is `100 * 1_024 * 1_024` = 104,857,600 (`DiskSweep/Services/Analyzers/LargeFileAnalyzer.swift:17`).
- The picker's tags are decimal (100,000,000 and up) and the Custom tag is `customThresholdMB * 1_000_000` (`DiskSweep/Views/Analyze/LargeFilesView.swift:28-33,75`).

**What happens.** On first appearance, the picker's selection matches no tag, so SwiftUI logs an invalid-selection warning and shows nothing. Because the value isn't in `thresholds`, the custom stepper also appears and reads "250 MB", while the scan actually uses ~105 MB.

**Fix.** Use one unit system. Set `defaultThreshold = 100_000_000`, which matches `ByteCountFormatter`'s decimal `.file` style, or make the tags binary. Initialize `customThresholdMB` from the current threshold.

---

### D12 — Hard-link handling drops real duplicates

**Impact Low · Effort S · Confidence High**

**Where:** `DiskSweep/Services/Analyzers/DuplicateAnalyzer.swift:293-313`. Every file whose inode appears more than once is removed from the size group.

**What happens.** If `A` and `A'` are hard links to one inode and `B` is a real copy of the same content, all of `A` and `A'` are removed, `B` is left alone, and no duplicate group is reported. Deleting `B` would have freed space.

**Fix.** Keep one representative per `(device, inode)`, such as the shallowest path, and drop only the extra aliases. Count the dropped aliases in `hardLinkAliasesIgnored` as today.

---

### D13 — Trash-first folders default to permanent deletion when "Prefer Move to Trash" is off

**Impact Low · Effort S · Confidence High**

**Where**
- `DiskSweep/Views/Cleanup/CleanupReviewView.swift:20` seeds the disposition picker from `preferredUserFileDisposition`.
- That value comes from the user-file preference (`DiskSweep/ViewModels/AppViewModel.swift:87-89`).
- The same picker controls Project Artifacts and Old IDE Versions (`CleanupReviewView.swift:33-35,89-107`).

**What happens.** The README and the `defaultsToTrash` comment (`DiskSweep/Models/CleanupLocation.swift:139-148`) say these folders move to the Trash by default. With the user-file preference off, the sheet instead opens on "Delete Permanently".

**Fix.** Default to `.trash` whenever the selection includes `defaultsToTrash` developer folders. Or show separate pickers for user files and developer folders.

---

## B. Likely defects (verify at runtime)

### L1 — Bare-key menu shortcuts intercept typing in search fields

**Impact Medium · Effort S · Confidence Medium**

**Where:** `DiskSweep/App/DiskSweepCommands.swift:36-37` binds Cancel Scan to Esc (`.cancelAction`). `DiskSweepCommands.swift:48-49` binds Quick Look to Space with no modifiers. All four content screens have a toolbar `.searchable` field (`CleanupListView.swift:50`, `DownloadsView.swift:159`, `LargeFilesView.swift:182`).

**Why it's likely.** AppKit offers key-down events to menu key equivalents before the first responder's `keyDown:`. A modifier-free Space equivalent can therefore swallow spaces typed in the search field. Esc may no longer clear the field and instead trigger Cancel Scan, which leads to D8.

**How to confirm.** Run the app, open Downloads, and type "my file" into the search field. Then press Esc in an empty search field.

**Fix.** Use ⌘Y for Quick Look, which matches Finder, and handle Space with `.onKeyPress(.space)` on the `Table` or list only. Use ⌘. for Cancel Scan.

---

### L2 — Strict directory identity makes cleaning caches of running apps fail

**Impact Medium · Effort M · Confidence Medium**

**Where**
- `FileIdentity` equality includes `mtime` and `ctime` (`DiskSweep/Services/SafetyValidator.swift:60-70`).
- The engine requires an exact match with the scan-time snapshot (`DiskSweep/Services/CleanupEngine.swift:142-152`) and checks the modification time again in `matchesScannedMetadata` (`CleanupEngine.swift:299-317`).

**What happens.** Adding or removing an entry in a directory changes its `mtime` and `ctime`. Running apps (browsers, Electron apps, Xcode, Slack) constantly add cache entries, so the top-level folder of an active cache often no longer matches by the time the user clicks Clean. The item then fails with "The target changed after validation." Combined with D6, the user sees only "N items could not be cleaned".

**Fix (design trade-off).** For `.safe`, regenerable locations, match on `device + inode + kind`, and keep exact `mtime` and `ctime` matching for user files, Downloads, and rule-based locations. Alternatively, offer "Rescan and Retry Failed Items" on the completion screen.

---

### L3 — "Recovered" bytes are measured against a noisy capacity value

**Impact Low–Medium · Effort S · Confidence Low–Medium**

**Where:** `DiskSweep/Models/CleanupResult.swift:71-81` measures before and after with `volumeAvailableCapacityForImportantUsage` (`DiskSweep/Services/DiskService.swift:45-47`). That value includes purgeable space, which the system can reclaim at any time. APFS also frees large deletions asynchronously, and blocks still referenced by a local snapshot aren't freed at all.

**What happens.** `creditedBytesRecovered` prefers any positive measured change over the permanently removed byte count. Small unrelated changes can therefore under-report a large cleanup, or credit space the cleanup didn't free.

**Fix.** Measure the delta with `volumeAvailableCapacityKey`, which excludes purgeable space. Label the value as an estimate. Optionally re-measure after a short delay, and mention local snapshots when the measured value is far below the removed bytes.

---

## C. Optional improvements

### Performance and battery

**P1 — Scanner re-resolves and re-fetches for every entry** (`DiskSweep/Services/FileSystemScanner.swift:178-198`)
- `resolvingSymlinksInPath()`, which performs a component-by-component `lstat`, runs for every enumerated entry, even when `exclusionURLs` is empty.
- `resourceValues(forKeys:)` is called on `standardized`, a different URL value from the one the enumerator returned with prefetched keys. That may cost another `getattrlist` per entry.
- **Fix:** compute `resolved` only when `exclusions` is non-empty and the entry is a symlink or under a symlinked parent. Read values from `candidate.resourceValues(forKeys:)`, the enumerator's own URL.
- This is the hot loop for every provider and for the Directory Sizer.

**P2 — Validation work per descendant before deletion** (`DiskSweep/Services/SafetyValidator.swift:238-266`, `522-575`)
- For every descendant of a directory being removed, `isProtected` rebuilds about 25 `URL` values and the code calls `resolvingSymlinksInPath()`.
- DerivedData or `node_modules` with 100k+ entries spends seconds just on these allocations, before `removeItem` walks the same tree again.
- **Fix:** precompute the protected roots as path-component arrays in `init`. Inside the walk, symlinks are skipped and volume boundaries are already checked, so per-entry resolution isn't needed.

**P3 — Duplicates read every candidate twice** (`DiskSweep/Services/Analyzers/DuplicateAnalyzer.swift:166-225`)
- Every sample-matched file is fully read for SHA-256 and then fully read again for the byte-by-byte comparison.
- **Fix:** for a sample group of exactly two files, compare bytes directly and skip hashing. For larger groups, either trust SHA-256 (collisions aren't a practical concern) or keep the byte check but stream both files once.
- This roughly halves I/O for large media duplicates.

**P4 — Eager lists and repeated per-render work**
- `CleanupCategoryCard.swift:31-35`, `DownloadsView.swift:151-153,197-238` (every group expanded by default, `:67`), and `DuplicatesView.swift:56-58` build every row with `VStack` and `ForEach`. Trash, user caches, and Downloads can contain thousands of rows.
- `DownloadsView.filteredAnalysis` regroups and re-sorts every file with `localizedStandardCompare`, and `visibleGroups` is evaluated twice per `body`. Each checkbox click repeats all of it.
- `DuplicatesView.swift:56` re-sorts groups the analyzer already sorted.
- **Fix:** use `LazyVStack` (or `List` / `Table`, which also fixes U1). Cache filtered results in `@State`, updated with `.onChange(of:)` on the filter values.

**P5 — Formatter allocation per label** (`DiskSweep/Services/FileSizeFormatter.swift:4-13`)
- A new `ByteCountFormatter` is created for every size label in every row on every render.
- **Fix:** use one static configured formatter, or `Int64.formatted(.byteCount(style: .file))`.

**P6 — Providers run strictly one after another** (`DiskSweep/ViewModels/AppViewModel.swift:151-198`)
- Most providers are I/O-bound on separate trees.
- **Fix:** a `withTaskGroup` with 2–3 concurrent providers would shorten wall-clock time. Insert results in `locationOrder` as they finish. Keep `.utility` priority, and consider `.background` for the launch-time automatic scan to be battery-friendly.

### Concurrency and thread safety

**C1 — Global `@unchecked Sendable` registry** (`DiskSweep/Services/CleanupSnapshotRegistry.swift:8-53`)
- An `NSLock` around a dictionary is correct, but it is process-global, hidden from callers, and shared by the app, all providers, the analyzers, and the tests (T2).
- **Fix:** with a macOS 15 deployment target you can use `Mutex<[String: [UUID: CleanupScanSnapshot]]>` from `Synchronization`. That removes `@unchecked`. Inject the instance through `ScanContext` or the providers, so tests and concurrent scans (D2) get separate instances.

**C2 — Off-main execution depends on a compiler default** (provider `scan` methods, `DiskSweep/Services/CleanupProvider.swift:25-28`)
- Providers do heavy synchronous work inside `nonisolated async` functions: `ProviderPaths.*`, `ElectronAppCacheRules.*`, `AndroidSystemImageRules.*`, `StaleIDEVersionRules.folders`, and `ProjectArtifactRules`. They are called from a MainActor `Task`.
- Today that work runs on the global executor only because `NonisolatedNonsendingByDefault` (SE-0461, part of Xcode's "Approachable Concurrency" setting) is off.
- Turning that setting on would move this synchronous I/O onto the main actor.
- **Fix:** either mark the provider entry points `@concurrent`, or wrap their synchronous rule evaluation in the existing `Task.detached` pattern. Add a comment so a future build-setting change doesn't regress this silently.

**C3 — Quick Look data source without panel control** (`DiskSweep/Services/FinderService.swift:36-53`)
- The code sets `QLPreviewPanel.shared().dataSource` directly without implementing `acceptsPreviewPanelControl(_:)`, `beginPreviewPanelControl(_:)`, and `endPreviewPanelControl(_:)` in the responder chain.
- AppKit may reset the data source when the responder chain changes, which shows up as an empty or stale panel.
- **Fix:** implement the control protocol on a responder, or use SwiftUI's `.quickLookPreview($url, in: urls)` (macOS 11+). That also removes the `@preconcurrency` conformance.

### Maintainability and complexity

**M1 — Duplicated logic**
- There are six implementations of "same or descendant path": `FileSystemScanner.swift:318`, `SafetyValidator.swift:592`, `ProjectArtifactsProvider.swift:513`, `CleanupEngine.swift:292`, `AppViewModel.swift:466`, and a string-prefix variant in `AnalyzerFileSystem.swift:360`.
- There are two different error-to-`ScanIssue.Kind` mappings: `FileSystemScanner.swift:325-343` and `AnalyzerFileSystem.swift:266-304`.
- The "size, snapshot, cancel, report" sequence is repeated in `ProviderSupport.scanChildren`, `scanDirectoryCandidates`, `XcodeArchivesProvider`, `LogProvider`, `TemporaryFilesProvider`, and `ProjectArtifactsProvider`.
- **Fix:** consolidate into one `URL` extension, one error mapper, and one sizing-and-snapshot helper. That keeps safety-critical comparisons in one place.

**M2 — Dead or unreachable code**
- `HomebrewCacheProvider.validEnvironmentCache` only accepts the standard path, so it can never add a root (`HomebrewCacheProvider.swift:46-58`). GUI apps also don't inherit `HOMEBREW_CACHE`.
- `ExclusionSettings.defaultExcludedDirectoryNames` is unused (`SettingsStore.swift:45-49`).
- `DiskUsageAnalyzer` and `LargeFolderScanResult.largestFolders` are used only by tests.
- `FinderService.closeQuickLook`, `CleanupHistoryStore.remove(id:)`, `clear()`, and `SettingsStore.reload()` / `resetToDefaults()` have no UI.
- `DuplicateSelection.preservingOneCopy` is unused by the app (F1).
- The "Scan" and "Rescan" commands do the same thing (`DiskSweepCommands.swift:28-34`).
- `PermissionManager.refreshStatus` has identical `.unknown` branches (`PermissionManager.swift:85-91`).

**M3 — Duplicated navigation**
- Settings exists both as a `Settings` scene (`DiskSweepApp.swift:17-20`) and as a sidebar destination embedding the same two-column view inside the detail column (`RootView.swift:236-237`). That puts a sidebar inside a sidebar.
- Large Folders and Disk Usage share one scan and one state (`RootView.swift:204-231`).
- **Fix:** replace the Settings sidebar row with `SettingsLink`. Consider merging the two analyzers into one screen with "List" and "Map" modes.

**M4 — Misleading exclusion toggle**
- "Version-control metadata: Exclude .git and .svn folders" (`SettingsView.swift:146-148`) only affects analyzers.
- Providers and the validator always exclude `.git` through `FileSystemSafetyPolicy` (`FileSystemScanner.swift:6-9`).
- **Fix:** reword the toggle, for example "In analysis views…".

**M5 — Disk Usage hides direct files** (`DiskSweep/Views/Analyze/DiskUsageView.swift:46-50`)
- Child rows add up to less than the folder total because files stored directly in the folder aren't shown.
- **Fix:** add a synthetic "Files in this folder" row with `size - sum(children)`.

**M6 — Project-file drift** (uncommitted changes in `DiskSweep.xcodeproj`)
- The working-tree `project.pbxproj` adds `DEVELOPMENT_TEAM = 7RLDYXQTNX`, test-target `CODE_SIGN_*` settings, and asset and string-catalog symbol generation. None of these are in `project.yml`, which the README calls the source of truth. Running `xcodegen` would drop them.
- **Fix:** move them into `project.yml`, putting the team ID in an `.xcconfig` that isn't committed if it shouldn't be shared. Or discard them.

**M7 — Localization**
- Model display strings are plain `String` values passed to `Text(String)`: `CleanupLocation.name` / `.explanation`, `CleanupRisk.title`, `SidebarDestination.title`, and `SafetyValidationError` messages. They are never extracted for localization.
- **Fix:** if localization is planned, return `LocalizedStringResource` and add a String Catalog. The pending diff already enables `STRING_CATALOG_GENERATE_SYMBOLS`.

### UI/UX and accessibility

**U1 — No keyboard navigation in custom lists**
- The cleanup cards, Downloads groups, and Duplicates are `ScrollView` + `VStack` with checkbox `Toggle`s.
- There is no arrow-key focus movement, Space-to-toggle, or ⌘A, and VoiceOver users meet a toggle nested inside each `DisclosureGroup` label.
- Large Files already uses `Table`.
- **Fix:** use `List(selection:)` or `Table` with a checkbox column for the other screens. That fixes keyboard and VoiceOver behavior, enables the context menu with `primaryAction`, and gives lazy loading (P4).

### Security

**S1 — Small TOCTOU window at removal** (`DiskSweep/Services/CleanupEngine.swift:156-183`)
- Validation is thorough, but deletion is path-based (`removeItem(at:)` / `trashItem(at:)`). A process running as the same user could swap a parent folder for a symlink between `revalidate` and the removal.
- The risk is low: a same-user process could already delete those files, and the README describes the checks as reducing TOCTOU risk, not eliminating it.
- **Hardening option:** open the approved root with `O_DIRECTORY | O_NOFOLLOW` and traverse with `openat`, then remove with `unlinkat` / `removefile` relative to that descriptor, for permanent deletions.
- **Other notes:** no App Sandbox (documented) and Hardened Runtime is on. Notarize distribution builds as the README states.

### Testing

**T1 — Missing coverage for the risky parts**
- There are no tests for `AppViewModel`: scan and cancel lifecycle (D2, D8), selection scoping (D4), overlap filtering (D7), or the Downloads bridge (D10).
- There are no provider tests for DerivedData with Swift package checkouts (D1) or for packages in the analyzers (D3).
- There are no tolerant-decoding tests (D5).
- `AppViewModel`'s dependencies are already injectable, so these tests can be written without touching the real home folder.
- Swift Testing's parameterized `@Test(arguments:)` would suit the rule tables (Device Support build parsing, IDE version parsing, Android `config.ini` parsing).

**T2 — Shared global state**
- Tests write to `CleanupSnapshotRegistry.shared` using production provider IDs.
- The scheme has `parallelizable = "NO"` (`DiskSweep.xcscheme:43`), so this works today. Turning on parallel testing would make tests interfere with each other. C1 fixes this.

---

## D. Feature ideas

| # | Idea | Notes |
| --- | --- | --- |
| F1 | **Duplicates → Move to Trash.** Today the Duplicates screen only says "Use Finder" (`DuplicatesView.swift:61-66`), and `selectedDuplicateFileIDs` never reaches cleanup. | Add an analysis snapshot provider like Downloads, and enforce `DuplicateSelection.preservingOneCopy` in the view model, not only in the view. |
| F2 | **Large Files → multi-select and Move to Trash.** | Same bridge as F1. The `Table` already exists, so switch it to `Set<UUID>` selection. |
| F3 | **Undo / Put Back.** `trashItem(at:resultingItemURL:)` is called with `nil` (`CleanupEngine.swift:179-182`). | Record each item's Trash location in `CleanedItemRecord`, then offer "Undo" on the completion sheet and "Put Back" in History. |
| F4 | **APFS clone-aware sizes.** Copies made with `cp -c` share blocks, so removing one frees nothing. | Read `ATTR_CMNEXT_PRIVATESIZE` with `getattrlist` (macOS 10.15+) to show real reclaimable bytes in Duplicates and Large Files. |
| F5 | **Running-app awareness.** | Match `NSWorkspace.shared.runningApplications` bundle IDs to cache folder names. Warn or deselect caches of running apps (this also reduces L2). |
| F6 | **Simulators.** Simulator support today is limited to caches. | Offer "Delete unavailable simulators" and old runtimes through `xcrun simctl delete unavailable` and `simctl runtime list`. Use the tool, not path deletion, because runtimes live in system-owned locations. |
| F7 | **Custom Android SDK and AVD locations.** The paths are hard-coded (`AndroidSystemImagesProvider.swift:9-18`). | Read `sdk.dir` and `ANDROID_AVD_HOME` / `ANDROID_USER_HOME` from Android Studio's settings, or let the user choose. |
| F8 | **History management.** | "Clear History" and per-entry delete. The store already supports both. When "Keep local cleanup history" is turned off, offer to delete the existing file. |
| F9 | **Menu bar extra.** | A `MenuBarExtra` showing free space with a low-space threshold notification and a quick "Scan" button. |
| F10 | **Disk Usage chart.** | A Swift Charts `SectorMark` sunburst or donut (macOS 14+) for the current level, alongside the existing bars. |

---

## What's already solid

These don't need changes. They are listed so the findings above are read in proportion.

- **Safety design:** the safety layer is allowlist-based, canonicalizes roots, refuses symlinks and volume crossings, revalidates identity right before mutation, and repeats rule checks for rule-based locations. It is careful and well-tested (`SafetyValidatorTests`, `CleanupEngineTests`, `DeveloperCleanupProvidersTests`).
- **Off-main work:** heavy filesystem work runs in `Task.detached(priority: .utility)` with cancellation forwarded through `withTaskCancellationHandler`, and cancellation is checked inside the hot loops.
- **Swift 6:** the code compiles in Swift 6 language mode with complete concurrency checking. Models are `Sendable` value types, and UI stores are `@MainActor @Observable` with `@ObservationIgnored` on their dependencies.
- **Honest reporting:** Trash moves are not credited as recovered space, and history migration is conservative.
- **Dependencies:** there are no third-party dependencies and no network code.
