# Contributing to Switchboard

Thanks for helping improve Switchboard.

## Getting started

```bash
git clone https://github.com/YOUR_USERNAME/Switchboard.git
cd Switchboard
swift test
```

You need Xcode 16 or later (Swift 6). The first build fetches `swift-syntax`, which takes a minute.

## Project layout

| Target | Purpose |
|---|---|
| `Switchboard` | Store, resolution, remote config, experiments, persistence |
| `SwitchboardMacros` | The `@FeatureFlags` and `@FlagKey` macro implementations |
| `SwitchboardUI` | The SwiftUI debug menu |
| `SwitchboardTests` | Runtime behaviour, including real macro expansions |
| `SwitchboardMacrosTests` | Macro diagnostics |

## Guidelines

- Open an issue before large changes so we can agree on the design.
- Keep the runtime library dependency-free; only the macro target depends on `swift-syntax`.
- Keep everything compiling under Swift 6 strict concurrency.
- Add tests for new behaviour, and diagnostics tests for new macro errors.
- Document public API with DocC comments and update `CHANGELOG.md` under *Unreleased*.

By contributing, you agree that your contributions are licensed under the MIT License.
