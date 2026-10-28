/// Values are injected at build time with --dart-define (see .github/workflows/android.yml).
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const appName = 'Ai buddy Biz';
  /// Public page that shows shipment tracking (web/track.html hosted anywhere). Optional.
  static const trackingUrl = String.fromEnvironment('TRACK_URL');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
