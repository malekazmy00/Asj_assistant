import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which conversation is currently open, across app restarts.
///
/// This can't be inferred from `last_message_at` alone: a freshly-created
/// empty chat has no messages yet, so it would never sort as "most recent"
/// and a restart would silently drop the user back into an old
/// conversation instead of the new one they just started.
class SessionService {
  SessionService._();
  static final SessionService instance = SessionService._();

  static const _prefsKey = 'current_conversation_id';

  Future<String?> getCurrentConversationId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsKey);
  }

  Future<void> setCurrentConversationId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, id);
  }
}
