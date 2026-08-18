# Vendored fork of `speech_to_text` 7.4.0

This is a locally-patched copy of the `speech_to_text` pub.dev package
(unmodified except as noted below), pulled in via `dependency_overrides` in
`app/pubspec.yaml`. It exists to fix one specific, confirmed-by-real-crash-log
bug in the upstream package — remove this override and delete this directory
if/when a future upstream release fixes it (check the CHANGELOG for a fix to
`startListening` error handling first).

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
