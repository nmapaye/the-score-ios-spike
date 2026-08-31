# Verification tiers

Verification is reported in three tiers so parser success is never mistaken for a working app.

## Tier 1: source and fixture checks without Xcode

These checks ran successfully on the current tree because they avoid SDK module loading:

```sh
find Sources Tests iOS -name '*.swift' -print0 | xargs -0 -n 1 swiftc -frontend -parse
plutil -lint iOS/ScoreApp/Supporting/Info.plist \
  iOS/ScoreApp/Supporting/ScoreApp.entitlements
rg -n '^import ' Sources/ScoreCore
```

Result: all 40 Swift files parsed, both property lists linted, and every `ScoreCore` source imports Foundation only.

Also validate every JSON manifest with a JSON parser, confirm each referenced audio path exists with exact case, and search `Sources/ScoreCore` for imports other than Foundation or the Swift standard library.

Tier 1 can establish:

- Swift grammar parses.
- JSON is well formed.
- Fixture references point to present files.
- `ScoreCore` has no direct dependency on Core Motion, AVFAudio, MediaPlayer, SwiftUI, HealthKit, or location frameworks.

Tier 1 cannot establish type correctness, module availability, actor or sendability correctness, linking, test success, audio timing, resource bundling, app lifecycle behavior, or device behavior.

Record each file that was not parsed or validated. A missing check is pending, not passing.

## Tier 2: package compile and deterministic tests

The installed macOS 15.4 SDK was selected explicitly for a package-only build before full Xcode is installed:

```sh
mkdir -p /private/tmp/the-score-clang-cache
env SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
  CLANG_MODULE_CACHE_PATH=/private/tmp/the-score-clang-cache \
  swift build --disable-sandbox \
  --scratch-path .build/macos15 \
  --cache-path .build/cache \
  --config-path .build/config \
  --security-path .build/security
```

Result: all 17 production source files compiled successfully in the package's declared Swift 6 language mode. This route compiles macOS package targets only.

The compiled engineering checks ran with these commands:

```sh
.build/macos15/debug/ScoreLab self-test
.build/macos15/debug/ScoreLab validate-pack

for trace_path in Fixtures/MotionTraces/*.json; do
  .build/macos15/debug/ScoreLab simulate "$trace_path"
done
```

Result: `self-test` passed 35 compiled checks. `validate-pack` accepted `engineering-score-v1` and inspected six assets with one exact sample rate, channel layout, PCM format, and interleaving layout. Frame counts and per-file SHA-256 values matched, and the canonical asset-set hash matched the pack integrity hash. The manual-fallback, stale, steady-walk, stop-start, and Surge traces passed 31 explicit snapshots. Every snapshot compares transport frame, section, current and requested energy, adaptation mode, stale state, and queued transition. A mismatch exits with an error instead of printing a trace that merely looks plausible.

The normal test command was also attempted with the same SDK, cache, and SwiftPM path flags:

```sh
env SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
  CLANG_MODULE_CACHE_PATH=/private/tmp/the-score-clang-cache \
  swift test --disable-sandbox \
  --scratch-path .build/macos15 \
  --cache-path .build/cache \
  --config-path .build/config \
  --security-path .build/security
```

Result: the test target stopped at `import Testing` with `no such module 'Testing'`. No test case ran. The eight files under `Tests` contain 52 authored Swift Testing cases. They are syntax checked but not compiled or unit tested on this host.

The short render probe ran with:

```sh
.build/macos15/debug/ScoreLab offline-render 0.25
```

Result: the command exited before engine creation with `This host does not expose the Core Audio player component required by AVAudioPlayerNode.` This is a clean capability failure, not an audio-render pass. The compiled harness now schedules bar-level energy events and phrase-level section events and reports transition counts, boundary checks and failures, phase checks and failures, sample continuity, and frame completion. Those runtime report paths and the one-hour stress render remain unexecuted on this host.

On a host that exposes the required Core Audio component and Swift Testing module, enable only the named stress case with:

