# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-10-02

### Added
- `@FeatureFlags` macro that generates a flag registry, a resolving initializer and `FeatureFlagContainer` conformance, with compile-time diagnostics.
- `@FlagKey` to map a property to a different remote key.
- `@Observable`, `@MainActor` `FlagStore` with override → experiment → remote → default resolution.
- Remote config over HTTP or any custom `RemoteConfigSource`, with disk caching and `.immediately` / `.nextLaunch` activation.
- Weighted A/B/n experiments with deterministic FNV-1a bucketing and an `onAssignment` callback for analytics.
- Persisted local overrides that can be disabled in release builds.
- `SwitchboardUI` debug menu with search, per-type editors, origin badges and type-mismatch warnings.
