# iOS: a scaffolded target, and what it still has to be given

`mobile/ios/` is a real Xcode project now — `flutter create . --platforms=ios` was
run here — but **nothing has been shipped from it yet**. `build_apk.ps1` and the
`build_and_publish` job in `.github/workflows/proctorguard_pipeline.yml` still
publish Android, and the iOS half is *compiled* (unsigned, on a macOS runner) by
that same file's `build_ios` job, so an iOS-only break is caught in a pull request
rather than the next time a Mac opens Xcode. It also carries the `testflight` job
below, which signs and uploads — inert until the repository has the secrets it
lists.

## What the scaffold already carries

None of these are the value `flutter create` writes; each is a decision, and
`test/android_manifest_contract_test.dart` pins the ones a file can answer for.

| Piece | Where | Why not the template's value |
| --- | --- | --- |
| `CFBundleDisplayName` and `CFBundleName` = `ProctorGuard` | `Runner/Info.plist` | The same name as `android:label`, `MaterialApp.title` and the web metadata: the app's own copy sends the student to Settings by that name (`audio_monitor.dart`), so a second spelling is a support ticket. |
| `CFBundleIdentifier` = `com.stackbuildco.proctorguard` | `Runner.xcodeproj` (`PRODUCT_BUNDLE_IDENTIFIER`), read by the plist as `$(PRODUCT_BUNDLE_IDENTIFIER)` | The iOS half of the package rename: the id is the app's data directory and its granted permissions, and `com.example.*` is refused by the store. |
| `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` | `Runner/Info.plist` | **Without them iOS terminates the app** on the first `AVCaptureDevice.requestAccess`, with no exception for `ExamTakingPage` to catch and nothing the student can do about it. The camera string also discloses the still frame that goes to `proctor-snapshots` with a violation; the microphone string says the level is measured and the audio never recorded. |
| `UIStatusBarHidden` + `UIViewControllerBasedStatusBarAppearance` = false | `Runner/Info.plist` | The status bar Android's kiosk/immersive build hides app-wide. Without the second key the first does nothing. |
| `ITSAppUsesNonExemptEncryption` = false | `Runner/Info.plist` | Only TLS to Supabase. Left out, App Store Connect asks the export-compliance question once per build and a TestFlight upload sits in "Missing Compliance". |
| `platform :ios, '15.5'` | `ios/Podfile` (added — `flutter create` does not write one) | `google_mlkit_face_detection` and the `google_mlkit_commons` it pulls in declare `s.platform = :ios, '15.5'`. At Flutter's template default of 13.0 `pod install` does not warn — it refuses to resolve. The earlier version of this checklist said "13.0 (or newer)"; 15.5 is the floor the pods actually set. |
| `IPHONEOS_DEPLOYMENT_TARGET = 15.5` | `Runner.xcodeproj`, all three configurations | CocoaPods resolves from the Podfile while Xcode links from the project setting; the two disagreeing is how a pod resolves cleanly and then fails to link. The contract test asserts they agree. |

`UIRequiresFullScreen` is deliberately **absent**. It was on the old checklist, but
iPadOS 26 ignores it and the real guarantee on an iPad is an MDM profile (below). A
key that no longer does anything is worse than a comment saying so.

Verified without a Mac: `flutter build bundle --target-platform=ios` compiles the
Dart for the iOS target, so every conditional import (`web_*` vs stub, the `dart:io`
guards) resolves the way an iOS build will; `flutter analyze` and `flutter test` run
on any host. Anything native — pod resolution, the Swift compile, the storyboards —
needs macOS, which is the workflow's job: it runs `pod install --repo-update` and
then `flutter build ios --release --no-codesign`.

## What is still missing, in the order it should be done

1. **The lifecycle violations.** `MainActivity.onResume()` re-pins the kiosk and
   reports `app_minimized`; iOS has neither yet. In this template the *scene* owns
   the app's foreground/background transitions, so the hook is
   `SceneDelegate.sceneWillResignActive` (with `sceneDidBecomeActive` for the re-pin
   attempt), reporting through the same `ProctoringNotifier.reportAppMinimized()`
   entry point Android uses. The pin half cannot work — see the table below — but
   *reporting* that the student left can.
