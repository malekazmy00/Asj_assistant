import 'dart:async';

import 'package:flutter/material.dart';

import 'config.dart';
import 'screens/chat_screen.dart';
import 'screens/library_screen.dart';
import 'services/outbox_service.dart';
import 'services/supabase_service.dart';
import 'theme/app_theme.dart';

// ============================================================================
// TEMPORARY DEBUG BUILD ONLY — remove this whole block (and the
// navigatorKey wiring below) once the mic-button crash is confirmed
// root-caused. There's no adb/device access to pull a real crash log
// right now, so this catches any uncaught exception app-wide and shows it
// in a dialog to screenshot, instead of the app just dying with no trace.
// ============================================================================
final debugNavigatorKey = GlobalKey<NavigatorState>();
bool _showingDebugErrorDialog = false;

void _showDebugErrorDialog(String title, Object error, StackTrace? stack) {
  // showDialog during a build/layout/paint pass (which is exactly when
  // FlutterError.onError fires) isn't safe — defer to the next frame.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final context = debugNavigatorKey.currentContext;
    if (context == null || _showingDebugErrorDialog) return;
    _showingDebugErrorDialog = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              '$error\n\n${stack ?? '(no stack trace)'}',
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _showingDebugErrorDialog = false;
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Close'),
          ),
        ],
      ),
    );
  });
}
// ============================================================================
// End temporary debug block
// ============================================================================

Future<void> main() async {
  // TEMPORARY (debug): route Flutter framework-level errors (widget build/
  // layout/paint) to the dialog above instead of the default red screen.
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    defaultOnError?.call(details);
    _showDebugErrorDialog('Flutter error', details.exception, details.stack);
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
    }
    runApp(const MedicalEngineerAssistantApp());
  }, (error, stack) {
    debugPrint('Uncaught error: $error\n$stack');
    _showDebugErrorDialog('Uncaught error', error, stack); // TEMPORARY (debug)
  });
}

class MedicalEngineerAssistantApp extends StatelessWidget {
  const MedicalEngineerAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: debugNavigatorKey, // TEMPORARY (debug) — see block above
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
