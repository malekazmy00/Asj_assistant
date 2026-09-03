import 'dart:async';

import 'package:flutter/material.dart';

import 'config.dart';
import 'screens/chat_screen.dart';
import 'screens/library_screen.dart';
import 'services/error_log_service.dart';
import 'services/outbox_service.dart';
import 'services/search_preference_service.dart';
import 'services/supabase_service.dart';
import 'theme/app_theme.dart';

/// Used only to show a lightweight, optional "something went wrong" banner
/// after a Flutter-level crash gets logged — not needed for the logging
/// itself, which doesn't require any UI.
final appNavigatorKey = GlobalKey<NavigatorState>();

void _showRecoveredFromErrorBanner() {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final context = appNavigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Something went wrong there — you can keep going.')),
    );
  });
}

Future<void> main() async {
  // Flutter framework-level errors (widget build/layout/paint) — log to
  // error_logs and show a soft "something went wrong" banner instead of
  // the default red screen. Still calls the previous handler first so
  // console output (visible in a debug build) is unaffected.
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    defaultOnError?.call(details);
    unawaited(ErrorLogService.instance.logError(
      level: 'fatal',
      source: 'dart',
      errorType: details.exception.runtimeType.toString(),
      message: details.exception.toString(),
      stackTrace: details.stack?.toString(),
      screenOrAction: 'Flutter framework error',
    ));
    _showRecoveredFromErrorBanner();
  };

  // A platform plugin misbehaving on some specific device (e.g. a
  // connectivity check failing asynchronously, outside any try/catch we
  // control) should never be able to take the whole app down to a blank
  // screen — log it and keep going.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    if (AppConfig.isConfigured) {
      await SupabaseService.initialize();
      // App-wide, not screen-scoped: pending sends keep retrying on
      // reconnect even while the user is on the Library tab.
      await OutboxService.instance.init();
      await SearchPreferenceService.instance.init();
      // Uploads (and clears) any crash file a native handler wrote during
      // a previous run that ended in a crash the Dart side never saw —
      // see MainActivity.kt / ErrorLogService.uploadPendingNativeCrashes.
      unawaited(ErrorLogService.instance.uploadPendingNativeCrashes());
    }
    runApp(const MedicalEngineerAssistantApp());
  }, (error, stack) {
    debugPrint('Uncaught error: $error\n$stack');
    unawaited(ErrorLogService.instance.logError(
      level: 'fatal',
      source: 'dart',
      errorType: error.runtimeType.toString(),
      message: error.toString(),
      stackTrace: stack.toString(),
      screenOrAction: 'uncaught async error',
    ));
    _showRecoveredFromErrorBanner();
  });
}

class MedicalEngineerAssistantApp extends StatelessWidget {
  const MedicalEngineerAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'Medical Engineer Assistant',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: AppConfig.isConfigured ? const RootShell() : const _MissingConfigScreen(),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const _screens = [ChatScreen(), LibraryScreen()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Chat'),
          NavigationDestination(icon: Icon(Icons.folder_outlined), label: 'Library'),
        ],
      ),
    );
  }
}

class _MissingConfigScreen extends StatelessWidget {
  const _MissingConfigScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Missing SUPABASE_URL / SUPABASE_ANON_KEY.\n'
            'Build with --dart-define-from-file=dart_define.json',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
