import Foundation

enum StandardCleanupProviders {
    static func all(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [any CleanupProvider] {
        [
            UserCacheProvider(homeDirectory: homeDirectory),
            ApplicationCacheProvider(homeDirectory: homeDirectory),
            LogProvider(homeDirectory: homeDirectory),
            TemporaryFilesProvider(),
            TrashProvider(homeDirectory: homeDirectory),
            BrowserCacheProvider(homeDirectory: homeDirectory),
            ElectronAppCacheProvider(homeDirectory: homeDirectory),
            XcodeDerivedDataProvider(homeDirectory: homeDirectory),
            XcodeArchivesProvider(homeDirectory: homeDirectory),
            XcodeSimulatorDataProvider(homeDirectory: homeDirectory),
            XcodeDeviceSupportProvider(homeDirectory: homeDirectory),
            SwiftPackageCacheProvider(homeDirectory: homeDirectory),
            HomebrewCacheProvider(homeDirectory: homeDirectory),
            DeveloperToolCacheProvider(homeDirectory: homeDirectory),
            StaleIDEVersionsProvider(homeDirectory: homeDirectory),
            AndroidSystemImagesProvider(homeDirectory: homeDirectory),
            DownloadsProvider(homeDirectory: homeDirectory)
        ]
    }
}
