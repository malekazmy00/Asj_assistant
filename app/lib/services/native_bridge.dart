import 'package:flutter/services.dart';

/// Thin channel to a couple of small native (Android) helpers that exist
/// purely to support error/crash logging:
///
/// - [getFilesDir]: the app's private storage directory, as an absolute
///   path — used to find the "pending crash" JSON files a native crash
///   handler writes (see MainActivity.kt) without any cross-language
///   guessing about where that maps to on the Dart side.
/// - [setLastAction]: tells native code what the user was just doing, so
///   if the process dies right after, the crash record can include that
///   context (e.g. "tapped mic button") even though the actual crash
///   happens entirely outside Dart.
///
/// No-ops (never throws) on platforms without this channel implemented —
/// today that's everything except Android.
class NativeBridge {
  NativeBridge._();
  static final NativeBridge instance = NativeBridge._();

  static const _channel = MethodChannel('medical_engineer_assistant/native_bridge');

  Future<String?> getFilesDir() async {
    try {
      return await _channel.invokeMethod<String>('getFilesDir');
    } catch (_) {
      return null;
    }
  }

  Future<void> setLastAction(String action) async {
    try {
      await _channel.invokeMethod<void>('setLastAction', {'action': action});
    } catch (_) {
      // Best-effort context for a crash handler — never worth failing the
      // actual feature over.
    }
  }
}
