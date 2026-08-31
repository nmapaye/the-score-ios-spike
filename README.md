# The Score iOS Spike

This repository is an engineering spike for a walking companion that adapts one coherent, composer-authored score to movement. “The Score” is a codename, not a cleared public name. The spike tests procedural arrangement, motion interpretation, background audio integration, and recovery behavior. It is not a production app, fitness tracker, streaming service, or generative-music system.

The repository can be edited without Xcode. `ScoreCore`, `ScoreAudioEngine`, and the `ScoreLab` command-line target are organized as a Swift package. The thin SwiftUI and Core Motion integration lives under `iOS/` and is added to an iOS app target after Xcode is installed.

## Repository map

- `Sources/ScoreCore` contains portable contracts, frame-grid math, adaptation rules, and session state.
- `Sources/ScoreAudioEngine` contains the `AVAudioEngine` transport and pack loading support.
- `Sources/ScoreLab` validates packs and replays deterministic motion traces.
- `Tests` contains package tests for the portable logic and audio transport.
- `iOS` contains source and configuration templates for the later iPhone target.
- `Sources/ScoreAudioEngine/Resources/EngineeringScore` contains the engineering score fixture and manifest.
- `Docs` contains architecture, Xcode integration, toolchain status, and verification guidance.

The included audio is disposable engineering material. It exists to expose scheduling, phase, transition, and loading faults. It is not launch music and must not inform a claim about the finished musical experience.

## Current verification boundary

All 17 production Swift files compile in Swift 6 mode against the installed macOS 15.4 SDK when that SDK and a writable module cache are selected explicitly. The compiled `ScoreLab` self-test passes 35 checks. The engineering pack verifies six audio assets and their asset-set integrity hash. Five deterministic motion traces pass 31 explicit state snapshots and return an error on any mismatch.

The 52 authored Swift Testing cases did not run. The workaround SDK cannot load the installed Swift Testing module. Five portable iOS shell files pass a macOS-compatible type check against the built package modules, but no file has been checked against an iPhoneOS SDK. This host also lacks the Core Audio scheduled-sound-player component, so offline audio execution and runtime transport checks remain pending. Simulator work, signing, and iPhone runs are also pending. See [the handoff report](Docs/HANDOFF_REPORT.md) and [toolchain status](Docs/TOOLCHAIN_STATUS.md) for the exact boundaries.

No claim is made yet that Core Motion updates remain reliable during a locked-screen walk. That behavior must pass the physical-device matrix in [Device testing](Docs/DEVICE_TEST_MATRIX.md).

## Working without Xcode

Edit the package and shell in any text editor. Parser checks and the explicit macOS 15.4 SDK workaround are documented in [Verification](Docs/VERIFICATION.md). Do not treat parser success, or a successful macOS package build, as iPhone runtime proof.

After installing a matching full Xcode release, select its developer directory, compile and test the package, then create the iOS 17 app target using [Xcode integration](Docs/XCODE_INTEGRATION.md).

## Product boundaries

The spike has one intentional-walk session. Motion can select Easy, Steady, Brisk, or a short Surge arrangement. Manual Easy, Steady, and Brisk controls are the fallback when Motion permission is denied or observations become stale.

This milestone deliberately excludes accounts, backends, GPS, routes, HealthKit, Apple Watch, StoreKit, subscriptions, third-party dependencies, production scores, runtime AI audio, user-song integration, and fitness claims.

## Documentation

- [Architecture and scope](Docs/ARCHITECTURE.md)
- [Xcode integration](Docs/XCODE_INTEGRATION.md)
- [Toolchain status](Docs/TOOLCHAIN_STATUS.md)
- [Verification tiers](Docs/VERIFICATION.md)
- [Physical-device test matrix](Docs/DEVICE_TEST_MATRIX.md)
- [Current handoff report](Docs/HANDOFF_REPORT.md)
