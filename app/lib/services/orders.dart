import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'session.dart';

/// Menu item for order taking: one sellable variant with its option groups.
class MenuItem {
  final String productId;
  final String variantId;
  final String name;
  final String? categoryId;
  final double price;
  final bool soldOut;
  final List<ModGroup> groups;
  MenuItem(this.productId, this.variantId, this.name, this.categoryId, this.price, this.soldOut, this.groups);
}

class ModGroup {
  final String id;
  final String name;
  final int min;
  final int max;
  final List<(String, String, double)> options; // id, name, price
  ModGroup(this.id, this.name, this.min, this.max, this.options);
}

class Orders {
  Orders._();

  static NumberFormat get money => NumberFormat.currency(symbol: '${AppSession.instance.currency} ');
  static final hm = DateFormat('HH:mm');

  static const statusLabels = {
    'pending': 'New — accept?',
    'open': 'In progress',
    'ready': 'Ready',
    'out_for_delivery': 'Out for delivery',
    'delivered': 'Delivered — to close',
    'completed': 'Completed',
    'cancelled': 'Cancelled',
  };

  static const channelLabels = {
    'dine_in': 'Dine-in',
    'takeaway': 'Takeaway',
    'delivery': 'Delivery',
    'online': 'Online',
    'marketplace': 'Marketplace',
  };

  static const marketplaces = {
    'grabfood': 'GrabFood',
    'foodpanda': 'foodpanda',
    'shopeefood': 'ShopeeFood',
    'lalamove': 'Lalamove',
    'shopify': 'Shopify',
    'woocommerce': 'WooCommerce',
    'other': 'Other',
  };

  static String errorText(Object e) {
    if (e is PostgrestException) return e.message;
    if (e is FunctionException) {
      final d = e.details;
      return d is Map && d['error'] != null ? '${d['error']}' : 'Request failed (${e.status})';
    }
    final t = e.toString();
    return t.startsWith('Exception: ') ? t.substring(11) : t;
  }

  static String time(dynamic v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '' : hm.format(d.toLocal());
  }

  /// Minutes since a timestamp (for kitchen tickets and table timers).
  static int minutesSince(dynamic v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? 0 : DateTime.now().difference(d).inMinutes;
  }

  static Map<String, dynamic>? _settings;
  static Future<Map<String, dynamic>?> settings({bool refresh = false}) async {
    if (_settings != null && !refresh) return _settings;
    final s = AppSession.instance;
    try {
      _settings = await s.db.from('ext_settings').select().eq('tenant_id', s.tenantId!).maybeSingle();
    } catch (_) {}
    return _settings;
  }

  static String? webPage(String page, String query) {
    final base = (_settings?['web_base_url'] ?? '') as String;
    if (base.trim().isEmpty) return null;
    return '${base.replaceAll(RegExp(r'/+$'), '')}/$page?$query';
  }

  /// Everything that can be ordered, with option groups. Cached per session.
  static List<MenuItem>? _menu;
  static List<Map<String, dynamic>> categories = [];
  static Future<List<MenuItem>> menu({bool refresh = false}) async {
    if (_menu != null && !refresh) return _menu!;
    final s = AppSession.instance;
    final st = await settings();
    final r = await Future.wait<dynamic>([
      s.db
          .from('products')
          .select('id, name, category_id, sold_out, menu_sort, kind, product_variants(id, name, price, active), '
              'product_modifier_groups(sort_order, modifier_groups(id, name, min_select, max_select, modifiers(id, name, price_delta, active, sort_order)))')
          .eq('tenant_id', s.tenantId!)
          .eq('active', true)
          .neq('kind', 'bundle')
          .order('menu_sort')
          .order('name'),
      s.db.from('categories').select('id, name, sort_order').eq('tenant_id', s.tenantId!).order('sort_order').order('name'),
    ]);
    categories = List<Map<String, dynamic>>.from(r[1] as List);
    final hidden = {st?['service_variant_id'], st?['delivery_variant_id']};
    final out = <MenuItem>[];
    for (final p in r[0] as List) {
      final links = List<Map<String, dynamic>>.from((p['product_modifier_groups'] ?? const []) as List)
        ..sort((a, b) => ((a['sort_order'] ?? 0) as int).compareTo((b['sort_order'] ?? 0) as int));
      final groups = [
        for (final l in links)
          if (l['modifier_groups'] != null)
            ModGroup(
              l['modifier_groups']['id'] as String,
              l['modifier_groups']['name'] as String,
              (l['modifier_groups']['min_select'] ?? 0) as int,
              (l['modifier_groups']['max_select'] ?? 1) as int,
              [
                for (final m in (List<Map<String, dynamic>>.from((l['modifier_groups']['modifiers'] ?? const []) as List)
                  ..sort((a, b) => ((a['sort_order'] ?? 0) as int).compareTo((b['sort_order'] ?? 0) as int))))
                  if (m['active'] == true) (m['id'] as String, m['name'] as String, (m['price_delta'] as num).toDouble()),
              ],
            ),
      ];
      for (final v in (p['product_variants'] ?? const []) as List) {
        if (v['active'] != true || hidden.contains(v['id'])) continue;
        out.add(MenuItem(p['id'] as String, v['id'] as String, '${p['name']}${v['name'] != null && '${v['name']}'.isNotEmpty ? ' — ${v['name']}' : ''}',
            p['category_id'] as String?, (v['price'] as num).toDouble(), p['sold_out'] == true, groups));
      }
    }
    _menu = out;
    return out;
  }

  static void clearCache() {
    _menu = null;
    _settings = null;
  }
}
