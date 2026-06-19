import Foundation
import Testing
@testable import Switchboard

enum CheckoutStyle: String, CaseIterable, FlagValue {
    case classic, express, oneTap
}

@FeatureFlags
struct TestFlags {
    /// Shows the redesigned onboarding flow.
    var newOnboarding: Bool = false

    /// Maximum number of parallel uploads.
    @FlagKey("max_upload_count")
    var maxUploads: Int = 5

    var discountRate: Double = 0.1
    var welcomeTitle: String = "Welcome"
    var checkoutStyle: CheckoutStyle = .classic

    /// Computed properties are ignored by the macro.
    var isAggressiveUpload: Bool { maxUploads > 10 }
}

struct StubSource: RemoteConfigSource {
    let config: RemoteConfig
    func fetch() async throws -> RemoteConfig { config }
}

struct FailingSource: RemoteConfigSource {
    struct Failure: Error {}
    func fetch() async throws -> RemoteConfig { throw Failure() }
}

@MainActor
func makeStore(
    config: RemoteConfig? = nil,
    overrides: [String: FlagRawValue] = [:],
    source: (any RemoteConfigSource)? = nil,
    cache: InMemoryConfigCache? = nil,
    overrideStorage: InMemoryOverrideStorage? = nil,
    overridesEnabled: Bool = true,
    bucketingID: String = "user-1"
) -> FlagStore<TestFlags> {
    FlagStore(
        TestFlags.self,
        bucketingID: bucketingID,
        source: source,
        cache: cache ?? InMemoryConfigCache(config),
        overrideStorage: overrideStorage ?? InMemoryOverrideStorage(overrides),
        overridesEnabled: overridesEnabled
    )
}

// MARK: - Macro output

@Suite("@FeatureFlags expansion")
struct MacroTests {
    @Test("Generates a definition per stored property, in declaration order")
    func definitions() {
        let keys = TestFlags.definitions.map(\.key)
        #expect(keys == ["newOnboarding", "max_upload_count", "discountRate", "welcomeTitle", "checkoutStyle"])
    }

    @Test("Captures doc comments, defaults and enum options")
    func metadata() throws {
        let onboarding = try #require(TestFlags.definitions.first { $0.key == "newOnboarding" })
        #expect(onboarding.description == "Shows the redesigned onboarding flow.")
        #expect(onboarding.defaultValue == .bool(false))
        #expect(onboarding.options == nil)

        let checkout = try #require(TestFlags.definitions.first { $0.key == "checkoutStyle" })
        #expect(checkout.defaultValue == .string("classic"))
        #expect(checkout.options == [.string("classic"), .string("express"), .string("oneTap")])
    }

    @Test("init() produces the declared defaults")
    func defaults() {
        let flags = TestFlags()
        #expect(flags.newOnboarding == false)
        #expect(flags.maxUploads == 5)
        #expect(flags.discountRate == 0.1)
        #expect(flags.welcomeTitle == "Welcome")
        #expect(flags.checkoutStyle == .classic)
    }
}

// MARK: - Resolution

@Suite("Resolution")
@MainActor
struct ResolutionTests {
    @Test("Remote values replace defaults, using custom keys")
    func remoteValues() {
        let store = makeStore(config: RemoteConfig(flags: [
            "newOnboarding": .bool(true),
            "max_upload_count": .int(12),
            "checkoutStyle": .string("express"),
        ]))

        #expect(store.flags.newOnboarding)
        #expect(store.flags.maxUploads == 12)
        #expect(store.flags.isAggressiveUpload)
        #expect(store.flags.checkoutStyle == .express)
        #expect(store.origin(forKey: "newOnboarding") == .remote)
        #expect(store.origin(forKey: "welcomeTitle") == .default)
    }

