import Foundation

/// The remote configuration document.
///
/// ```json
/// {
///   "flags": { "newOnboarding": true, "max_upload_count": 10 },
///   "experiments": [
///     {
///       "id": "checkout-2026-q4",
///       "flag": "checkoutStyle",
///       "variants": [
///         { "name": "control",   "value": "classic", "weight": 50 },
///         { "name": "treatment", "value": "express", "weight": 50 }
///       ]
///     }
///   ]
/// }
/// ```
public struct RemoteConfig: Codable, Sendable, Equatable {
    public var flags: [String: FlagRawValue]
    public var experiments: [Experiment]

    public init(flags: [String: FlagRawValue] = [:], experiments: [Experiment] = []) {
        self.flags = flags
        self.experiments = experiments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flags = try container.decodeIfPresent([String: FlagRawValue].self, forKey: .flags) ?? [:]
        experiments = try container.decodeIfPresent([Experiment].self, forKey: .experiments) ?? []
    }
}

/// An A/B (or A/B/n) test that controls one flag.
///
/// Users are assigned to a variant by hashing the experiment's salt with a
/// stable bucketing ID (usually a user or install ID), so the same user always
/// lands in the same variant, on every device and every launch, with no
/// server round trip.
///
/// Weights are relative, so `[1, 1]`, `[50, 50]` and `[500, 500]` all split
/// evenly. A gradual rollout is an experiment with two variants:
/// `true` at weight 10 and `false` at weight 90.
public struct Experiment: Codable, Sendable, Equatable, Identifiable {
    public struct Variant: Codable, Sendable, Hashable {
        public var name: String
        public var value: FlagRawValue
        public var weight: Int

        public init(name: String, value: FlagRawValue, weight: Int) {
            self.name = name
            self.value = value
            self.weight = weight
        }
    }

    public var id: String
    /// The key of the flag this experiment controls.
    public var flag: String
    public var variants: [Variant]
    /// Changing the salt re-shuffles assignments. Defaults to `id`.
    public var salt: String?

    public init(id: String, flag: String, variants: [Variant], salt: String? = nil) {
        self.id = id
        self.flag = flag
        self.variants = variants
        self.salt = salt
    }

    /// The variant for `bucketingID`, or `nil` if the experiment has no positive weights.
    public func variant(for bucketingID: String) -> Variant? {
        let total = variants.reduce(0) { $0 + max($1.weight, 0) }
        guard total > 0 else { return nil }

        var point = Bucketing.bucket(for: "\(salt ?? id):\(bucketingID)", count: total)
        for variant in variants {
            let weight = max(variant.weight, 0)
            if point < weight { return variant }
            point -= weight
        }
        return nil
    }
}

// FNV-1a hash used for bucketing — stable across launches and devices, unlike Swift's Hasher.
enum Bucketing {
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func bucket(for string: String, count: Int) -> Int {
        Int(fnv1a(string) % UInt64(count))
    }
}
