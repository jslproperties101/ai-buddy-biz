/// Values are injected at build time with --dart-define (see .github/workflows/android.yml).
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  /// Database area the app reads and writes. Since Batch 2b (9 Nov 2026) Ai buddy Biz lives in the EAB-QA-Test
  /// project in its own schema "biz". Build with --dart-define=SUPABASE_SCHEMA=public for a stand-alone Biz project.
  static const supabaseSchema = String.fromEnvironment('SUPABASE_SCHEMA', defaultValue: 'biz');
  static const appName = 'Ai buddy Biz';
  /// Public page that shows shipment tracking (web/track.html hosted anywhere). Optional.
  static const trackingUrl = String.fromEnvironment('TRACK_URL');
  /// Public signing page (web/sign.html hosted anywhere). Needed to send contracts for e-signature.
  static const signUrl = String.fromEnvironment('SIGN_URL');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
