# R8 / ProGuard rules for the release build (see `app/build.gradle.kts`:
# `isMinifyEnabled` + `isShrinkResources`).
#
# Shrinking and obfuscation are only safe because the *native* halves of this app are
# reached by name rather than by a direct call: the platform instantiates the activity
# from the manifest, the Flutter engine looks up the plugin registrant reflectively, and
# the on-device vision models are loaded from the bundled native library by class name.
# Everything kept below is kept for one of those three reasons.

# --- Diagnostics ------------------------------------------------------------
# Stack traces from a shrunken build are unreadable without these: the line numbers
# are stripped by default, and an obfuscated crash report from a student's phone is
# not something that can be acted on.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod,Exceptions,AnnotationDefault

# --- Flutter embedding and the plugin registry ------------------------------
# `GeneratedPluginRegistrant` is called by name, and each plugin's channel handler is
# registered through it, so the whole embedding surface survives.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-dontwarn io.flutter.embedding.**

# --- This app's native half -------------------------------------------------
# Instantiated from the manifest and answered over `lock_task_channel` /
# `hardware_integrity_channel`; the channel names themselves are string literals that
# R8 would otherwise be free to consider unused.
-keep class com.example.exam_proctor.** { *; }

# --- On-device vision (the engine named "MediaPipe") -------------------------
# `lib/core/services/mediapipe_proctoring_service.dart` -> `MediaPipeProctoringService`
# is the only camera-signal source in the app, and it is backed by
# `google_mlkit_face_detection` (`com.google.mlkit:face-detection:16.1.7`, the *bundled*
# detector) plus the transitively-resolved `play-services-mlkit-face-detection`, whose
# classes are also on the release classpath. Both AARs ship consumer rules, but those
# only cover their own generics/proto reflection - see the packages kept below, each
# verified in the resolved artefacts of this build:
#
#   com.google.mlkit.**                              the public API the plugin calls
#                                                    (`FaceDetection.getClient`, options)
#   com.google.android.gms.internal.mlkit_vision_face_bundled.**
#                                                    the bundled engine, instantiated by
#                                                    name from `libface_detector_v2_jni.so`
#   com.google.android.gms.vision.face.**             the JNI entry point
#                                                    (`FaceDetectorV2Jni`, kept alive so
#                                                    the native library can find it)
#   com.google.android.gms.internal.mlkit_vision_*.** the shared vision plumbing
#   org.tensorflow.lite.** / com.google.android.odml.**  what the models run on
#
# The bundled AAR's own rules keep the *fields of* `...mlkit_vision_face_bundled.zzuw`
# subclasses and `com.google.mlkit:common` keeps `@UsedBy` members; neither keeps the
# classes in between. Losing one of them turns every face signal into `no_face`, i.e. a
# student disqualified by a shrinker.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.vision.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_face.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_face_bundled.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class com.google.android.odml.** { *; }
-keep class org.tensorflow.lite.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.vision.**
-dontwarn com.google.android.gms.internal.mlkit_vision_face.**
-dontwarn com.google.android.gms.internal.mlkit_vision_face_bundled.**
-dontwarn com.google.android.gms.internal.mlkit_vision_common.**
-dontwarn com.google.android.gms.internal.mlkit_common.**
-dontwarn com.google.android.odml.**
-dontwarn org.tensorflow.lite.**

# --- Dynamite module descriptors --------------------------------------------
# The bundled detector carries `com.google.android.gms.dynamite.descriptors.com.google.
# mlkit.dynamite.face.ModuleDescriptor`, a class whose only purpose is to be found by the
# Dynamite loader's `Class.forName`. Nothing statically references it, so R8 removes it
# and the loader's graceful-fallback path is what actually runs.
-keep class com.google.android.gms.dynamite.descriptors.** { *; }

# Kept for the day the face detector is replaced by MediaPipe Tasks' face landmarker
# (`MediaPipeProctoringService` documents that seam): the plan was scoped around
# `com.google.mediapipe`, and re-deriving these rules from a runtime crash is a
# needlessly expensive way to find out they were missing.
-keep class com.google.mediapipe.** { *; }
-dontwarn com.google.mediapipe.**

# --- Camera, audio and permissions -----------------------------------------
# `camera_android_camerax` and `permission_handler` reach AndroidX/framework classes
# reflectively in places; the annotations they read have to survive too (kept above).
-keep class androidx.camera.** { *; }
-keep class androidx.lifecycle.** { *; }
-dontwarn androidx.camera.**
-dontwarn androidx.lifecycle.**

# --- Kotlin ----------------------------------------------------------------
# Metadata drives reflection over Kotlin classes (the plugins are Kotlin).
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**
-dontwarn kotlinx.**
