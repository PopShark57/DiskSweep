import Foundation

enum ProviderSupport {
    static func scanChildren(
        providerID: String,
        location: CleanupLocation,
        roots: [URL],
        context: ScanContext,
        progress: @escaping ScanProgressHandler,
        excludedChildNames: Set<String> = [],
        forceDefaultSelection: Bool? = nil
    ) async -> ProviderScanResult {
        let scanner = FileSystemScanner()
        let sizer = DirectorySizer()
        let excludedNames = Set(excludedChildNames.map { $0.lowercased() })
        var cleanupItems: [CleanupItem] = []
        var issues: [ScanIssue] = []
        var snapshots: [UUID: CleanupScanSnapshot] = [:]
        var totalFiles = 0
        var totalBytes: Int64 = 0
        let rootValidator = SafetyValidator(homeDirectory: context.homeDirectory)
        let existingRoots = existingDirectories(roots).compactMap { root -> URL? in
            do {
                _ = try rootValidator.preflightApprovedRoot(root, location: location)
                return root
            } catch {
                issues.append(ScanIssue(
                    kind: .inaccessible,
                    path: root.path,
                    message: error.localizedDescription
                ))
                return nil
            }
        }

        rootScan: for root in existingRoots {
            if Task.isCancelled {
                issues.append(ScanIssue(
                    kind: .cancelled,
                    path: root.path,
                    message: "Scanning was cancelled."
                ))
                break rootScan
            }

            let childOptions = FileSystemScanOptions(
                recursive: false,
                includeFiles: true,
                includeDirectories: true,
                includeSymbolicLinks: true,
                includeHiddenFiles: context.showHiddenFiles,
                skipPackages: false,
                skipCloudPlaceholders: true,
                collectItems: true,
                batchSize: 128,
                exclusionURLs: context.exclusions,
                excludedNames: [],
                excludedExtensions: ["photoslibrary", "photolibrary", "backupdb"]
            )

            let children: FileSystemScanResult
            do {
                children = try await scanner.scan(root: root, options: childOptions)
                issues.append(contentsOf: children.issues)
            } catch is CancellationError {
                issues.append(ScanIssue(
                    kind: .cancelled,
                    path: root.path,
                    message: "Scanning was cancelled."
                ))
                break rootScan
            } catch {
                issues.append(FileSystemScanner.issue(for: error, at: root))
                continue
            }

            for child in children.items {
                if Task.isCancelled {
                    issues.append(ScanIssue(
                        kind: .cancelled,
                        path: child.url.path,
                        message: "Scanning was cancelled."
                    ))
                    break rootScan
                }
                if excludedNames.contains(child.name.lowercased()) { continue }

                var size = child.size
                var fileCount = child.kind == .file ? 1 : 0
                var isDeletable = child.kind == .file || child.kind == .directory
                var explanation = location.explanation
                if FileSystemSafetyPolicy.excludes(child.url) {
                    isDeletable = false
                    explanation += " This item is protected by DiskSweep's default scan exclusions."
                }

                if child.kind == .directory {
                    let baselineFiles = totalFiles
                    let baselineBytes = totalBytes
                    do {
                        let measured = try await sizer.size(
                            of: child.url,
                            exclusions: context.exclusions,
                            includeHiddenFiles: true,
                            skipPackages: false,
                            batchSize: 256
                        ) { update in
                            await progress(ScanProgress(
                                phase: .enumerating,
                                location: location,
                                currentPath: update.currentURL.path,
                                filesAnalyzed: baselineFiles + update.filesAnalyzed,
                                bytesFound: baselineBytes + update.bytesFound,
                                completedProviders: 0,
                                totalProviders: 1
                            ))
                        }
                        size = measured.byteCount
                        fileCount = measured.fileCount
                        issues.append(contentsOf: measured.issues)
                        if !measured.excludedURLs.isEmpty || !measured.issues.isEmpty {
                            isDeletable = false
                            explanation += " This folder contains excluded or uninspected content, so DiskSweep will not remove it as a unit."
                        }
                    } catch is CancellationError {
                        issues.append(ScanIssue(
                            kind: .cancelled,
                            path: child.url.path,
                            message: "Scanning was cancelled."
                        ))
                        break rootScan
                    } catch {
                        issues.append(FileSystemScanner.issue(for: error, at: child.url))
                        isDeletable = false
                        explanation += " DiskSweep could not inspect every descendant, so this folder cannot be removed."
                    }
                }

                totalBytes += max(0, size)
                totalFiles += max(0, fileCount)
                let identity = try? SafetyValidator.captureIdentity(at: child.url)
                if identity == nil {
                    isDeletable = false
                    issues.append(ScanIssue(
                        kind: .disappeared,
                        path: child.url.path,
                        message: "The item changed or disappeared before its cleanup identity could be recorded."
                    ))
                }

                let cleanupItem = CleanupItem(
                    providerID: providerID,
                    location: location,
                    name: displayName(for: child.url, root: root, location: location),
                    url: child.url,
                    size: size,
                    fileCount: fileCount,
                    kind: child.kind,
                    modifiedAt: child.modifiedAt,
                    risk: location.risk,
                    explanation: explanation,
                    isSelectedByDefault: forceDefaultSelection,
                    isDeletable: isDeletable
                )
                cleanupItems.append(cleanupItem)
                if let identity {
                    snapshots[cleanupItem.id] = CleanupScanSnapshot(
                        identity: identity,
                        exclusionRoots: context.exclusions
                    )
                }

                await progress(ScanProgress(
                    phase: .enumerating,
                    location: location,
                    currentPath: child.url.path,
                    filesAnalyzed: totalFiles,
                    bytesFound: totalBytes,
                    completedProviders: 0,
                    totalProviders: 1
                ))
            }
        }

        if Task.isCancelled || issues.contains(where: { $0.kind == .cancelled }) {
            if !issues.contains(where: { $0.kind == .cancelled }) {
                issues.append(ScanIssue(
                    kind: .cancelled,
                    path: existingRoots.last?.path ?? "",
                    message: "Scanning was cancelled."
                ))
            }
            CleanupSnapshotRegistry.shared.replace(
                providerID: providerID,
                snapshots: [:]
            )
            await progress(ScanProgress(
                phase: .cancelled,
                location: location,
                currentPath: existingRoots.last?.path ?? "",
                filesAnalyzed: totalFiles,
                bytesFound: totalBytes,
                completedProviders: 0,
                totalProviders: 1
            ))
            return ProviderScanResult(
                location: location,
                items: [],
                issues: issues
            )
        }

        await progress(ScanProgress(
            phase: Task.isCancelled ? .cancelled : .completed,
            location: location,
            currentPath: existingRoots.last?.path ?? "",
            filesAnalyzed: totalFiles,
            bytesFound: totalBytes,
            completedProviders: Task.isCancelled ? 0 : 1,
            totalProviders: 1
        ))

        CleanupSnapshotRegistry.shared.replace(
            providerID: providerID,
            snapshots: snapshots
        )

        return ProviderScanResult(
            location: location,
            items: cleanupItems.sorted { $0.size > $1.size },
            issues: issues
        )
    }

