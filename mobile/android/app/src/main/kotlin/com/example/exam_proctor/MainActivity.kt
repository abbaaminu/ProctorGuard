package com.example.exam_proctor

import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.os.Build
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
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
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

    companion object {
        private const val CHANNEL = "lock_task_channel"
    }
}

