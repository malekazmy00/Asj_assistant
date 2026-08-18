package com.medicalengineerassistant.medical_engineer_assistant

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val channelName = "medical_engineer_assistant/native_bridge"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Install once, before anything else could crash. Doesn't replace
        // the platform's own crash handling (Android still shows its usual
        // "keeps stopping" dialog) — this only writes a record of what
        // happened first, since there's no adb access to pull one after
        // the fact otherwise.
        NativeCrashReporter.install(applicationContext)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getFilesDir" -> result.success(applicationContext.filesDir.absolutePath)
                "setLastAction" -> {
                    NativeCrashReporter.lastAction = call.argument<String>("action") ?: "unknown"
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}

/**
 * Catches uncaught exceptions that never reach Dart at all — thrown
 * directly from native/Activity-lifecycle code (permission callbacks,
 * plugin native implementations, etc.) — and writes a JSON record to app
 * storage before the process actually dies. Flutter-side errors are
 * already handled separately in Dart (see main.dart's FlutterError.onError
 * / runZonedGuarded); this exists specifically for the class of crash that
 * happens *outside* the Dart VM and would otherwise leave zero trace.
 *
 * Deliberately does NOT attempt a network call here — the process is
 * actively dying, so there's no reliable window to complete one. Instead
 * this writes one small local file per crash under
 * filesDir/pending_crash_logs/, which the Dart side uploads to Supabase
 * and deletes on the *next* launch (see ErrorLogService.uploadPendingNativeCrashes).
 */
object NativeCrashReporter {
    private const val TAG = "NativeCrashReporter"

    /** Best-effort context set by Dart right before a risky operation (see
     * NativeBridge.setLastAction) — included in the crash record if a
     * crash happens shortly after. Not guaranteed accurate if a crash
     * happens for an unrelated reason well after the last update. */
    @Volatile
    var lastAction: String = "unknown"

    private var installed = false

    fun install(context: android.content.Context) {
        if (installed) return
        installed = true

        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()

        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                writeCrashFile(context, throwable)
            } catch (e: Throwable) {
                // Never let crash *reporting* itself throw — that would
                // just replace one uncaught exception with another during
                // an already-fragile moment.
                Log.e(TAG, "Failed to write crash file", e)
            }
            // Always hand off to whatever Android/Flutter's own handler
            // would have done — this is purely additive, not a
            // replacement for normal crash behavior.
            previousHandler?.uncaughtException(thread, throwable)
        }
    }

    private fun writeCrashFile(context: android.content.Context, throwable: Throwable) {
        val dir = File(context.filesDir, "pending_crash_logs")
        if (!dir.exists()) dir.mkdirs()

        val stackTrace = Log.getStackTraceString(throwable)
        val timestamp = SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'", Locale.US).format(Date())

        val json = buildString {
            append("{")
            append("\"error_type\":").append(jsonString(throwable.javaClass.name)).append(",")
            append("\"message\":").append(jsonString(throwable.message ?: "")).append(",")
            append("\"stack_trace\":").append(jsonString(stackTrace)).append(",")
            append("\"screen_or_action\":").append(jsonString(lastAction))
            append("}")
        }

        val file = File(dir, "crash_$timestamp.json")
        file.writeText(json)
    }

    /** Minimal hand-rolled JSON string escaping — deliberately not pulling
     * in a JSON library for this one call site; org.json's JSONObject
     * would work too but this avoids any risk of that itself throwing
     * mid-crash-handling. */
    private fun jsonString(value: String): String {
        val sb = StringBuilder()
        sb.append('"')
        for (c in value) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (c.code < 0x20) sb.append("\\u%04x".format(c.code)) else sb.append(c)
            }
        }
        sb.append('"')
        return sb.toString()
    }
}