    @Test("Values of the wrong type fall back to the default")
    func typeMismatch() {
        let store = makeStore(config: RemoteConfig(flags: [
            "newOnboarding": .string("yes"),
            "checkoutStyle": .string("unknownCase"),
            "discountRate": .int(1),
        ]))

        #expect(store.flags.newOnboarding == false)
        #expect(store.hasTypeMismatch(forKey: "newOnboarding"))
        #expect(store.flags.checkoutStyle == .classic)
        #expect(store.flags.discountRate == 1.0, "Ints are accepted for Double flags")
        #expect(!store.hasTypeMismatch(forKey: "discountRate"))
    }

    @Test("Overrides beat remote values and persist")
    func overrides() {
        let storage = InMemoryOverrideStorage()
        let store = makeStore(config: RemoteConfig(flags: ["newOnboarding": .bool(true)]), overrideStorage: storage)

        store.setOverride(false, forKey: "newOnboarding")

        #expect(store.flags.newOnboarding == false)
        #expect(store.origin(forKey: "newOnboarding") == .override)
        #expect(storage.overrides == ["newOnboarding": .bool(false)])

        let relaunched = makeStore(config: RemoteConfig(flags: ["newOnboarding": .bool(true)]), overrideStorage: storage)
        #expect(relaunched.flags.newOnboarding == false)

        relaunched.setOverride(nil, forKey: "newOnboarding")
        #expect(relaunched.flags.newOnboarding)
        #expect(storage.overrides.isEmpty)
    }

    @Test("removeAllOverrides restores remote and default values")
    func removeAll() {
        let store = makeStore(overrides: ["newOnboarding": .bool(true), "max_upload_count": .int(99)])
        #expect(store.flags.maxUploads == 99)

        store.removeAllOverrides()

        #expect(store.flags.maxUploads == 5)
        #expect(store.overrides.isEmpty)
    }

    @Test("Overrides are ignored when disabled")
    func overridesDisabled() {
        let store = makeStore(overrides: ["newOnboarding": .bool(true)], overridesEnabled: false)
        #expect(store.flags.newOnboarding == false)

        store.setOverride(true, forKey: "newOnboarding")
        #expect(store.flags.newOnboarding == false)
    }
}

// MARK: - Remote refresh

@Suite("Refresh")
@MainActor
struct RefreshTests {
    let fetched = RemoteConfig(flags: ["welcomeTitle": .string("Hi there")])

    @Test("Immediate activation applies and caches the config")
    func immediate() async throws {
        let cache = InMemoryConfigCache()
        let store = makeStore(source: StubSource(config: fetched), cache: cache)

        try await store.refresh()

        #expect(store.flags.welcomeTitle == "Hi there")
        #expect(cache.config == fetched)
        #expect(store.lastRefreshDate != nil)
    }

    @Test("Next-launch activation caches without changing current flags")
    func nextLaunch() async throws {
        let cache = InMemoryConfigCache()
        let store = makeStore(source: StubSource(config: fetched), cache: cache)

        try await store.refresh(activation: .nextLaunch)

        #expect(store.flags.welcomeTitle == "Welcome")
        #expect(store.pendingConfig == fetched)

        let relaunched = makeStore(cache: cache)
        #expect(relaunched.flags.welcomeTitle == "Hi there")

        #expect(store.activatePending())
        #expect(store.flags.welcomeTitle == "Hi there")
        #expect(!store.activatePending())
    }

    @Test("A failed refresh keeps the current config")
    func failure() async {
        let store = makeStore(config: fetched, source: FailingSource())

        await #expect(throws: FailingSource.Failure.self) {
            try await store.refresh()
        }
        #expect(store.flags.welcomeTitle == "Hi there")
        #expect(store.lastRefreshError != nil)
    }
}

// MARK: - Experiments

@Suite("Experiments")
@MainActor
struct ExperimentTests {
    let checkoutTest = Experiment(
        id: "checkout-2026-q4",
        flag: "checkoutStyle",
        variants: [
            .init(name: "control", value: .string("classic"), weight: 50),
            .init(name: "treatment", value: .string("express"), weight: 50),
        ]
    )

    @Test("FNV-1a matches the reference test vectors")
    func fnvVectors() {
        #expect(Bucketing.fnv1a("") == 0xcbf2_9ce4_8422_2325)
        #expect(Bucketing.fnv1a("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(Bucketing.fnv1a("foobar") == 0x8594_4171_f739_67e8)
    }

