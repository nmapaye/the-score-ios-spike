# Toolchain status

Status captured on 2026-08-31. This is a record of the local machine at capture time, not a statement about later builds.

## Observed installation

```text
Active developer directory: /Library/Developer/CommandLineTools
Swift driver:              1.148.6
Swift compiler:            Apple Swift 6.3.2
Compiler build:            swiftlang-6.3.2.1.108 clang-2100.1.1.101
Compiler target:           arm64-apple-macosx26.0
Selected macOS SDK:        26.5
iPhoneOS SDK:              not installed or not visible to xcrun
```

`xcrun --sdk iphoneos --show-sdk-path` reports `SDK "iphoneos" cannot be located`.

The selected macOS SDK and compiler also have different build identities despite both reporting Swift 6.3.2. A simple Foundation load reports:

```text
SDK compiler:     swiftlang-6.3.2.1.2 clang-2100.0.123.2
Active compiler:  swiftlang-6.3.2.1.108 clang-2100.1.1.101
Result: this SDK is not supported by the compiler
```

The sandboxed probe also could not write the default Clang module cache under the user cache directory. That permission error is separate from the compiler and default SDK identity mismatch. A writable cache alone does not make the default macOS 26.5 SDK compatible.

## Verified macOS-only workaround

The machine also has `/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk`. Selecting that SDK explicitly and using a writable Clang module cache allowed Foundation to load and the production package to compile:

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

This command completed successfully in the package's declared Swift 6 language mode for all 17 production files in `ScoreCore`, `ScoreAudioEngine`, and `ScoreLab`. The resulting binary passed the checks recorded in [the handoff report](HANDOFF_REPORT.md).

The same workaround does not make `swift test` available. The test build stops at `import Testing` with `no such module 'Testing'`. The installed Testing framework expects newer Swift standard-library support than the macOS 15.4 SDK workaround supplies. No Swift Testing test case ran, so the test suite is blocked rather than passing or failing.

The host also reports no Core Audio scheduled-sound-player component. `ScoreLab offline-render 0.25` exits cleanly with an explanatory error before creating `AVAudioPlayerNode`. Offline rendering and runtime transport tests remain pending for a working Xcode host.

## What this blocks

- Plain `swift build` and `swift test` cannot provide trustworthy results against the default selected macOS 26.5 SDK.
- The default SDK blocks Foundation and AVFAudio module loading. The explicit macOS 15.4 workaround compiles production package targets but cannot load Swift Testing.
- There is no iOS SDK for compiling the shell or simulator target.
- Signing, simulator runs, and physical-device deployment require full Xcode.

Swift parser checks that do not load SDK modules found no grammar errors in the current 40 Swift files. The two iOS property lists also pass `plutil -lint`. Five portable shell files pass a separate macOS-compatible type check against the built package modules, but no iOS framework file has been type checked against an iPhoneOS SDK. The limits of these checks are described in [Verification](VERIFICATION.md).

## Repair path

Install a full Xcode release that includes an iOS 17 or newer SDK and use the compiler shipped with that same Xcode bundle. Then select it and verify all tool paths:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
swift --version
xcrun --show-sdk-path
xcrun --sdk iphoneos --show-sdk-path
```

If Xcode is installed under another name, use that app's exact `Contents/Developer` path. Do not mix a standalone Swift snapshot or a different Command Line Tools release with the Xcode SDK.

After selection, run the compile-level checks in [Verification](VERIFICATION.md). Replace this status with new command output rather than assuming installation repaired the problem. Full Xcode is still required even if all macOS workaround commands pass, because the workaround provides no iPhoneOS SDK.
