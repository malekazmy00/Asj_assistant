/// Build-time configuration, supplied via `--dart-define-from-file`.
///
/// This app has no login system (v1, single user), so the only secret it
/// ever holds is the Supabase *anon* key — safe by design to ship inside a
/// client binary, since all real authorization happens via Row Level
/// Security policies and the service-role-only Edge Functions.
class AppConfig {
  AppConfig._();

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
