//
//  AppDataLocationResolver.swift
//  osaurus
//
//  Shared app data/config/cache location resolution.
//

import Foundation

/// Resolves Osaurus storage locations from Apple/XDG-standard candidates with
/// read-only fallback to existing legacy locations.
public enum AppDataLocationResolver {
    public static let testRootEnvironmentVariable = "OSAURUS_TEST_ROOT"
    public static let standardApplicationSupportFolderName = "Osaurus"
    public static let standardCacheFolderName = "Osaurus"
    public static let xdgFolderName = "osaurus"
    public static let legacyHomeFolderName = ".osaurus"
    public static let legacyApplicationSupportFolderName = "com.dinoki.osaurus"

    public enum LocationKind: String, CaseIterable, Sendable {
        case data
        case config
        case cache
    }

    public enum LocationSource: String, Sendable {
        case standard
        case legacyHomeDotDirectory = "legacy_home_dot_directory"
        case legacyApplicationSupport = "legacy_application_support"
        case testOverride = "test_override"
        case environmentOverride = "environment_override"
    }

    public struct Candidate: Equatable, Sendable {
        public let kind: LocationKind
        public let source: LocationSource
        public let url: URL
        public let exists: Bool
        public let isSelected: Bool

        public init(
            kind: LocationKind,
            source: LocationSource,
            url: URL,
            exists: Bool,
            isSelected: Bool
        ) {
            self.kind = kind
            self.source = source
            self.url = url
            self.exists = exists
            self.isSelected = isSelected
        }
    }

    public struct ResolvedLocation: Equatable, Sendable {
        public let kind: LocationKind
        public let source: LocationSource
        public let url: URL

        public init(kind: LocationKind, source: LocationSource, url: URL) {
            self.kind = kind
            self.source = source
            self.url = url
        }
    }

    public struct ResolvedLocations: Equatable, Sendable {
        public let data: ResolvedLocation
        public let config: ResolvedLocation
        public let cache: ResolvedLocation
        public let candidates: [Candidate]
        public let standardDataRoot: URL
        public let standardConfigRoot: URL
        public let standardCacheRoot: URL
        public let legacyHomeRoot: URL
        public let legacyApplicationSupportRoot: URL?

        public var dataRoot: URL { data.url }
        public var configRoot: URL { config.url }
        public var cacheRoot: URL { cache.url }

        public var usesLegacyDataRoot: Bool {
            data.source == .legacyHomeDotDirectory || data.source == .legacyApplicationSupport
        }

        public func candidates(for kind: LocationKind) -> [Candidate] {
            candidates.filter { $0.kind == kind }
        }

        public var dataSearchRoots: [URL] {
            searchURLs(for: .data)
        }

        public var configSearchDirectories: [URL] {
            searchURLs(for: .config)
        }

        public var cacheSearchDirectories: [URL] {
            searchURLs(for: .cache)
        }

        public init(
            data: ResolvedLocation,
            config: ResolvedLocation,
            cache: ResolvedLocation,
            candidates: [Candidate],
            standardDataRoot: URL,
            standardConfigRoot: URL,
            standardCacheRoot: URL,
            legacyHomeRoot: URL,
            legacyApplicationSupportRoot: URL?
        ) {
            self.data = data
            self.config = config
            self.cache = cache
            self.candidates = candidates
            self.standardDataRoot = standardDataRoot
            self.standardConfigRoot = standardConfigRoot
            self.standardCacheRoot = standardCacheRoot
            self.legacyHomeRoot = legacyHomeRoot
            self.legacyApplicationSupportRoot = legacyApplicationSupportRoot
        }

        private func searchURLs(for kind: LocationKind) -> [URL] {
            let selected: URL
            switch kind {
            case .data:
                selected = data.url
            case .config:
                selected = config.url
            case .cache:
                selected = cache.url
            }

            var urls = [selected]
            for candidate in candidates where candidate.kind == kind {
                if !urls.contains(where: { samePath($0, candidate.url) }) {
                    urls.append(candidate.url)
                }
            }
            return urls
        }
    }

