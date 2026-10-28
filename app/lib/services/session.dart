import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class Outlet {
  final String id;
  final String name;
  final String kind;
  Outlet(this.id, this.name, this.kind);
}

/// Who is signed in, which business and outlet they're working in, and what they may do.
class Session {
  Session._();
  static final Session instance = Session._();

  SupabaseClient get db => Supabase.instance.client;

  String? tenantId;
  String tenantName = '';
  String currency = 'MYR';
  String roleName = '';
  Set<String> perms = {};
  List<Outlet> outlets = [];
  Outlet? outlet;
  double defaultTaxRate = 0; // fraction, e.g. 0.06; full tax engine arrives in Batch C

  bool can(String perm) => perms.contains(perm);

  /// Returns false when the user has no business yet.
  Future<bool> load() async {
    final uid = db.auth.currentUser!.id;
    final prefs = await SharedPreferences.getInstance();
    final rows = await db
        .from('memberships')
        .select('tenant_id, role_id, roles(name), tenants(name, base_currency)')
        .eq('user_id', uid)
        .eq('active', true);
    if (rows.isEmpty) return false;

    final saved = prefs.getString('tenant_id');
    final m = rows.firstWhere((r) => r['tenant_id'] == saved, orElse: () => rows.first);
    tenantId = m['tenant_id'] as String;
    tenantName = (m['tenants']?['name'] ?? '') as String;
    currency = (m['tenants']?['base_currency'] ?? 'MYR') as String;
    roleName = (m['roles']?['name'] ?? '') as String;
    await prefs.setString('tenant_id', tenantId!);

    final rp = await db.from('role_permissions').select('permission_code').eq('role_id', m['role_id']);
    perms = {for (final r in rp) r['permission_code'] as String};

    final os = await db.from('outlets').select('id, name, kind').eq('tenant_id', tenantId!).order('name');
    outlets = [for (final o in os) Outlet(o['id'] as String, o['name'] as String, o['kind'] as String)];
    final savedOutlet = prefs.getString('outlet_id');
    outlet = outlets.where((o) => o.id == savedOutlet).firstOrNull ?? (outlets.isEmpty ? null : outlets.first);

    final mod = await db
        .from('tenant_modules')
        .select('settings')
        .eq('tenant_id', tenantId!)
        .eq('module', 'POS')
        .maybeSingle();
    defaultTaxRate = ((mod?['settings']?['default_tax_rate']) as num?)?.toDouble() ?? 0;
    return true;
  }

  Future<void> selectOutlet(Outlet o) async {
    outlet = o;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('outlet_id', o.id);
  }

  Future<void> saveTaxRate(double rate) async {
    final mod = await db
        .from('tenant_modules')
        .select('settings')
        .eq('tenant_id', tenantId!)
        .eq('module', 'POS')
        .maybeSingle();
    final settings = Map<String, dynamic>.from((mod?['settings'] as Map?) ?? {});
    settings['default_tax_rate'] = rate;
    await db.from('tenant_modules').update({'settings': settings}).eq('tenant_id', tenantId!).eq('module', 'POS');
    defaultTaxRate = rate;
  }

  Future<void> signOut() async {
    tenantId = null;
    perms = {};
    await db.auth.signOut();
  }
}
