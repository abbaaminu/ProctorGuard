# iOS: not a target yet, and what has to be true when it becomes one

**There is no iOS project in this repository.** `mobile/ios/` exists, but it holds
only what a Flutter build writes: `Flutter/Generated.xcconfig`,
`Flutter/flutter_export_environment.sh`, `Flutter/ephemeral/*` and
`Runner/GeneratedPluginRegistrant.{h,m}`. There is no `Runner.xcodeproj`, no
`Runner/Info.plist` and no `AppDelegate.swift`, and `mobile/pubspec.yaml` ships
Android + web only (`flutter create --platforms=ios .` has never been run here).
This directory holds the checklist instead. Nothing else in the app blocks an iOS
target: `KioskService` degrades to `KioskResult.unsupported` off Android,
`AudioMonitor` and the web guards have their own platform seams, and the
Supabase/data layer is platform-neutral.

Two of the Android guarantees in this repository **cannot be reproduced on iOS**, and
the decision to ship iOS has to account for them:

| Guarantee (Android) | iOS equivalent | Consequence |
| --- | --- | --- |
| `Activity.startLockTask()` / device-owner lock task | Guided Access, or Apple's *Single App Mode* via a supervised device + MDM | Only an MDM-supervised iPad can actually lock a student in. Without it, an iOS exam is escapable by design. |
| `FLAG_SECURE` (`MainActivity.kt`) | Nothing public | A student can screenshot and record an iOS exam. There is no supported API to prevent it. |

## When the target is created

1. Run `flutter create --platforms=ios .` from `mobile/`, then port every entry below
   into `ios/Runner/Info.plist`.

```xml
<!-- The app's identity metadata. `CFBundleDisplayName` is the name under the icon
     and `CFBundleName` the short one the system uses internally; both are the
     name the student is told to look for when the app sends them to Settings
     ("Allow it for ProctorGuard in ...", `lib/core/services/audio_monitor.dart`),
     so they are the same string as `android:label`, `MaterialApp.title` and the
     web metadata (`AndroidManifest.xml`, `lib/main.dart`, `web/index.html`,
     `web/manifest.json`) - `test/android_manifest_contract_test.dart` pins all of
     them together.
     `CFBundleIdentifier` is the iOS half of the package rename: it has to be the
     same id as the Android `applicationId` in `android/app/build.gradle.kts`,
     because that id is the app's data directory, its granted permissions and its
     upgrade path. `flutter create`'s placeholder (`com.example.exam_proctor`) is
     refused by the store and collides with any other `flutter create` build. -->
<key>CFBundleDisplayName</key>
<string>ProctorGuard</string>
<key>CFBundleName</key>
<string>ProctorGuard</string>
<key>CFBundleIdentifier</key>
<string>com.stackbuildco.proctorguard</string>

<!-- The camera and microphone are the proctoring session itself; without these
     strings iOS terminates the app the moment it asks for access. -->
<key>NSCameraUsageDescription</key>
<string>ProctorGuard uses the front camera for the duration of an exam to check that
the student is present and alone.</string>
<key>NSMicrophoneUsageDescription</key>
<string>ProctorGuard listens to the room's loudness during an exam to detect
sustained noise. No audio is recorded or stored.</string>

<!-- The exam is a lock-down session: it needs the screen to stay awake and the
     student to stay in the app. -->
<key>UIRequiresFullScreen</key><true/>
<key>UIViewControllerBasedStatusBarAppearance</key><false/>
<key>UIStatusBarHidden</key><true/>

<!-- No photo library, no location, no contacts: an exam client that can read the
     photo library can exfiltrate a photographed question. Absent keys are the
     guarantee. -->
<key>ITSAppUsesNonExemptEncryption</key><false/>
```

2. `ios/Runner/AppDelegate.swift`: re-request the pin on `applicationDidBecomeActive`
   the way `MainActivity.onResume()` re-pins lock task mode, and add
   `applicationWillResignActive` handling that reports an `app_minimized` violation
   through the same `ProctoringNotifier.reportAppMinimized()` entry point Android uses.
3. `platform :ios, '13.0'` (or newer) in `ios/Podfile`, matching
   `google_mlkit_face_detection` and `record`.
4. Add the two iOS rows above to the deployment checklist so a school choosing an iPad
   understands that an MDM is what makes the pin real.

## Verified from this repository

- `mobile/pubspec.yaml` declares no iOS-specific dependency, and
  `git ls-files mobile/ios` returns only Flutter-generated files
  (`Flutter/Generated.xcconfig`, `Flutter/flutter_export_environment.sh`,
  `Flutter/ephemeral/*`, `Runner/GeneratedPluginRegistrant.{h,m}`) plus this README:
  no Xcode project, so no `Info.plist` holding the identity keys above yet - and
  nothing in the repository silently relying on the `flutter create` placeholder
  bundle id either (the Android half was renamed to `com.stackbuildco.proctorguard`
  in `android/app/build.gradle.kts`, and it is the id `CFBundleIdentifier` has to
  match on the day the target is created).
- The Supabase session policy (`allowBackup="false"` on Android) has an iOS analogue to
  configure when the target lands: `isExcludedFromBackup` on the keychain item, so the
  refresh token does not travel to a new device through iCloud Keychain.
