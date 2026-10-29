import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'session.dart';

enum SaleOutcome { synced, queued }

class SaleResult {
  final SaleOutcome outcome;
  final String? receiptNo;
  final double? total;
  SaleResult(this.outcome, {this.receiptNo, this.total});
}

/// Sends sales to the server, or keeps them on the phone when offline and retries later.
/// Each sale carries a client_sale_id, so retrying never creates a duplicate.
class SalesQueue {
  SalesQueue._();
  static final SalesQueue instance = SalesQueue._();

  String get _key => 'pending_sales_${AppSession.instance.tenantId}';

  Future<List<Map<String, dynamic>>> pending() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    return [for (final r in raw) jsonDecode(r) as Map<String, dynamic>];
  }

  Future<void> _save(List<Map<String, dynamic>> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, [for (final i in items) jsonEncode(i)]);
  }

  /// Business errors (e.g. underpaid, not allowed) are thrown as PostgrestException.
  /// Network errors put the sale in the offline queue.
  Future<SaleResult> submit(Map<String, dynamic> payload) async {
    try {
      final res = await AppSession.instance.db.rpc('complete_sale', params: {'p': payload});
      final m = res as Map<String, dynamic>;
      return SaleResult(SaleOutcome.synced, receiptNo: m['receipt_no'] as String?, total: (m['total'] as num?)?.toDouble());
    } on PostgrestException {
      rethrow;
    } on AuthException {
      rethrow;
    } catch (_) {
      final items = await pending();
      items.add(payload);
      await _save(items);
      return SaleResult(SaleOutcome.queued);
    }
  }

  /// Returns how many queued sales were sent. Stops at the first network failure.
  /// A sale the server rejects is moved to a "failed" list so it doesn't block the rest.
  Future<int> syncAll() async {
    final items = await pending();
    if (items.isEmpty) return 0;
    var sent = 0;
    final remaining = <Map<String, dynamic>>[];
    for (var i = 0; i < items.length; i++) {
      try {
        await AppSession.instance.db.rpc('complete_sale', params: {'p': items[i]});
        sent++;
      } on PostgrestException catch (e) {
        await _addFailed(items[i], e.message);
      } catch (_) {
        remaining.addAll(items.sublist(i));
        break;
      }
    }
    await _save(remaining);
    return sent;
  }

  Future<void> _addFailed(Map<String, dynamic> sale, String error) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${_key}_failed';
    final list = prefs.getStringList(key) ?? [];
    list.add(jsonEncode({'sale': sale, 'error': error, 'at': DateTime.now().toIso8601String()}));
    await prefs.setStringList(key, list);
  }

  Future<List<Map<String, dynamic>>> failed() async {
    final prefs = await SharedPreferences.getInstance();
    return [for (final r in prefs.getStringList('${_key}_failed') ?? []) jsonDecode(r) as Map<String, dynamic>];
  }
}
