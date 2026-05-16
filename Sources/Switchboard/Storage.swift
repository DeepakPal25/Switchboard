import Foundation

// MARK: - Remote sources

/// Fetches the latest ``RemoteConfig``.
///
/// Conform your own type to back Switchboard with Firebase Remote Config,
/// LaunchDarkly, your own API, or a static JSON file on a CDN.
public protocol RemoteConfigSource: Sendable {
    func fetch() async throws -> RemoteConfig
}

/// Loads a ``RemoteConfig`` JSON document from a URL.
public struct HTTPRemoteConfigSource: RemoteConfigSource {
    public let url: URL
    public let headers: [String: String]
    private let session: URLSession

    public init(url: URL, headers: [String: String] = [:], session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.session = session
    }

    public func fetch() async throws -> RemoteConfig {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteConfigError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteConfigError.unacceptableStatus(http.statusCode)
        }
        return try JSONDecoder().decode(RemoteConfig.self, from: data)
    }
}

/// Wraps a closure as a source, e.g. to adapt an existing networking layer.
public struct ClosureRemoteConfigSource: RemoteConfigSource {
    private let body: @Sendable () async throws -> RemoteConfig

    public init(_ body: @escaping @Sendable () async throws -> RemoteConfig) {
        self.body = body
    }

    public func fetch() async throws -> RemoteConfig {
        try await body()
    }
}

public enum RemoteConfigError: Error, Sendable, Equatable {
    case invalidResponse
    case unacceptableStatus(Int)
}

// MARK: - Config cache

/// Persists the last fetched config so the app starts with known values offline.
public protocol ConfigCache {
    func load() -> RemoteConfig?
    func save(_ config: RemoteConfig)
}

/// Stores the config as JSON in the Caches directory.
public struct FileConfigCache: ConfigCache {
    public let fileURL: URL

    public init(fileURL: URL = URL.cachesDirectory.appending(path: "Switchboard/remote-config.json")) {
        self.fileURL = fileURL
    }

    public func load() -> RemoteConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(RemoteConfig.self, from: data)
    }

    public func save(_ config: RemoteConfig) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(config).write(to: fileURL, options: .atomic)
        } catch {
            // A failed cache write only costs freshness on the next cold start.
        }
    }
}

/// A cache that lives only in memory. Useful for tests and previews.
public final class InMemoryConfigCache: ConfigCache {
    public private(set) var config: RemoteConfig?

    public init(_ config: RemoteConfig? = nil) {
        self.config = config
    }

    public func load() -> RemoteConfig? { config }
    public func save(_ config: RemoteConfig) { self.config = config }
}

// MARK: - Override storage

/// Persists local overrides set from the debug menu.
public protocol OverrideStorage {
    func load() -> [String: FlagRawValue]
    func save(_ overrides: [String: FlagRawValue])
}

/// Stores overrides in `UserDefaults` so they survive relaunches.
public final class UserDefaultsOverrideStorage: OverrideStorage {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "switchboard.overrides") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: FlagRawValue] {
        guard let data = defaults.data(forKey: key),
              let overrides = try? JSONDecoder().decode([String: FlagRawValue].self, from: data)
        else { return [:] }
        return overrides
    }

    public func save(_ overrides: [String: FlagRawValue]) {
        if overrides.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Override storage that lives only in memory. Useful for tests and previews.
public final class InMemoryOverrideStorage: OverrideStorage {
    public private(set) var overrides: [String: FlagRawValue]

    public init(_ overrides: [String: FlagRawValue] = [:]) {
        self.overrides = overrides
    }

    public func load() -> [String: FlagRawValue] { overrides }
    public func save(_ overrides: [String: FlagRawValue]) { self.overrides = overrides }
}
