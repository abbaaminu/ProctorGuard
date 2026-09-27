package com.example.exam_proctor

import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.display.DisplayManager
import android.os.Build
import android.view.Display
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native half of the exam kiosk bridge (Dart: lib/core/services/kiosk_service.dart,
 * channel `lock_task_channel`).
 *
 *   startLock           -> startLockTask() + immersive mode + keep screen on
 *   stopLock            -> stopLockTask() + restore status/navigation bars
 *   isLockTaskActive    -> ActivityManager.lockTaskModeState != NONE
 *   isLockTaskPermitted -> DevicePolicyManager.isLockTaskPermitted(packageName)
 *
 * Android exposes no public "lock task ended" callback on Activity
 * (DeviceAdminReceiver has one, but that requires device-owner status), so the
 * Dart side polls `isLockTaskActive` while an exam runs: two consecutive
 * inactive reports, after pinning was confirmed, mean the student escaped
 * screen pinning — which is logged as an `app_minimized` violation. With Device
 * Owner status (Android Enterprise) the app is whitelisted instead, so there is
 * nothing to escape.
 *
 * It is also the native half of the device-integrity bridge (Dart:
 * lib/core/services/hardware_integrity_service.dart, channel
 * `hardware_integrity_channel`):
 *
 *   getIntegrityReport  -> DisplayManager.displays (secondary display) plus the
 *                          camera list (virtual/external camera)
 *
 * Both are permission-free reads. The camera half is deliberately narrow: an
 * external (USB) camera cannot be opened by a proctoring app as the *exam*
 * camera without also being visible here, and an emulator's camera is virtual by
 * construction — a second physical camera the device shipped with (wide-angle,
 * depth) is not a finding, and neither is a display that is switched off, since
 * nothing can be read from one.
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INTEGRITY_CHANNEL)
            .setMethodCallHandler { call, result -> handleIntegrity(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) = when (call.method) {
        // Long names kept so an older Dart build can still pin the app.
        "startLock", "startLockTask" -> result.success(startLock())
        "stopLock", "stopLockTask" -> {
            stopLock()
            result.success(null)
        }
        "isLockTaskActive" -> result.success(isLockTaskActive())
        "isLockTaskPermitted" -> result.success(isLockTaskPermitted())
        else -> result.notImplemented()
    }

    private fun startLock(): HashMap<String, Any?> {
        val reply = HashMap<String, Any?>()
        val strict = isLockTaskPermitted()
        reply["strict"] = strict
        // getLockTaskModeState() is API 23+, so Dart can only poll for escapes
        // from there on (Flutter's default minSdk is 24 anyway).
        reply["canDetectEscape"] = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
        try {
            applyImmersiveMode(true)
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            startLockTask()
            reply["granted"] = true
            reply["message"] = if (strict) {
                "Locked by device policy: leaving the exam needs a supervisor."
            } else {
                "Screen pinned (best effort): escaping needs a long-press of back + recents."
            }
        } catch (error: Exception) {
            // Not in the foreground, or the platform refused to pin.
            reply["granted"] = false
            reply["message"] = error.message ?: error.javaClass.simpleName
        }
        return reply
    }

    private fun stopLock() {
        try {
            stopLockTask()
        } catch (_: Exception) {
            // Not pinned, or already unpinned: still restore the chrome below.
        }
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        applyImmersiveMode(false)
    }

    private fun applyImmersiveMode(hide: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val controller = window.insetsController ?: return
            if (hide) {
                controller.hide(WindowInsets.Type.systemBars())
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            } else {
                controller.show(WindowInsets.Type.systemBars())
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = if (hide) {
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            } else {
                View.SYSTEM_UI_FLAG_VISIBLE
            }
        }
    }

    private fun isLockTaskActive(): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
                .lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
        } else {
            false
        }
    } catch (_: Exception) {
        false
    }

    private fun isLockTaskPermitted(): Boolean = try {
        (getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager)
            .isLockTaskPermitted(packageName)
    } catch (_: Exception) {
        false
    }

    private fun handleIntegrity(call: MethodCall, result: MethodChannel.Result) =
        when (call.method) {
            "getIntegrityReport" -> result.success(integrityReport(call))
            else -> result.notImplemented()
        }

    /**
     * One integrity sample: what is attached to this device right now.
     *
     * Every lookup below swallows its own failure, so a device that cannot answer
     * contributes `false` rather than crashing the channel — and Dart reads an
     * unanswered probe as "cannot see", never as a violation.
     */
    private fun integrityReport(call: MethodCall): HashMap<String, Any?> {
        val reply = HashMap<String, Any?>()
        reply["supported"] = true

        val displays = secondaryDisplays()
        val reason = virtualCameraReason(call.argument<String>("cameraId"))

        reply["secondaryDisplay"] = displays.isNotEmpty()
        reply["secondaryDisplayNames"] = displays
        reply["virtualCamera"] = reason != null
        reply["virtualCameraReason"] = reason
        reply["externalCameraSupported"] = externalCameraSupported()
        reply["detail"] = when {
            reason != null && displays.isNotEmpty() ->
                "$reason Another display is attached: ${displays.joinToString(", ")}."
            reason != null -> reason
            displays.isNotEmpty() ->
                "Another display is attached: ${displays.joinToString(", ")}."
            else -> null
        }
        return reply
    }

    /**
     * Every attached display that is neither this device's own screen nor
     * switched off.
     *
     * `DisplayManager` is the only API that sees an HDMI monitor or a cast target:
     * both arrive as *presentation* displays, which an app is handed only if the
     * platform exposes them — and one that is present but off (a monitor with no
     * signal) is left out, because nothing can be read from it.
     */
    private fun secondaryDisplays(): List<String> = try {
        val manager = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        manager.displays
            .filter {
                it.displayId != Display.DEFAULT_DISPLAY && it.state != Display.STATE_OFF
            }
            .map { display ->
                val name = display.name
                val label = if (name.isNullOrBlank()) "display ${display.displayId}" else name
                // FLAG_PRESENTATION is what the platform sets on a display that a
                // presentation (or a cast session) renders to.
                if (display.flags and Display.FLAG_PRESENTATION != 0) {
                    "$label (casting)"
                } else {
                    label
                }
            }
    } catch (_: Exception) {
        emptyList()
    }

    private fun cameraIds(): List<String> = try {
        (getSystemService(Context.CAMERA_SERVICE) as CameraManager).cameraIdList.toList()
    } catch (_: Exception) {
        emptyList()
    }

    private fun externalCameraSupported(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S_V2) {
            try {
                (getSystemService(Context.CAMERA_SERVICE) as CameraManager)
                    .isExternalCameraSupported
            } catch (_: Exception) {
                false
            }
        } else {
            // There is no API to ask before 32 ("does this device take USB
            // cameras?"), so the attachable-camera list answers the same question.
            cameraIds().any { isExternalFacingCamera(it) }
        }

    /**
     * Why the camera feeding this attempt counts as virtual, or null when it is
     * this device's own lens.
     *
     * The exam passes the id of the camera it actually opened, which makes the
     * strongest case exact: that id's lens facing is EXTERNAL, i.e. a USB/plug-in
     * camera rather than one of the device's own. When the exam cannot name one
     * yet (its controller is not up), the mere presence of an external camera is
     * reported instead — a lens on the camera list that is not part of this device
     * is exactly the substitution surface this looks for, and the app cannot tell
     * which of two lenses fed it.
     */
    private fun virtualCameraReason(requestedCameraId: String?): String? {
        if (isEmulator()) {
            return "This device is an emulator, so its camera feed is virtual rather " +
                "than a physical lens."
        }

        if (requestedCameraId != null && isExternalFacingCamera(requestedCameraId)) {
            return "The camera in use (id $requestedCameraId) is an external device, not " +
                "this device's own lens."
        }

        val attached = cameraIds().firstOrNull { isExternalFacingCamera(it) }
        if (attached != null && attached != requestedCameraId) {
            return "An external camera (id $attached) is attached to this device."
        }

        return null
    }

    /**
     * The classic emulator fingerprints. An emulator has no physical camera at
     * all — whatever "front camera" it reports is synthesised, or a webcam passed
     * through from the host — so the feed an exam sees there is never the
     * student's real lens.
     */
    private fun isEmulator(): Boolean =
        Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.contains("emulator") ||
            Build.MODEL.contains("Emulator", ignoreCase = true) ||
            Build.MODEL.contains("Android SDK built for") ||
            Build.HARDWARE.contains("goldfish") ||
            Build.HARDWARE.contains("ranchu") ||
            Build.PRODUCT.contains("sdk")

    companion object {
        private const val CHANNEL = "lock_task_channel"
        private const val INTEGRITY_CHANNEL = "hardware_integrity_channel"
    }
}

