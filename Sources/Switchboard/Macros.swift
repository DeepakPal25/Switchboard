/// Turns a struct of stored properties into a type-safe set of feature flags.
///
/// ```swift
/// @FeatureFlags
/// struct AppFlags {
///     /// Shows the redesigned onboarding flow.
///     var newOnboarding: Bool = false
///
///     @FlagKey("max_upload_count")
///     var maxUploads: Int = 5
///
///     var checkoutStyle: CheckoutStyle = .classic
/// }
/// ```
///
/// The macro generates:
/// - `static let definitions`, the registry used by the debug menu, with
///   each flag's key, default value, doc comment and allowed values;
/// - `init(resolver:)`, which reads every flag from remote config, A/B
///   assignments and overrides, falling back to the declared default;
/// - `init()`, which produces all defaults;
/// - conformance to ``FeatureFlagContainer``.
///
/// Every flag must be a `var` with an explicit type and a default value.
/// Mistakes are reported as compiler errors on the offending property.
@attached(member, names: named(definitions), named(init))
@attached(extension, conformances: FeatureFlagContainer)
public macro FeatureFlags() = #externalMacro(module: "SwitchboardMacros", type: "FeatureFlagsMacro")

/// Overrides the key a flag uses in remote config. By default the key is the property name.
@attached(peer)
public macro FlagKey(_ key: String) = #externalMacro(module: "SwitchboardMacros", type: "FlagKeyMacro")
