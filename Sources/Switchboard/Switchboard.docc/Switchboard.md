# ``Switchboard``

Type-safe feature flags with remote config, local overrides, A/B tests and a debug menu.

## Overview

Declare flags as a struct and apply ``FeatureFlags()``:

```swift
@FeatureFlags
struct AppFlags {
    /// Shows the redesigned onboarding flow.
    var newOnboarding: Bool = false
    var maxUploads: Int = 5
}
```

Create a ``FlagStore`` and read `store.flags.newOnboarding`. Values resolve in this order: local override, experiment variant, remote value, then the default declared in code.

## Topics

### Declaring flags

- ``FeatureFlags()``
- ``FlagKey(_:)``
- ``FlagValue``
- ``FeatureFlagContainer``
- ``FlagDefinition``

### Reading flags

- ``FlagStore``
- ``FlagOrigin``
- ``FlagResolver``
- ``FlagRawValue``

### Remote config and experiments

- ``RemoteConfig``
- ``Experiment``
- ``RemoteConfigSource``
- ``HTTPRemoteConfigSource``
- ``ClosureRemoteConfigSource``

### Persistence

- ``ConfigCache``
- ``FileConfigCache``
- ``InMemoryConfigCache``
- ``OverrideStorage``
- ``UserDefaultsOverrideStorage``
- ``InMemoryOverrideStorage``