    @Test("Assignment is deterministic for a bucketing ID")
    func deterministic() {
        for id in ["alice", "bob", "carol"] {
            let first = checkoutTest.variant(for: id)
            #expect(first != nil)
            for _ in 0..<5 {
                #expect(checkoutTest.variant(for: id) == first)
            }
        }
    }

    @Test("Traffic splits according to weights")
    func distribution() {
        let skewed = Experiment(
            id: "rollout",
            flag: "newOnboarding",
            variants: [
                .init(name: "on", value: .bool(true), weight: 20),
                .init(name: "off", value: .bool(false), weight: 80),
            ]
        )
        let sampleSize = 20_000
        let enrolledOn = (0..<sampleSize).filter { skewed.variant(for: "user-\($0)")?.name == "on" }.count
        let share = Double(enrolledOn) / Double(sampleSize)
        #expect(abs(share - 0.2) < 0.02, "Expected about 20% but got \(share)")
    }

    @Test("Zero-weight variants are never assigned")
    func zeroWeight() {
        let experiment = Experiment(
            id: "kill",
            flag: "newOnboarding",
            variants: [
                .init(name: "on", value: .bool(true), weight: 0),
                .init(name: "off", value: .bool(false), weight: 1),
            ]
        )
        #expect((0..<500).allSatisfy { experiment.variant(for: "u\($0)")?.name == "off" })
    }

    @Test("Experiments beat remote values; overrides beat experiments")
    func precedence() {
        let config = RemoteConfig(flags: ["checkoutStyle": .string("oneTap")], experiments: [checkoutTest])
        let store = makeStore(config: config, bucketingID: "alice")
        let assigned = checkoutTest.variant(for: "alice")!

        #expect(store.flags.checkoutStyle.flagRawValue == assigned.value)
        #expect(store.origin(forKey: "checkoutStyle") == .experiment(id: "checkout-2026-q4", variant: assigned.name))

        store.setOverride(CheckoutStyle.oneTap, forKey: "checkoutStyle")
        #expect(store.flags.checkoutStyle == .oneTap)
        #expect(store.origin(forKey: "checkoutStyle") == .override)
    }

    @Test("onAssignment reports each new assignment once")
    func assignmentCallback() async throws {
        let config = RemoteConfig(experiments: [checkoutTest])
        var reported: [String] = []
        let store = FlagStore(
            TestFlags.self,
            bucketingID: "alice",
            source: StubSource(config: config),
            cache: InMemoryConfigCache(config),
            overrideStorage: InMemoryOverrideStorage(),
            onAssignment: { experiment, variant in reported.append("\(experiment.id)=\(variant.name)") }
        )
        #expect(reported.count == 1)

        try await store.refresh()
        #expect(reported.count == 1, "An unchanged assignment is not reported again")
    }
}

// MARK: - Coding

@Suite("RemoteConfig JSON")
struct CodingTests {
    @Test("Decodes plain JSON with untagged values")
    func decodes() throws {
        let json = Data("""
        {
          "flags": { "a": true, "b": 3, "c": 2.5, "d": "text" },
          "experiments": [
            { "id": "e1", "flag": "a", "variants": [ { "name": "on", "value": true, "weight": 1 } ] }
          ]
        }
        """.utf8)

        let config = try JSONDecoder().decode(RemoteConfig.self, from: json)

        #expect(config.flags == ["a": .bool(true), "b": .int(3), "c": .double(2.5), "d": .string("text")])
        #expect(config.experiments.first?.variants.first?.value == .bool(true))
    }

    @Test("Missing sections default to empty")
    func emptyDocument() throws {
        let config = try JSONDecoder().decode(RemoteConfig.self, from: Data("{}".utf8))
        #expect(config == RemoteConfig())
    }

    @Test("Round-trips through JSON")
    func roundTrip() throws {
        let original = RemoteConfig(flags: ["x": .double(1.5), "y": .bool(false)])
        let decoded = try JSONDecoder().decode(RemoteConfig.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
