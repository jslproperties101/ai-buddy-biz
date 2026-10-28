import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/printing_service.dart';
import '../services/session.dart';

class SalesHistoryScreen extends StatefulWidget {
  const SalesHistoryScreen({super.key});
  @override
  State<SalesHistoryScreen> createState() => _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends State<SalesHistoryScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  final _search = TextEditingController();

  Session get _s => Session.instance;
  NumberFormat get _money => NumberFormat.currency(symbol: '${_s.currency} ');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var q = _s.db
          .from('sales')
          .select('id, receipt_no, status, subtotal, discount_total, tax_total, total, sold_at, note, '
              'sale_lines(name, qty, unit_price, discount, tax_name, tax_amount, line_total), payments(method, amount)')
          .eq('tenant_id', _s.tenantId!);
      if (_s.outlet != null) q = q.eq('outlet_id', _s.outlet!.id);
      final term = _search.text.trim();
      if (term.isNotEmpty) q = q.ilike('receipt_no', '%$term%');
      final rows = await q.order('sold_at', ascending: false).limit(100);
      setState(() => _rows = List<Map<String, dynamic>>.from(rows));
    } on PostgrestException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Offline. Sales history needs a connection.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _void(Map<String, dynamic> sale) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Void ${sale['receipt_no']}?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Stock goes back and the sale is reversed in the accounts. This cannot be undone.'),
          TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason (required)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Void sale')),
        ],
      ),
    );
    if (ok != true) return;
    if (reason.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('A reason is required')));
      return;
    }
    try {
      await _s.db.rpc('void_sale', params: {'p_sale_id': sale['id'], 'p_reason': reason.text.trim()});
      if (mounted) Navigator.of(context).pop();
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _reprint(Map<String, dynamic> sale) {
    final lines = [
      for (final l in (sale['sale_lines'] as List))
        (
          l['name'] as String,
          (l['qty'] as num).toDouble(),
          (l['unit_price'] as num).toDouble(),
          (l['discount'] as num).toDouble(),
        )
    ];
    final pays = sale['payments'] as List;
    final paid = pays.fold<double>(0.0, (a, p) => a + (p['amount'] as num).toDouble());
    PrintingService.printReceipt(
      receiptNo: sale['receipt_no'] as String,
      lines: lines,
      subtotal: (sale['subtotal'] as num).toDouble(),
      discount: (sale['discount_total'] as num).toDouble(),
      tax: (sale['tax_total'] as num).toDouble(),
      total: (sale['total'] as num).toDouble(),
      paidMethod: pays.isEmpty ? '-' : pays.map((p) => p['method']).join('+'),
      paid: paid,
    );
  }

  void _open(Map<String, dynamic> sale) {
    final voided = sale['status'] != 'completed';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Receipt ${sale['receipt_no']}', style: Theme.of(context).textTheme.titleLarge),
            Text(DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(sale['sold_at'] as String).toLocal())),
            if (voided) Text(sale['status'].toString().toUpperCase(), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const Divider(),
            for (final l in (sale['sale_lines'] as List))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(l['name'] as String),
                subtitle: Text('${l['qty']} × ${_money.format(l['unit_price'])}'
                    '${(l['tax_name'] ?? '') != '' ? ' · ${l['tax_name']}' : ''}'),
                trailing: Text(_money.format(l['line_total'])),
              ),
            const Divider(),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Total', style: TextStyle(fontWeight: FontWeight.bold)),
              Text(_money.format(sale['total']), style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            for (final p in (sale['payments'] as List))
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('Paid ${p['method']}'),
                Text(_money.format(p['amount'])),
              ]),
            if (sale['note'] != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(sale['note'] as String)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => _reprint(sale), child: const Text('Reprint'))),
              if (!voided && _s.can('pos.sale.void')) ...[
                const SizedBox(width: 12),
                Expanded(child: FilledButton.tonal(onPressed: () => _void(sale), child: const Text('Void'))),
              ],
            ]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sales history')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _search,
            decoration: const InputDecoration(
              hintText: 'Receipt number',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _load(),
          ),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: _rows.length,
                    itemBuilder: (_, i) {
                      final r = _rows[i];
                      final voided = r['status'] != 'completed';
                      return ListTile(
                        title: Text(r['receipt_no'] as String,
                            style: TextStyle(decoration: voided ? TextDecoration.lineThrough : null)),
                        subtitle: Text(
                            '${DateFormat('d MMM HH:mm').format(DateTime.parse(r['sold_at'] as String).toLocal())} · '
                            '${(r['sale_lines'] as List).length} item(s)${voided ? ' · ${r['status']}' : ''}'),
                        trailing: Text(_money.format(r['total'])),
                        onTap: () => _open(r),
                      );
                    },
                  ),
                ),
        ),
      ]),
    );
  }
}
