# iOS: not a target yet, and what has to be true when it becomes one

**There is no iOS project in this repository.** `mobile/ios/` does not exist, and
`mobile/pubspec.yaml` ships Android + web only (`flutter create --platforms=ios .`
has never been run here). So there is no `Runner/Info.plist` to harden, and this
directory holds the checklist instead. Nothing else in the app blocks an iOS target:
`KioskService` degrades to `KioskResult.unsupported` off Android, `AudioMonitor` and
the web guards have their own platform seams, and the Supabase/data layer is
platform-neutral.

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

- `mobile/pubspec.yaml` declares no iOS-specific dependency, and no `ios/` directory is
  tracked (`git ls-files mobile/ios` is empty).
- The Supabase session policy (`allowBackup="false"` on Android) has an iOS analogue to
  configure when the target lands: `isExcludedFromBackup` on the keychain item, so the
  refresh token does not travel to a new device through iCloud Keychain.