```sh
SCORE_RUN_AUDIO_STRESS=1 swift test --filter oneHourOfflineStress
```

The selected case is named `One-hour offline phase stress harness`. It renders 3,600 seconds and requires completed frames, finite samples, matching stem frames, at least one energy and section event, zero boundary failures, and zero phase failures.

After the compiler and SDK come from one working full Xcode installation, rerun without the workaround:

```sh
swift package resolve
swift build
swift test
swift run ScoreLab self-test
swift run ScoreLab validate-pack
```

The compiled self-test covers:

- Contract encoding, all energy cases, and the four allowed session-summary fields.
- Beat, bar, phrase, and one-hour rational frame calculations.
- A valid manifest, missing-resource and frame-mismatch rejection, malformed integrity-hash rejection, and verified asset-set integrity.
- Authorized phrase transitions, unknown-section rejection, composer energy-to-section mapping, and accepted runtime boundary reconciliation.
- Five-second stabilization, twelve-second dwell, queued-energy application, and the ten-second freshness boundary.
- Denied Motion selecting Manual Steady, delayed Surge activation, and the twelve-second Surge cap.
- Paused-time exclusion, outro completion, session completion, and reset.
- Inspection of six fixture assets, their sample rates, and their SHA-256 values.

The five simulations separately exercise steady walking, stop and start, Surge, stale input, and manual fallback through 31 required snapshots. The Swift Testing sources contain broader cases, including accepted-boundary and failed-reprepare behavior, but those cases have not run on this host.

After Xcode repair, the Swift Testing suite must compile and run. Use macOS offline rendering for a one-hour transport stress case, inspect transition windows for clicks, and verify each audible stem has the expected phase relative to the canonical clock.

A package test pass does not verify the iOS shell or locked-screen sensor delivery.

## Tier 3: simulator and physical iPhone

A macOS-compatible type check passes for `AppModels.swift`, `AppServiceProtocols.swift`, `ScoreEnginePlaybackController.swift`, `AppPreferences.swift`, and `SessionSummaryStore.swift` against the compiled package modules. This catches portable contract and controller type errors only. It does not load Core Motion, iOS `AVAudioSession`, MediaPlayer, SwiftUI, or an iPhoneOS SDK.

The recorded command is:

```sh
env SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
  CLANG_MODULE_CACHE_PATH=/private/tmp/the-score-clang-cache \
  swiftc -swift-version 6 -typecheck \
  -I .build/macos15/arm64-apple-macosx/debug/Modules \
  iOS/ScoreApp/Models/AppModels.swift \
  iOS/ScoreApp/Services/AppServiceProtocols.swift \
  iOS/ScoreApp/Services/ScoreEnginePlaybackController.swift \
  iOS/ScoreApp/Services/AppPreferences.swift \
  iOS/ScoreApp/Services/SessionSummaryStore.swift
```

After creating the app target, build the complete iOS shell in Xcode. Use the simulator for view state, manual mode, injected observations, local summaries, and basic lifecycle events. Run motion, audio-route, background, and interruption acceptance tests on physical iPhones using [the device matrix](DEVICE_TEST_MATRIX.md).

The locked-screen Auto gate requires a 60 to 90 minute physical walk with current motion observations, stable background playback, fallback behavior when input becomes stale, and no clicks or phase break. Test phone-in-hand, pocket, and bag placements across the recruited test set.

## Reporting language

Use these labels in commits and handoffs:

- **Syntax checked** means Tier 1 ran on every listed source file.
- **Compiled** means the named target built with the recorded Xcode and SDK versions.
- **Unit tested** means the named test command passed with a recorded test count.
- **Simulator tested** means the named scenario ran on a recorded simulator and OS version.
- **Device tested** means the named matrix row passed on a recorded physical model and iOS version.
- **Pending** means the check did not run or its evidence is incomplete.
- **Failed** means the check ran and did not meet its stated acceptance condition.

Do not use “verified,” “working,” or “production ready” without naming the tier and evidence. Do not make a locked-screen reliability claim while its required matrix rows are pending or failed.
