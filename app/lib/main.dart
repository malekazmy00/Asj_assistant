import 'package:flutter/material.dart';

import 'config.dart';
import 'screens/chat_screen.dart';
import 'screens/library_screen.dart';
import 'services/outbox_service.dart';
import 'services/supabase_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (AppConfig.isConfigured) {
    await SupabaseService.initialize();
    // App-wide, not screen-scoped: pending sends keep retrying on reconnect
    // even while the user is on the Library tab.
    await OutboxService.instance.init();
  }
  runApp(const MedicalEngineerAssistantApp());
}

class MedicalEngineerAssistantApp extends StatelessWidget {
  const MedicalEngineerAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
