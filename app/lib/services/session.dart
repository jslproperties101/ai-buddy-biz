import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class Outlet {
  final String id;
  final String name;
  final String kind;
  final String? countryCode;
  final String? region;
  Outlet(this.id, this.name, this.kind, this.countryCode, this.region);
}

class TaxRate {
  final String code;
  final double rate;
  final String name;
  final bool inclusive;
  TaxRate(this.code, this.rate, this.name, this.inclusive);
  Map<String, dynamic> toJson() => {'code': code, 'rate': rate, 'name': name, 'inclusive': inclusive};
  static TaxRate fromJson(Map<String, dynamic> j) =>
      TaxRate(j['code'] as String, (j['rate'] as num).toDouble(), j['name'] as String, j['inclusive'] as bool);
}

/// Who is signed in, which business and outlet they're working in, and what they may do.
class Session {
  Session._();
  static final Session instance = Session._();

  SupabaseClient get db => Supabase.instance.client;

  String? tenantId;
  String tenantName = '';
  String currency = 'MYR';
  String countryCode = 'MY';
  String defaultTaxCode = 'standard';
  String roleName = '';
  Set<String> perms = {};
  Set<String> modules = {};
  List<Outlet> outlets = [];
  Outlet? outlet;

  /// Tax rates for the current outlet, by tax code. Cached on the phone for offline selling.
  Map<String, TaxRate> taxTable = {};

  /// The signed-in user's open shift at this outlet, if any.
  String? openShiftId;
  double openShiftCash = 0;

  bool can(String perm) => perms.contains(perm);

  /// Module switched on for this business (POS, INV, FIN, CRM, LOG, …)
  bool has(String module) => modules.contains(module);

  /// Returns false when the user has no business yet.
  Future<bool> load() async {
    final uid = db.auth.currentUser!.id;
    final prefs = await SharedPreferences.getInstance();
    final rows = await db
        .from('memberships')
        .select('tenant_id, role_id, roles(name), tenants(name, base_currency, country_code, default_tax_code)')
        .eq('user_id', uid)
        .eq('active', true);
    if (rows.isEmpty) return false;

    final saved = prefs.getString('tenant_id');
    final m = rows.firstWhere((r) => r['tenant_id'] == saved, orElse: () => rows.first);
    tenantId = m['tenant_id'] as String;
    tenantName = (m['tenants']?['name'] ?? '') as String;
    currency = (m['tenants']?['base_currency'] ?? 'MYR') as String;
    countryCode = (m['tenants']?['country_code'] ?? 'MY') as String;
    defaultTaxCode = (m['tenants']?['default_tax_code'] ?? 'standard') as String;
    roleName = (m['roles']?['name'] ?? '') as String;
    await prefs.setString('tenant_id', tenantId!);

    final rp = await db.from('role_permissions').select('permission_code').eq('role_id', m['role_id']);
    perms = {for (final r in rp) r['permission_code'] as String};

    await reloadModules();

    await reloadOutlets();
    final savedOutlet = prefs.getString('outlet_id');
    outlet = outlets.where((o) => o.id == savedOutlet).firstOrNull ?? (outlets.isEmpty ? null : outlets.first);
    await _loadOutletState();
    return true;
  }

  Future<void> reloadModules() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'modules_$tenantId';
    try {
      final rows = await db.from('tenant_modules').select('module').eq('tenant_id', tenantId!).eq('enabled', true);
      modules = {for (final r in rows) r['module'] as String};
      await prefs.setStringList(key, modules.toList());
    } catch (_) {
      modules = (prefs.getStringList(key) ?? ['POS', 'INV', 'FIN', 'CRM']).toSet();
    }
  }

  Future<void> reloadOutlets() async {
    final os = await db
        .from('outlets')
        .select('id, name, kind, country_code, region')
        .eq('tenant_id', tenantId!)
        .order('name');
    outlets = [
      for (final o in os)
        Outlet(o['id'] as String, o['name'] as String, o['kind'] as String, o['country_code'] as String?,
            o['region'] as String?)
    ];
    if (outlet != null) outlet = outlets.where((o) => o.id == outlet!.id).firstOrNull ?? outlet;
  }

  Future<void> selectOutlet(Outlet o) async {
    outlet = o;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('outlet_id', o.id);
    await _loadOutletState();
  }

  Future<void> _loadOutletState() async {
    await refreshTaxTable();
    await refreshShift();
  }

  String get _taxKey => 'tax_${outlet?.id}';

  /// Online: fetch and cache. Offline: use the cached copy.
  Future<void> refreshTaxTable() async {
    if (outlet == null) return;
    final prefs = await SharedPreferences.getInstance();
    try {
      final rows = await db.rpc('outlet_tax_table', params: {'p_outlet': outlet!.id}) as List;
      taxTable = {
        for (final r in rows)
          r['tax_code'] as String: TaxRate(r['tax_code'] as String, (r['rate'] as num).toDouble(), r['name'] as String,
              r['inclusive'] as bool)
      };
      await prefs.setString(_taxKey, jsonEncode([for (final t in taxTable.values) t.toJson()]));
    } catch (_) {
      final raw = prefs.getString(_taxKey);
      if (raw != null) {
        taxTable = {
          for (final j in (jsonDecode(raw) as List)) (j['code'] as String): TaxRate.fromJson(j as Map<String, dynamic>)
        };
      }
    }
  }

  /// Same fallback rules as the server: unknown code → 'standard', except exempt/zero → 0%.
  TaxRate taxFor(String? code) {
    final c = (code == null || code.isEmpty) ? defaultTaxCode : code;
    final hit = taxTable[c];
    if (hit != null) return hit;
    final inclusive = taxTable.values.any((t) => t.inclusive);
    if (c == 'exempt' || c == 'zero') return TaxRate(c, 0, 'Exempt', inclusive);
    return taxTable['standard'] ?? TaxRate('standard', 0, 'No tax', inclusive);
  }

  Future<void> refreshShift() async {
    if (outlet == null) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'shift_${outlet!.id}';
    try {
      final row = await db
          .from('shifts')
          .select('id, opening_cash')
          .eq('outlet_id', outlet!.id)
          .eq('user_id', db.auth.currentUser!.id)
          .isFilter('closed_at', null)
          .maybeSingle();
      openShiftId = row?['id'] as String?;
      openShiftCash = ((row?['opening_cash'] ?? 0) as num).toDouble();
      if (openShiftId == null) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, openShiftId!);
      }
    } catch (_) {
      openShiftId = prefs.getString(key);
    }
  }

  Future<void> signOut() async {
    tenantId = null;
    perms = {};
    openShiftId = null;
    await db.auth.signOut();
  }
}
