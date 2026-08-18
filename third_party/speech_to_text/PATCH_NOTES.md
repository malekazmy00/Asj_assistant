# Vendored fork of `speech_to_text` 7.4.0 — DISABLED, kept for reference

**Status as of the mic-button rework: not wired into the app.** The patch
below made on-device live recognition survive the crash it was hitting, but
real-device testing afterward turned up further crashes on a *second*
device in the same live-recognition path — a broader reliability problem
with the plugin's on-device flow across devices, not just the one bug this
patch covered. Rather than keep chasing per-device crashes in a live
recognizer, the mic button now records a short local clip and sends it to
Gemini for transcription (same approach as call recordings — see
`chat_composer.dart` and `supabase/functions/transcribe-voice-message/`),
which sidesteps on-device `SpeechRecognizer` entirely.

This directory (and the patch below) is kept on disk, undeleted and
documented, in case on-device recognition is worth revisiting later
(offline use, lower latency, no per-utterance API cost). To re-enable: add
`speech_to_text` back to `app/pubspec.yaml`'s `dependencies:` and re-add the
`dependency_overrides:` block pointing here (see git history for the exact
lines — `git log -p -- app/pubspec.yaml`).

---

This is a locally-patched copy of the `speech_to_text` pub.dev package
(unmodified except as noted below). It fixes one specific,
confirmed-by-real-crash-log bug in the upstream package — worth checking
the CHANGELOG for a fix to `startListening` error handling before ever
re-enabling this fork, in case it's no longer needed.

## The bug

`android/src/main/kotlin/com/csdcorp/speech_to_text/SpeechToTextPlugin.kt`,
`startListening()`, called `speechRecognizer?.startListening(recognizerIntent)`
inside a bare `handler.post { }` block with no try/catch. On some devices —
confirmed via `error_logs` in production, device: "MTT L506", Android 8.1
(SDK 27) — the OS resolves the device's default speech-recognition service
to a restricted/non-exported component, and `startListening()` throws:

```
java.lang.SecurityException: Not allowed to bind to service Intent
{ act=android.speech.RecognitionService cmp=<some non-Google package>/... }
```

Because this throws from a posted `Handler` callback — after the original
plugin method call already returned — it's an uncaught exception on the
main thread that nothing downstream (not this plugin's own `onMethodCall`
try/catch, not Dart's `FlutterError.onError`/`runZonedGuarded`, not any
try/catch in the calling Dart code) can ever catch. It takes the whole app
down.

## The fix

Wrapped that one `startListening()` call in try/catch and routed any
exception through the plugin's own existing `sendError()` helper — the
same path used for every other recognizer failure this plugin reports —
so it now surfaces as a normal `onError` callback on the Dart side
(`SpeechErrorListener`) instead of a crash.

See the `// PATCHED` comment at the call site for the exact diff.
