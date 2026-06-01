import Foundation
import Observation

/// Where a flag's current value came from, in order of precedence.
public enum FlagOrigin: Sendable, Hashable {
    /// Set locally from the debug menu. Highest precedence.
    case override
    /// Assigned by an experiment.
    case experiment(id: String, variant: String)
    /// Set in the `flags` section of remote config.
    case remote
    /// The value declared in code.
    case `default`
}

/// The source of truth for an app's flags.
///
/// `FlagStore` is `@Observable`, so SwiftUI views that read `store.flags`
/// update automatically when config is activated or an override changes:
///
/// ```swift
/// @main
/// struct MyApp: App {
///     @State private var flags = FlagStore(
///         AppFlags.self,
///         bucketingID: Installation.id,
///         source: HTTPRemoteConfigSource(url: configURL)
///     )
///
///     var body: some Scene {
///         WindowGroup {
///             RootView()
///                 .environment(flags)
///                 .task { try? await flags.refresh() }
///         }
///     }
/// }
///
/// struct RootView: View {
///     @Environment(FlagStore<AppFlags>.self) private var store
///
///     var body: some View {
///         if store.flags.newOnboarding { NewOnboarding() } else { Onboarding() }
///     }
/// }
/// ```
///
/// Resolution order: override → experiment → remote → default.
@MainActor
@Observable
public final class FlagStore<Flags: FeatureFlagContainer> {
    /// When a freshly fetched config takes effect.
    public enum Activation: Sendable {
        /// Apply right away. Visible UI may change mid-session.
        case immediately
        /// Cache it for the next cold start, or call ``activatePending()``.
        /// Avoids flags flipping under a user mid-flow.
        case nextLaunch
    }

    /// The current, fully resolved flags.
    public private(set) var flags: Flags
    public private(set) var activeConfig: RemoteConfig
    /// A config fetched with ``Activation/nextLaunch`` that hasn't been applied yet.
    public private(set) var pendingConfig: RemoteConfig?
    public private(set) var overrides: [String: FlagRawValue]
    /// The variant this user is in, keyed by experiment ID.
    public private(set) var assignments: [String: Experiment.Variant]
    public private(set) var lastRefreshDate: Date?
    public private(set) var lastRefreshError: (any Error)?

    public let bucketingID: String
    /// When `false` (e.g. in App Store builds), stored overrides are ignored and new ones are rejected.
    public let overridesEnabled: Bool

    private var resolvedValues: [String: FlagRawValue]

    @ObservationIgnored private let configSource: (any RemoteConfigSource)?
    @ObservationIgnored private let cache: (any ConfigCache)?
    @ObservationIgnored private let overrideStorage: any OverrideStorage
    @ObservationIgnored private let onAssignment: (@MainActor (Experiment, Experiment.Variant) -> Void)?

    /// - Parameters:
    ///   - type: The `@FeatureFlags` struct.
    ///   - bucketingID: A stable per-user or per-install ID used for experiment assignment.
    ///   - source: Where to fetch remote config from. `nil` for local-only flags.
    ///   - cache: Persists the last fetched config. Loaded synchronously at init.
    ///   - overrideStorage: Persists debug-menu overrides.
    ///   - overridesEnabled: Pass `false` in release builds to ignore overrides entirely.
    ///   - onAssignment: Called when the user is newly assigned to an experiment variant;
    ///     forward it to analytics.
    public init(
        _ type: Flags.Type = Flags.self,
        bucketingID: String,
        source: (any RemoteConfigSource)? = nil,
        cache: (any ConfigCache)? = FileConfigCache(),
        overrideStorage: any OverrideStorage = UserDefaultsOverrideStorage(),
        overridesEnabled: Bool = true,
        onAssignment: (@MainActor (Experiment, Experiment.Variant) -> Void)? = nil
    ) {
        let config = cache?.load() ?? RemoteConfig()
        let overrides = overridesEnabled ? overrideStorage.load() : [:]
        let resolution = Resolution(config: config, overrides: overrides, bucketingID: bucketingID)

        self.bucketingID = bucketingID
        self.overridesEnabled = overridesEnabled
        self.configSource = source
        self.cache = cache
        self.overrideStorage = overrideStorage
        self.onAssignment = onAssignment
        self.activeConfig = config
        self.overrides = overrides
        self.assignments = resolution.assignments
        self.resolvedValues = resolution.values
        self.flags = Flags(resolver: FlagResolver(values: resolution.values))

        reportAssignments(previous: [:])
    }

