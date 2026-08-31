# Xcode integration

These steps turn the package and prewritten shell into an iPhone app after a full Xcode release with an iOS 17 or newer SDK is installed. Keep generated Xcode project files inside this repository so source paths remain stable.

`ScorePrototype` is an engineering target name. “The Score” remains a codename and is not cleared for public release.

## 1. Select the full Xcode toolchain

Open Xcode once so it can install components and present its license. In Xcode, open **Settings > Locations** and select the installed release under **Command Line Tools**. The equivalent terminal selection is:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path
swift --version
```

All four commands must resolve to the same Xcode installation. Do not proceed with `/Library/Developer/CommandLineTools` selected.

## 2. Create the iOS 17 SwiftUI app target

1. Choose **File > New > Project** in Xcode.
2. Select **iOS > App**.
3. Set Product Name to `ScorePrototype`, Interface to **SwiftUI**, Language to **Swift**, and device family to **iPhone**. Do not add SwiftData, Core Data, CloudKit, or template test targets.
4. Choose an organization identifier you control. The resulting bundle identifier must be unique for device signing.
5. Save the project in `iOS/ScoreApp/XcodeProject` under the repository root. Do not create another Git repository.
6. Select the app target, open **General**, and set the minimum deployment target to iOS 17.0.

Remove the generated `ContentView.swift` and generated `@main` app file from the app target when equivalent files from the repository shell are added. The target must have exactly one `@main` type.

## 3. Add the repository as a local package

1. Choose **File > Add Package Dependencies**.
2. Select **Add Local** and choose the repository root, the directory that contains `Package.swift`.
3. Add the `ScoreCore` and `ScoreAudioEngine` products to the `ScorePrototype` app target. Do not link the `ScoreLab` executable to the app.
4. Confirm both libraries appear under **Target > General > Frameworks, Libraries, and Embedded Content**. Swift package libraries should use their default embedding setting.

If Xcode offers to treat the root package as a separate workspace item, accept it. Package sources should continue to live under `Sources`; do not copy them into the app target.

## 4. Add the iOS shell

1. Delete the generated app entry and `ContentView.swift` from the target and disk.
2. Drag `iOS/ScoreApp/App`, `iOS/ScoreApp/Models`, `iOS/ScoreApp/Services`, and `iOS/ScoreApp/Views` into the project navigator under the app group.
3. In the add-files sheet, select **Create groups**, leave **Copy items if needed** off, and select only the `ScorePrototype` app target.
4. Add `iOS/ScoreApp/Supporting/Info.plist` and `iOS/ScoreApp/Supporting/ScoreApp.entitlements` as file references. Do not copy them or add either file to **Copy Bundle Resources**.
5. In **Build Settings**, set **Generate Info.plist File** to `No`, **Info.plist File** to `../Supporting/Info.plist`, and **Code Signing Entitlements** to `../Supporting/ScoreApp.entitlements` for Debug and Release. These paths are relative to the project directory at `iOS/ScoreApp/XcodeProject`.
6. In the File inspector, confirm every shell Swift file has `ScorePrototype` target membership and no package target membership.
7. Confirm the shell imports `ScoreCore` and `ScoreAudioEngine` without adding `CoreMotion`, `AVFAudio`, `MediaPlayer`, or SwiftUI imports to `ScoreCore`.

## 5. Add the engineering score resources

`Sources/ScoreAudioEngine/Resources/EngineeringScore` is declared as a `ScoreAudioEngine` package resource and copied into `Bundle.module` by Swift Package Manager. Do not add a second copy to the app target. `EngineeringScoreFixture.load()` resolves the manifest and audio through the package bundle.

Before running, verify that the pack manifest can resolve its intro, loop sections, four stems, and outro using case-sensitive names. The fixture is disposable engineering material. It is not cleared or mixed for release.

## 6. Configure signing and capabilities

1. Select the app target and open **Signing & Capabilities**.
2. Enable **Automatically manage signing** and select a development team.
3. Resolve the unique bundle identifier and wait for Xcode to create the development profile.
4. Add the **Background Modes** capability and select **Audio, AirPlay, and Picture in Picture**. This writes `audio` under `UIBackgroundModes`.
5. Do not add Location, HealthKit, iCloud, Push Notifications, or Background Processing capabilities.

The checked-in Info.plist supplies this `NSMotionUsageDescription`:

> Motion cadence changes the arrangement during a walk. The app does not save raw motion data.

The shell should present its audible preview before triggering this system prompt. Apple can change capability labels between Xcode releases, so confirm the generated Info entry is `Privacy - Motion Usage Description` and the background mode contains `audio`.

## 7. Compile in increasing order

Use the full Xcode toolchain from the repository root:

```sh
swift package resolve
swift build
swift test
swift run ScoreLab self-test
swift run ScoreLab validate-pack

for trace_path in Fixtures/MotionTraces/*.json; do
  swift run ScoreLab simulate "$trace_path"
done
```

Then select an iOS simulator and build the app target. The simulator can exercise views, manual adaptation, app lifecycle, local storage, and injected traces. It cannot prove pedometer delivery, real headphone routing, locked-screen behavior, or signing on an iPhone.

## 8. Run on an iPhone

1. Connect a physical iPhone running iOS 17 or newer, trust the Mac, and enable Developer Mode if Xcode requests it.
2. Select the iPhone as the run destination and confirm the development team under Signing.
3. Build and run. Accept Motion permission only after hearing the preview.
4. Confirm audio remains in headphones, the Lock Screen shows transport information, and Play/Pause/Stop controls reach the session controller.
5. Run the complete [device test matrix](DEVICE_TEST_MATRIX.md), including a 60 to 90 minute locked-screen walk and interruption recovery.

Installing and launching the app proves only that this build runs on that device. Do not claim locked-screen adaptive behavior until all required matrix rows pass with captured evidence.