    public struct PlatformDirectories: Equatable, Sendable {
        public let homeDirectory: URL
        public let applicationSupportDirectory: URL?
        public let cachesDirectory: URL?
        public let xdgDataHome: URL
        public let xdgConfigHome: URL
        public let xdgCacheHome: URL

        public init(
            homeDirectory: URL,
            applicationSupportDirectory: URL?,
            cachesDirectory: URL?,
            xdgDataHome: URL,
            xdgConfigHome: URL,
            xdgCacheHome: URL
        ) {
            self.homeDirectory = homeDirectory
            self.applicationSupportDirectory = applicationSupportDirectory
            self.cachesDirectory = cachesDirectory
            self.xdgDataHome = xdgDataHome
            self.xdgConfigHome = xdgConfigHome
            self.xdgCacheHome = xdgCacheHome
        }
    }

    public static func platformDirectories(
        fileManager fm: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PlatformDirectories {
        let home = fm.homeDirectoryForCurrentUser
        return PlatformDirectories(
            homeDirectory: home,
            applicationSupportDirectory:
                fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            cachesDirectory: fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
            xdgDataHome: xdgDirectory(
                environmentName: "XDG_DATA_HOME",
                fallback: home.appendingPathComponent(".local/share", isDirectory: true),
                environment: environment
            ),
            xdgConfigHome: xdgDirectory(
                environmentName: "XDG_CONFIG_HOME",
                fallback: home.appendingPathComponent(".config", isDirectory: true),
                environment: environment
            ),
            xdgCacheHome: xdgDirectory(
                environmentName: "XDG_CACHE_HOME",
                fallback: home.appendingPathComponent(".cache", isDirectory: true),
                environment: environment
            )
        )
    }

    public static func resolve(
        overrideRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager fm: FileManager = .default,
        platformDirectories directories: PlatformDirectories? = nil
    ) -> ResolvedLocations {
        let dirs = directories ?? platformDirectories(fileManager: fm, environment: environment)

        if let overrideRoot {
            return overrideLocations(
                root: overrideRoot,
                source: .testOverride,
                fileManager: fm,
                directories: dirs
            )
        }
        if let envRoot = testRoot(from: environment) {
            return overrideLocations(
                root: envRoot,
                source: .environmentOverride,
                fileManager: fm,
                directories: dirs
            )
        }

        let standardData = standardDataRoot(in: dirs)
        let standardConfig = standardConfigRoot(in: dirs)
        let standardCache = standardCacheRoot(in: dirs)
        let legacyHome = dirs.homeDirectory.appendingPathComponent(
            legacyHomeFolderName,
            isDirectory: true
        )
        let legacySupport = dirs.applicationSupportDirectory?.appendingPathComponent(
            legacyApplicationSupportFolderName,
            isDirectory: true
        )

        let dataSource: LocationSource
        let dataRoot: URL
        if directoryExists(legacyHome, fileManager: fm) {
            dataSource = .legacyHomeDotDirectory
            dataRoot = legacyHome
        } else if directoryExists(standardData, fileManager: fm) {
            dataSource = .standard
            dataRoot = standardData
        } else if let legacySupport, directoryExists(legacySupport, fileManager: fm) {
            dataSource = .legacyApplicationSupport
            dataRoot = legacySupport
        } else {
            dataSource = .standard
            dataRoot = standardData
        }

        let config: ResolvedLocation = {
            let legacyHomeConfig = legacyHome.appendingPathComponent("config", isDirectory: true)
            let legacySupportConfig = legacySupport?.appendingPathComponent(
                "config",
                isDirectory: true
            )

            switch dataSource {
            case .legacyHomeDotDirectory:
                return ResolvedLocation(
                    kind: .config,
                    source: .legacyHomeDotDirectory,
                    url: legacyHomeConfig
                )
            case .legacyApplicationSupport:
                return ResolvedLocation(
                    kind: .config,
                    source: .legacyApplicationSupport,
                    url: legacySupportConfig ?? standardConfig
                )
            case .standard:
                if directoryExists(standardConfig, fileManager: fm) {
                    return ResolvedLocation(kind: .config, source: .standard, url: standardConfig)
                }
                if directoryExists(legacyHomeConfig, fileManager: fm) {
                    return ResolvedLocation(
                        kind: .config,
                        source: .legacyHomeDotDirectory,
                        url: legacyHomeConfig
                    )
                }
                if let legacySupportConfig, directoryExists(legacySupportConfig, fileManager: fm) {
                    return ResolvedLocation(
                        kind: .config,
                        source: .legacyApplicationSupport,
                        url: legacySupportConfig
                    )
                }
                return ResolvedLocation(kind: .config, source: .standard, url: standardConfig)
            case .testOverride, .environmentOverride:
                return ResolvedLocation(kind: .config, source: dataSource, url: dataRoot)
            }
        }()

        let cache: ResolvedLocation = {
            let legacyHomeCache = legacyHome.appendingPathComponent("cache", isDirectory: true)
            let legacySupportCache = legacySupport?.appendingPathComponent("cache", isDirectory: true)

            switch dataSource {
            case .legacyHomeDotDirectory:
                return ResolvedLocation(
                    kind: .cache,
                    source: .legacyHomeDotDirectory,
                    url: legacyHomeCache
                )
            case .legacyApplicationSupport:
                return ResolvedLocation(
                    kind: .cache,
                    source: .legacyApplicationSupport,
                    url: legacySupportCache ?? standardCache
                )
            case .standard:
                if directoryExists(standardCache, fileManager: fm) {
                    return ResolvedLocation(kind: .cache, source: .standard, url: standardCache)
                }
                if directoryExists(legacyHomeCache, fileManager: fm) {
                    return ResolvedLocation(
                        kind: .cache,
                        source: .legacyHomeDotDirectory,
                        url: legacyHomeCache
                    )
                }
                if let legacySupportCache, directoryExists(legacySupportCache, fileManager: fm) {
                    return ResolvedLocation(
                        kind: .cache,
                        source: .legacyApplicationSupport,
                        url: legacySupportCache
                    )
                }
                return ResolvedLocation(kind: .cache, source: .standard, url: standardCache)
            case .testOverride, .environmentOverride:
                return ResolvedLocation(
                    kind: .cache,
                    source: dataSource,
                    url: dataRoot.appendingPathComponent("cache", isDirectory: true)
                )
            }
        }()

        let data = ResolvedLocation(kind: .data, source: dataSource, url: dataRoot)
        return ResolvedLocations(
            data: data,
            config: config,
            cache: cache,
            candidates: selectedCandidates(
                selected: [data, config, cache],
                standardData: standardData,
                standardConfig: standardConfig,
                standardCache: standardCache,
                legacyHome: legacyHome,
                legacySupport: legacySupport,
                fileManager: fm
            ),
            standardDataRoot: standardData,
            standardConfigRoot: standardConfig,
            standardCacheRoot: standardCache,
            legacyHomeRoot: legacyHome,
            legacyApplicationSupportRoot: legacySupport
        )
    }

    private static func overrideLocations(
        root: URL,
        source: LocationSource,
        fileManager fm: FileManager,
        directories: PlatformDirectories
    ) -> ResolvedLocations {
        let data = ResolvedLocation(kind: .data, source: source, url: root)
        let config = ResolvedLocation(
            kind: .config,
            source: source,
            url: root.appendingPathComponent("config", isDirectory: true)
        )
        let cache = ResolvedLocation(
            kind: .cache,
            source: source,
            url: root.appendingPathComponent("cache", isDirectory: true)
        )
        let standardData = standardDataRoot(in: directories)
        let standardConfig = standardConfigRoot(in: directories)
        let standardCache = standardCacheRoot(in: directories)
        return ResolvedLocations(
            data: data,
            config: config,
            cache: cache,
            candidates: [
                Candidate(
                    kind: .data,
                    source: source,
                    url: root,
                    exists: directoryExists(root, fileManager: fm),
                    isSelected: true
                ),
                Candidate(
                    kind: .config,
                    source: source,
                    url: config.url,
                    exists: directoryExists(config.url, fileManager: fm),
                    isSelected: true
                ),
                Candidate(
                    kind: .cache,
                    source: source,
                    url: cache.url,
                    exists: directoryExists(cache.url, fileManager: fm),
                    isSelected: true
                ),
            ],
            standardDataRoot: standardData,
            standardConfigRoot: standardConfig,
            standardCacheRoot: standardCache,
            legacyHomeRoot: directories.homeDirectory.appendingPathComponent(
                legacyHomeFolderName,
                isDirectory: true
            ),
            legacyApplicationSupportRoot:
                directories.applicationSupportDirectory?.appendingPathComponent(
                    legacyApplicationSupportFolderName,
                    isDirectory: true
                )
        )
    }

    private static func selectedCandidates(
        selected: [ResolvedLocation],
        standardData: URL,
        standardConfig: URL,
        standardCache: URL,
        legacyHome: URL,
        legacySupport: URL?,
        fileManager fm: FileManager
    ) -> [Candidate] {
        var candidates: [Candidate] = []

        func append(kind: LocationKind, source: LocationSource, url: URL) {
            let chosen = selected.contains { location in
                location.kind == kind
                    && location.source == source
                    && samePath(location.url, url)
            }
            candidates.append(
                Candidate(
                    kind: kind,
                    source: source,
                    url: url,
                    exists: directoryExists(url, fileManager: fm),
                    isSelected: chosen
                )
            )
        }

        append(kind: .data, source: .standard, url: standardData)
        append(kind: .data, source: .legacyHomeDotDirectory, url: legacyHome)
        if let legacySupport {
            append(kind: .data, source: .legacyApplicationSupport, url: legacySupport)
        }

        append(kind: .config, source: .standard, url: standardConfig)
        append(
            kind: .config,
            source: .legacyHomeDotDirectory,
            url: legacyHome.appendingPathComponent("config", isDirectory: true)
        )
        if let legacySupport {
            append(
                kind: .config,
                source: .legacyApplicationSupport,
                url: legacySupport.appendingPathComponent("config", isDirectory: true)
            )
        }

        append(kind: .cache, source: .standard, url: standardCache)
        append(
            kind: .cache,
            source: .legacyHomeDotDirectory,
            url: legacyHome.appendingPathComponent("cache", isDirectory: true)
        )
        if let legacySupport {
            append(
                kind: .cache,
                source: .legacyApplicationSupport,
                url: legacySupport.appendingPathComponent("cache", isDirectory: true)
            )
        }

        return candidates
    }

    private static func standardDataRoot(in directories: PlatformDirectories) -> URL {
        if let applicationSupportDirectory = directories.applicationSupportDirectory {
            return applicationSupportDirectory.appendingPathComponent(
                standardApplicationSupportFolderName,
                isDirectory: true
            )
        }
        return directories.xdgDataHome.appendingPathComponent(xdgFolderName, isDirectory: true)
    }

    private static func standardConfigRoot(in directories: PlatformDirectories) -> URL {
        if let applicationSupportDirectory = directories.applicationSupportDirectory {
            return applicationSupportDirectory
                .appendingPathComponent(standardApplicationSupportFolderName, isDirectory: true)
                .appendingPathComponent("config", isDirectory: true)
        }
        return directories.xdgConfigHome.appendingPathComponent(xdgFolderName, isDirectory: true)
    }

    private static func standardCacheRoot(in directories: PlatformDirectories) -> URL {
        if let cachesDirectory = directories.cachesDirectory {
            return cachesDirectory.appendingPathComponent(
                standardCacheFolderName,
                isDirectory: true
            )
        }
        return directories.xdgCacheHome.appendingPathComponent(xdgFolderName, isDirectory: true)
    }

    private static func testRoot(from environment: [String: String]) -> URL? {
        guard let raw = environment[testRootEnvironmentVariable]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func xdgDirectory(
        environmentName: String,
        fallback: URL,
        environment: [String: String]
    ) -> URL {
        guard let raw = environment[environmentName]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !raw.isEmpty else {
            return fallback
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return fallback }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static func directoryExists(_ url: URL, fileManager fm: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
}