    static func existingDirectories(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.compactMap { requested in
            let url = requested.standardizedFileURL
            guard let identity = try? SafetyValidator.captureIdentity(at: url),
                  identity.kind == .directory,
                  seen.insert(url.path).inserted else {
                return nil
            }
            return url
        }
    }

    static func displayName(
        for url: URL,
        root: URL,
        location: CleanupLocation
    ) -> String {
        let itemName = humanReadableIdentifier(url.lastPathComponent)

        switch location {
        case .applicationCaches:
            let components = root.pathComponents
            if let index = components.lastIndex(where: {
                $0 == "Containers" || $0 == "Group Containers"
            }), components.indices.contains(index + 1) {
                return "\(humanReadableIdentifier(components[index + 1])) — \(itemName)"
            }
            return itemName
        case .browserCaches:
            return "\(browserName(for: root)) — \(itemName)"
        default:
            return itemName
        }
    }

    static func humanReadableIdentifier(_ identifier: String) -> String {
        let knownNames: [String: String] = [
            "com.apple.safari": "Safari",
            "com.google.chrome": "Google Chrome",
            "google": "Google Chrome",
            "chromium": "Chromium",
            "com.microsoft.edgemac": "Microsoft Edge",
            "microsoft edge": "Microsoft Edge",
            "bravesoftware": "Brave",
            "firefox": "Firefox",
            "mozilla": "Firefox",
            "com.spotify.client": "Spotify",
            "com.hnc.discord": "Discord",
            "com.apple.dt.xcode": "Xcode",
            "org.swift.swiftpm": "Swift Package Manager"
        ]
        if let known = knownNames[identifier.lowercased()] { return known }

        let components = identifier
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: ".")
            .filter { component in
                !["com", "org", "net", "io", "app"].contains(component.lowercased())
            }
        guard let mostSpecific = components.last else { return identifier }
        return mostSpecific
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func browserName(for url: URL) -> String {
        let path = url.path.lowercased()
        if path.contains("brave") { return "Brave" }
        if path.contains("microsoft edge") { return "Microsoft Edge" }
        if path.contains("chromium") { return "Chromium" }
        if path.contains("google/chrome") { return "Google Chrome" }
        if path.contains("firefox") || path.contains("mozilla") { return "Firefox" }
        if path.contains("safari") { return "Safari" }
        return "Browser"
    }
}