    /// A store with no persistence or network, for SwiftUI previews and tests.
    public static func inMemory(
        config: RemoteConfig = RemoteConfig(),
        overrides: [String: FlagRawValue] = [:],
        bucketingID: String = "preview"
    ) -> FlagStore {
        FlagStore(
            bucketingID: bucketingID,
            source: nil,
            cache: InMemoryConfigCache(config),
            overrideStorage: InMemoryOverrideStorage(overrides)
        )
    }

    public var definitions: [FlagDefinition] { Flags.definitions }

    // MARK: Remote config

    /// Fetches remote config and caches it.
    ///
    /// On failure the current config stays active and the error is both
    /// thrown and stored in ``lastRefreshError``.
    public func refresh(activation: Activation = .immediately) async throws {
        guard let configSource else { return }
        do {
            let config = try await configSource.fetch()
            cache?.save(config)
            lastRefreshDate = .now
            lastRefreshError = nil
            switch activation {
            case .immediately:
                pendingConfig = nil
                activate(config)
            case .nextLaunch:
                pendingConfig = config
            }
        } catch {
            lastRefreshError = error
            throw error
        }
    }

    /// Applies a config fetched with ``Activation/nextLaunch``. Returns `false` if none is pending.
    @discardableResult
    public func activatePending() -> Bool {
        guard let pendingConfig else { return false }
        self.pendingConfig = nil
        activate(pendingConfig)
        return true
    }

    // MARK: Overrides

    /// Sets (or with `nil`, clears) a local override.
    public func setOverride(_ value: FlagRawValue?, forKey key: String) {
        guard overridesEnabled else { return }
        overrides[key] = value
        overrideStorage.save(overrides)
        recompute()
    }

    public func setOverride(_ value: some FlagValue, forKey key: String) {
        setOverride(value.flagRawValue, forKey: key)
    }

    public func removeAllOverrides() {
        guard !overrides.isEmpty else { return }
        overrides = [:]
        overrideStorage.save(overrides)
        recompute()
    }

    // MARK: Introspection

    /// The value currently in effect for `key`, including the default.
    public func effectiveValue(forKey key: String) -> FlagRawValue? {
        resolvedValues[key] ?? definitions.first { $0.key == key }?.defaultValue
    }

    /// Why a flag has its current value.
    public func origin(forKey key: String) -> FlagOrigin {
        if overrides[key] != nil { return .override }
        if let experiment = activeConfig.experiments.first(where: { $0.flag == key && assignments[$0.id] != nil }),
           let variant = assignments[experiment.id] {
            return .experiment(id: experiment.id, variant: variant.name)
        }
        if activeConfig.flags[key] != nil { return .remote }
        return .default
    }

    /// Whether remote config or an override supplied a value of the wrong type,
    /// in which case the default is being used.
    public func hasTypeMismatch(forKey key: String) -> Bool {
        guard let definition = definitions.first(where: { $0.key == key }),
              let value = resolvedValues[key]
        else { return false }
        return !value.isCompatible(with: definition.defaultValue)
    }

    // MARK: Private

    private func activate(_ config: RemoteConfig) {
        activeConfig = config
        recompute()
    }

    private func recompute() {
        let previous = assignments
        let resolution = Resolution(config: activeConfig, overrides: overrides, bucketingID: bucketingID)
        assignments = resolution.assignments
        resolvedValues = resolution.values
        flags = Flags(resolver: FlagResolver(values: resolution.values))
        reportAssignments(previous: previous)
    }

    private func reportAssignments(previous: [String: Experiment.Variant]) {
        guard let onAssignment else { return }
        for experiment in activeConfig.experiments {
            guard let variant = assignments[experiment.id], previous[experiment.id] != variant else { continue }
            onAssignment(experiment, variant)
        }
    }
}

// Merges remote flags, experiment assignments, and overrides into a single flat value map.
struct Resolution: Sendable {
    let values: [String: FlagRawValue]
    let assignments: [String: Experiment.Variant]

    init(config: RemoteConfig, overrides: [String: FlagRawValue], bucketingID: String) {
        var values = config.flags
        var assignments: [String: Experiment.Variant] = [:]
        for experiment in config.experiments {
            guard let variant = experiment.variant(for: bucketingID) else { continue }
            assignments[experiment.id] = variant
            values[experiment.flag] = variant.value
        }
        values.merge(overrides) { _, override in override }
        self.values = values
        self.assignments = assignments
    }
}
