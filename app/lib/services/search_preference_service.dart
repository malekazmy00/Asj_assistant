import 'package:shared_preferences/shared_preferences.dart';

/// Whether live web search is on for new chat messages — a simple, global,
/// persisted toggle (not per-conversation), surfaced as a button next to
/// the composer's attach/mic icons. Added so search can be switched off
/// while comparing free-tier LLM providers whose own live search is
/// quota-blocked (see chat/index.ts's LLM_PROVIDER / the web_search tool
/// in web_search.ts), and to give an easy way to turn it off later for
/// cost control regardless of which provider is active.
class SearchPreferenceService {
  SearchPreferenceService._();
  static final SearchPreferenceService instance = SearchPreferenceService._();

  static const _prefsKey = 'search_enabled_v1';

  bool _enabled = true;
  bool get enabled => _enabled;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_prefsKey) ?? true;
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, value);
  }
}