enum ProviderPaths {
    static func applicationCacheRoots(homeDirectory: URL) -> [URL] {
        let manager = FileManager()
        let containerLocations = [
            homeDirectory.appendingPathComponent("Library/Containers", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Group Containers", isDirectory: true)
        ]
        var roots: [URL] = []

        for parent in containerLocations {
            let containers = (try? manager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for container in containers {
                if parent.lastPathComponent == "Containers" {
                    if container.lastPathComponent == "com.apple.Safari" { continue }
                    roots.append(container.appendingPathComponent(
                        "Data/Library/Caches",
                        isDirectory: true
                    ))
                } else {
                    roots.append(container.appendingPathComponent(
                        "Library/Caches",
                        isDirectory: true
                    ))
                }
            }
        }
        return ProviderSupport.existingDirectories(roots)
    }

    static func browserCacheRoots(homeDirectory: URL) -> [URL] {
        var roots = [
            homeDirectory.appendingPathComponent("Library/Caches/com.apple.Safari", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/Google/Chrome", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/Chromium", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/Microsoft Edge", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/BraveSoftware/Brave-Browser", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/Firefox/Profiles", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/Mozilla/Firefox/Profiles", isDirectory: true),
            homeDirectory.appendingPathComponent(
                "Library/Containers/com.apple.Safari/Data/Library/Caches",
                isDirectory: true
            )
        ]

        let profileBases = [
            homeDirectory.appendingPathComponent(
                "Library/Application Support/Google/Chrome",
                isDirectory: true
            ),
            homeDirectory.appendingPathComponent(
                "Library/Application Support/Chromium",
                isDirectory: true
            ),
            homeDirectory.appendingPathComponent(
                "Library/Application Support/Microsoft Edge",
                isDirectory: true
            ),
            homeDirectory.appendingPathComponent(
                "Library/Application Support/BraveSoftware/Brave-Browser",
                isDirectory: true
            )
        ]

        let manager = FileManager()
        let cacheNames = ["Cache", "Code Cache", "GPUCache", "DawnCache", "GrShaderCache"]
        for base in profileBases {
            let profiles = (try? manager.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for profile in profiles where isBrowserProfileDirectory(profile.lastPathComponent) {
                roots.append(contentsOf: cacheNames.map {
                    profile.appendingPathComponent($0, isDirectory: true)
                })
            }
        }

        return ProviderSupport.existingDirectories(roots)
    }

    static func simulatorCacheRoots(homeDirectory: URL) -> [URL] {
        let coreSimulator = homeDirectory.appendingPathComponent(
            "Library/Developer/CoreSimulator",
            isDirectory: true
        )
        var roots = [coreSimulator.appendingPathComponent("Caches", isDirectory: true)]
        let devices = coreSimulator.appendingPathComponent("Devices", isDirectory: true)
        let deviceDirectories = (try? FileManager().contentsOfDirectory(
            at: devices,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        roots.append(contentsOf: deviceDirectories.map {
            $0.appendingPathComponent("data/Library/Caches", isDirectory: true)
        })
        return ProviderSupport.existingDirectories(roots)
    }

    private static func isBrowserProfileDirectory(_ name: String) -> Bool {
        name == "Default"
            || name == "Guest Profile"
            || name.hasPrefix("Profile ")
    }
}
