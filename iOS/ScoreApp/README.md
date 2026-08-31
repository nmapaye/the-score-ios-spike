# iPhone shell integration

This directory is source for a thin iOS 17 SwiftUI shell. It is deliberately outside the Swift package because signing, the iOS SDK, background modes, and physical-device Motion tests require Xcode.

`Score Prototype` is an engineering display name. It is not a cleared public product name.

## Create the app target

1. Install a current Xcode that includes the iOS 17 SDK or newer. Open this repository's `Package.swift` once so Xcode resolves the local package.
2. In Xcode, create an iOS App project in `iOS/ScoreApp/XcodeProject`. Use `ScorePrototype` as the product name, SwiftUI for the interface, Swift for the language, iPhone for the device family, and iOS 17.0 as the deployment target. Do not add Core Data, SwiftData, tests, or CloudKit during project creation.
3. Delete the generated app and content-view Swift files. Add `App`, `Models`, `Services`, and `Views` from this directory to the application target. Keep `Supporting/Info.plist` and `Supporting/ScoreApp.entitlements` as file references, not copied duplicates.
4. In the project editor, add the repository root as a local package dependency. Link the `ScoreCore` and `ScoreAudioEngine` products to the application target.
5. Because `SRCROOT` is `iOS/ScoreApp/XcodeProject`, set the target's custom Info.plist path to `../Supporting/Info.plist`. Set Code Signing Entitlements to `../Supporting/ScoreApp.entitlements`.
6. Under Signing & Capabilities, select the development team and a private bundle identifier. Add Background Modes and enable only `Audio, AirPlay, and Picture in Picture`. The checked-in plist already declares `audio`; the Xcode setting should agree with it.
7. Do not add HealthKit, Location, microphone, camera, push notifications, iCloud, Apple Watch, or an App Group. Motion & Fitness access uses the `NSMotionUsageDescription` string in the plist and does not require a separate entitlement.

## Resources and target membership

The engineering WAV files and manifest belong to `ScoreAudioEngine` as Swift package resources. Do not add a second copy to the app target. `EngineeringScoreFixture.load()` locates those package resources at runtime.

All Swift files under this directory belong only to the iOS app target. None should be added to `ScoreCore` or `ScoreAudioEngine`.

## First Xcode checks

- Build on a physical iPhone before changing API names in the adapters. The current command-line-only environment can parse these files but cannot type-check iOS frameworks.
- Confirm the preview is audible before the first Motion prompt appears.
- Deny Motion access and confirm the app selects Manual Steady and still completes a walk.
- Lock the phone for at least 60 minutes. Check that audio remains phase aligned and that Auto either receives fresh observations or exposes the stale-input manual fallback. A simulator cannot prove this gate.
- Exercise calls, Siri, AirPods removal and reconnection, Bluetooth route changes, Control Center play and pause, the remote stop command, media-services reset, and Low Power Mode.
- Inspect `Application Support/ScorePrototype/session-summaries.json`. Each entry must contain only `packID`, `duration`, `date`, and `adaptationMode`.

Do not treat successful compilation as proof that locked-screen cadence delivery works. Record the iPhone model, iOS version, phone placement, permission state, route, and test duration for each physical test.
