import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/setup_screen.dart';
import 'services/crm.dart';
import 'services/session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (AppConfig.isConfigured) {
    await Supabase.initialize(url: AppConfig.supabaseUrl, anonKey: AppConfig.supabaseAnonKey);
  }
  runApp(const AiBuddyBizApp());
}

class AiBuddyBizApp extends StatelessWidget {
  const AiBuddyBizApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E));
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: AppConfig.isConfigured ? const AuthGate() : const _NotConfigured(),
    );
  }
}

class _NotConfigured extends StatelessWidget {
  const _NotConfigured();
  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('This build has no Supabase settings.\nRebuild with SUPABASE_URL and SUPABASE_ANON_KEY.',
                textAlign: TextAlign.center),
          ),
        ),
      );
}

/// Login → pick/create business → home.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // Load the business once per signed-in user, not on every auth event (token refreshes happen hourly).
  String? _loadedFor;
  Future<bool>? _loading;

  Future<bool> _sessionFor(String uid) {
    if (_loadedFor != uid || _loading == null) {
      _loadedFor = uid;
      _loading = Session.instance.load().then((has) async {
        if (has) await Crm.instance.load();
        return has;
      });
    }
    return _loading!;
  }

  void _reload() => setState(() => _loading = null);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, _) {
        final user = Supabase.instance.client.auth.currentUser;
        if (user == null) {
          _loadedFor = null;
          _loading = null;
          return const LoginScreen();
        }
        return FutureBuilder<bool>(
          future: _sessionFor(user.id),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Scaffold(body: Center(child: CircularProgressIndicator()));
            }
            if (snap.hasError) {
              return Scaffold(
                body: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('Could not load your business:\n${snap.error}', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _reload, child: const Text('Retry')),
                  ]),
                ),
              );
            }
            if (snap.data != true) {
              return SetupScreen(onDone: _reload);
            }
            return const HomeScreen();
          },
        );
      },
    );
  }
}
