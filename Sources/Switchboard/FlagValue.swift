/// A JSON-compatible flag value, as stored in remote config and overrides.
///
/// Encodes and decodes *untagged*, so remote config stays plain JSON:
/// `{"newOnboarding": true, "maxUploads": 10, "checkoutStyle": "express"}`.
public enum FlagRawValue: Sendable, Hashable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Flag values must be a bool, number or string."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    /// A human-readable rendering, used by the debug menu.
    public var displayString: String {
        switch self {
        case .bool(let value): String(value)
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        }
    }

    /// Whether a value of this kind can stand in for `other` (ints and doubles are interchangeable).
    public func isCompatible(with other: FlagRawValue) -> Bool {
        switch (self, other) {
        case (.bool, .bool), (.string, .string):
            true
        case (.int, .int), (.int, .double), (.double, .int), (.double, .double):
            true
        default:
            false
        }
    }
}

/// A type that can be stored in a feature flag.
///
/// `Bool`, `Int`, `Double` and `String` conform out of the box. String-backed
/// enums only need to declare conformance:
///
/// ```swift
/// enum CheckoutStyle: String, CaseIterable, FlagValue {
///     case classic, express
/// }
/// ```
///
/// Adding `CaseIterable` makes the debug menu offer a picker of all cases.
public protocol FlagValue: Sendable {
    init?(flagRawValue: FlagRawValue)
    var flagRawValue: FlagRawValue { get }
}

extension FlagValue where Self: RawRepresentable, RawValue == String {
    public init?(flagRawValue: FlagRawValue) {
        guard case .string(let value) = flagRawValue else { return nil }
        self.init(rawValue: value)
    }

    public var flagRawValue: FlagRawValue { .string(rawValue) }
}

extension Bool: FlagValue {
    public init?(flagRawValue: FlagRawValue) {
        guard case .bool(let value) = flagRawValue else { return nil }
        self = value
    }

    public var flagRawValue: FlagRawValue { .bool(self) }
}

extension Int: FlagValue {
    public init?(flagRawValue: FlagRawValue) {
        switch flagRawValue {
        case .int(let value):
            self = value
        case .double(let value):
            guard let exact = Int(exactly: value) else { return nil }
            self = exact
        default:
            return nil
        }
    }

    public var flagRawValue: FlagRawValue { .int(self) }
}

extension Double: FlagValue {
    public init?(flagRawValue: FlagRawValue) {
        switch flagRawValue {
        case .double(let value): self = value
        case .int(let value): self = Double(value)
        default: return nil
        }
    }

    public var flagRawValue: FlagRawValue { .double(self) }
}

extension String: FlagValue {
    public init?(flagRawValue: FlagRawValue) {
        guard case .string(let value) = flagRawValue else { return nil }
        self = value
    }

    public var flagRawValue: FlagRawValue { .string(self) }
}