2. **The signing material.** The `testflight` job in
   `.github/workflows/proctorguard_pipeline.yml` now builds a signed `.ipa` and
   uploads it to TestFlight, but it needs an Apple Developer team id, a
   distribution certificate, an App Store provisioning profile (recommended) and
   an App Store Connect API key as repository secrets — none of which can live in
   this repository. What is still missing on the Apple side is the App Store
   Connect app record for `com.stackbuildco.proctorguard`; the secrets and their
   sources are in [TestFlight from CI](#testflight-from-ci) below.
3. **Artwork.** `Assets.xcassets/AppIcon.appiconset` and the launch image are still
   the Flutter template logo — the same gap the web icons once had.
4. **The keychain exclusion.** `allowBackup="false"` is Android's answer to a
   session outliving the exam; the iOS analogue is `isExcludedFromBackup` on the
   keychain item, so a refresh token does not travel to a new device through iCloud
   Keychain.
5. **The deployment rows.** A school choosing an iPad has to be told that an MDM is
   what makes the pin real; without one an iOS exam is escapable by design.

## TestFlight from CI

`testflight` in `.github/workflows/proctorguard_pipeline.yml` is the shipping half
of the iOS pipeline. It runs on a manual **Run workflow**, on every push to `main`,
and on a `vX.Y.Z` tag — never on a pull request, so signing material stays out of
reach of a fork. With no secrets configured a push stays green and says so in a
notice; a manual dispatch fails, because somebody asked for a build.

What it does, in order: `pod install` (same resolution the compile gate uses),
import the certificate into a **temporary keychain**, install the provisioning
profile, set `DEVELOPMENT_TEAM` (and manual signing, when a profile name is given)
in the generated workspace, write an `ExportOptions.plist` for `app-store-connect`,
`flutter build ipa --release`, and `xcrun altool --upload-app` with the App Store
Connect API key. The keychain, the profile and the `.p8` are deleted in an
`always()` step.

| Secret | Where it comes from |
| --- | --- |
| `APPLE_TEAM_ID` | [developer.apple.com/account](https://developer.apple.com/account) → Membership → *Team ID* (10 characters). |
| `IOS_DISTRIBUTION_CERTIFICATE_BASE64` | Keychain Access → *My Certificates* → export the **Apple Distribution** certificate as `.p12`, then `base64 -i distribution.p12 \| pbcopy`. |
| `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | The password chosen in that export dialog. |
| `IOS_PROVISIONING_PROFILE_BASE64` *(recommended)* | Apple Developer → Profiles → an **App Store** profile for `com.stackbuildco.proctorguard`; `base64 -i profile.mobileprovision \| pbcopy`. |
| `IOS_PROVISIONING_PROFILE_NAME` *(recommended)* | That profile's *Name* exactly as Apple lists it — the value Xcode shows under *Provisioning Profile*. |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect → Users and Access → Integrations → **App Store Connect API** → create a key with **App Manager** access. |
| `APP_STORE_CONNECT_ISSUER_ID` | Shown above the key list on that same page. |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The `AuthKey_XXXXXXXXXX.p8` file's contents, pasted as-is (it is only downloadable once). |
| `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | The same values `build_and_publish` uses. `SUPABASE_ANON_KEY` is still accepted as the older name. |
| `SENTRY_DSN` *(optional)* | Crash reporting is off unless this is set (see `mobile/README.md`). |

Two notes that save a failed run:

* **The profile is what makes signing deterministic.** With
  `IOS_PROVISIONING_PROFILE_NAME` set, the workflow signs manually against a
  profile that is already on the runner; without it, Xcode's automatic signing has
  to ask Apple for a profile, which a headless runner cannot authenticate for.
* **The build number is `github.run_number`, not the pubspec version.**
  TestFlight refuses a second upload of the same version+build, and `pubspec.yaml`
  is a hand-edited `1.0.0`; the marketing version stays there, the build number
  comes from CI. Bump `pubspec.yaml`'s version (e.g. `1.0.1`) for a new TestFlight
  *version*.

Before the first run there is one manual, one-off step outside this repository:
create the app record in App Store Connect with bundle id
`com.stackbuildco.proctorguard`. `ios/Runner.xcodeproj` is left on automatic
signing with no `DEVELOPMENT_TEAM`, so `flutter run` on a developer's Mac still
uses their own team; the workflow sets the team in its checked-out copy only.


Two of the Android guarantees in this repository **cannot be reproduced on iOS**,
and the decision to ship iOS has to account for them:

| Guarantee (Android) | iOS equivalent | Consequence |
| --- | --- | --- |
| `Activity.startLockTask()` / device-owner lock task | Guided Access, or Apple's *Single App Mode* via a supervised device + MDM | Only an MDM-supervised iPad can actually lock a student in. Without it, an iOS exam is escapable by design. |
| `FLAG_SECURE` (`MainActivity.kt`) | Nothing public | A student can screenshot and record an iOS exam. There is no supported API to prevent it. |

`KioskService` already degrades instead of pretending: off Android `startLock`
returns `KioskResult.unsupported`, and the exam screen shows no pin badge rather
than claiming one. `AudioMonitor` takes amplitude through `record` on iOS exactly as
it does on Android, and the Supabase/data layer is platform-neutral.

## Verified from this repository

- `flutter analyze --no-pub` and `flutter test` pass on a Windows host with the
  project scaffolded, and `flutter build bundle --target-platform=ios` compiles the
  Dart for the target — so no conditional import is missing an iOS branch.
- `test/android_manifest_contract_test.dart` reads the files above: the name on the
  icon, the renamed bundle id, both privacy strings, the status-bar pair, and
  `platform :ios` agreeing with `IPHONEOS_DEPLOYMENT_TARGET`.
- `git ls-files mobile/ios` now returns the project (`Runner.xcodeproj`,
  `Runner/Info.plist`, the storyboards, `AppDelegate.swift`, `SceneDelegate.swift`,
  this file, and the `Podfile`), so an iOS question is answerable from a checkout
  instead of from somebody's Mac.
