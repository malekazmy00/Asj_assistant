import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'native_bridge.dart';

/// Client-side error/crash telemetry — every uncaught exception (Dart or
/// native) and every handled-but-worth-knowing-about failure gets a row in
/// `error_logs`, so it can be queried directly instead of pulled off the
/// device by hand.
///
/// Logging itself must never be able to cause a *new* failure: every path
/// here swallows its own errors (network down, table unreachable,
/// whatever) rather than throwing — this is a side channel, not something
/// calling code should ever have to handle.
class ErrorLogService {
  ErrorLogService._();
  static final ErrorLogService instance = ErrorLogService._();

  String? _appVersion;
  Map<String, dynamic>? _deviceInfo;

  Future<void> _ensureContextLoaded() async {
    if (_appVersion != null && _deviceInfo != null) return;
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = '${info.version}+${info.buildNumber}';
    } catch (e) {
      _appVersion = 'unknown';
      debugPrint('ErrorLogService: could not read app version: $e');
    }
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await plugin.androidInfo;
        _deviceInfo = {
          'os_version': 'Android ${android.version.release} (SDK ${android.version.sdkInt})',
          'model': android.model,
          'manufacturer': android.manufacturer,
          'brand': android.brand,
        };
      } else {
        _deviceInfo = {'platform': Platform.operatingSystem, 'os_version': Platform.operatingSystemVersion};
      }
    } catch (e) {
      _deviceInfo = {};
      debugPrint('ErrorLogService: could not read device info: $e');
    }
  }

  /// Inserts one error_logs row. Insert-only by RLS design (see migration
  /// 0008) — this deliberately does NOT chain `.select()`, because
  /// requesting the row back (`Prefer: return=representation`) requires a
  /// read policy the anon key doesn't have here, and would make every
  /// single log call fail with a misleading RLS error.
  Future<void> logError({
    required String level, // fatal | error | warning
    required String source, // dart | native
    String? errorType,
    String? message,
    String? stackTrace,
    String? screenOrAction,
  }) async {
    try {
      await _ensureContextLoaded();
      await Supabase.instance.client.from('error_logs').insert({
        'level': level,
        'source': source,
        'error_type': errorType,
        'message': message,
        'stack_trace': stackTrace,
        'screen_or_action': screenOrAction,
        'app_version': _appVersion,
        'device_info': _deviceInfo,
      });
    } catch (e) {
      // If telemetry itself can't reach the network, that's fine — just
      // don't let it be a second failure on top of whatever we were
      // trying to log.
      debugPrint('ErrorLogService: failed to log error ($source/$level): $e');
    }
  }

  /// Call once at startup (after Supabase is initialized). Picks up any
  /// crash file MainActivity.kt's uncaught-exception handler wrote during
  /// a previous run (the process was dying at the time, so it couldn't
  /// make a network call itself — see native_bridge.dart), uploads each
  /// one, and deletes it only on a successful upload so a crash from a
  /// launch with no connectivity just retries on the next one.
  Future<void> uploadPendingNativeCrashes() async {
    try {
      final filesDirPath = await NativeBridge.instance.getFilesDir();
      if (filesDirPath == null) return;

      final crashDir = Directory('$filesDirPath/pending_crash_logs');
      if (!await crashDir.exists()) return;

      final files = await crashDir.list().where((e) => e.path.endsWith('.json')).toList();
      if (files.isEmpty) return;

      await _ensureContextLoaded();

      for (final entry in files) {
        final file = File(entry.path);
        try {
          final raw = await file.readAsString();
          final data = jsonDecode(raw) as Map<String, dynamic>;
          await Supabase.instance.client.from('error_logs').insert({
            'level': 'fatal',
            'source': 'native',
            'error_type': data['error_type'],
            'message': data['message'],
            'stack_trace': data['stack_trace'],
            'screen_or_action': data['screen_or_action'],
            'app_version': _appVersion,
            'device_info': _deviceInfo,
          });
          await file.delete();
        } catch (e) {
          // Leave this one file in place — it'll be retried next launch.
          // Other pending files still get their own attempt below.
          debugPrint('ErrorLogService: failed to upload pending native crash ${entry.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('ErrorLogService: uploadPendingNativeCrashes failed: $e');
    }
  }
}
