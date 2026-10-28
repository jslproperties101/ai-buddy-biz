import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/catalog.dart';
import '../services/session.dart';
import 'scanner_screen.dart';

class StockScreen extends StatefulWidget {
  const StockScreen({super.key});
  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _lowOnly = false;
  String _q = '';
  String? _error;
  String? _outletId;

  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_s.outlet == null) return;
    _outletId = _s.outlet!.id;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _s.db
          .from('stock_levels')
          .select('variant_id, qty, reorder_point, bin_location, product_variants(sku, name, products(name))')
          .eq('outlet_id', _outletId!);
      final list = List<Map<String, dynamic>>.from(rows)
        ..sort((a, b) => _label(a).compareTo(_label(b)));
      setState(() => _rows = list);
    } on PostgrestException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Offline. Stock needs a connection.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _label(Map<String, dynamic> r) {
    final v = r['product_variants'];
    final p = v['products']['name'] as String;
    final n = v['name'] as String?;
    return n == null || n.isEmpty ? p : '$p — $n';
  }

  bool _isLow(Map<String, dynamic> r) =>
      r['reorder_point'] != null && (r['qty'] as num) <= (r['reorder_point'] as num);

  Future<void> _adjust(Map<String, dynamic> r) async {
    if (!_s.can('inv.stock.adjust')) return;
    var reason = 'receive';
    final qty = TextEditingController();
    final note = TextEditingController();
    final current = (r['qty'] as num).toDouble();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(_label(r)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Now: ${_fmt(current)}'),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'receive', label: Text('Receive')),
                ButtonSegment(value: 'count', label: Text('Count')),
                ButtonSegment(value: 'damage', label: Text('Damage')),
                ButtonSegment(value: 'adjust', label: Text('± Adjust')),
              ],
              selected: {reason},
              onSelectionChanged: (s) => set(() => reason = s.first),
              showSelectedIcon: false,
            ),
            TextField(
              controller: qty,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: InputDecoration(
                labelText: switch (reason) {
                  'receive' => 'Quantity received',
                  'count' => 'Counted quantity on shelf',
                  'damage' => 'Quantity damaged / lost',
                  _ => 'Change (+ or −)',
                },
              ),
            ),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final n = double.tryParse(qty.text);
    if (n == null) return;
    final change = switch (reason) {
      'receive' => n.abs(),
      'damage' => -n.abs(),
      'count' => n - current,
      _ => n,
    };
    if (change == 0) return;
    try {
      await _s.db.rpc('adjust_stock', params: {
        'p_outlet': _outletId,
        'p_variant': r['variant_id'],
        'p_qty_change': change,
        'p_reason': reason,
        'p_note': note.text.trim().isEmpty ? null : note.text.trim(),
      });
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _transfer(Map<String, dynamic> r) async {
    final others = _s.outlets.where((o) => o.id != _outletId).toList();
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add another outlet first')));
      return;
    }
    var to = others.first;
    final qty = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text('Transfer ${_label(r)}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<Outlet>(
              value: to,
              items: [for (final o in others) DropdownMenuItem(value: o, child: Text(o.name))],
              onChanged: (o) => set(() => to = o!),
              decoration: const InputDecoration(labelText: 'To'),
            ),
            TextField(
              controller: qty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Quantity'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Transfer')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final n = double.tryParse(qty.text);
    if (n == null || n <= 0) return;
    try {
      await _s.db.rpc('transfer_stock', params: {'p_from': _outletId, 'p_to': to.id, 'p_variant': r['variant_id'], 'p_qty': n});
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _scanToFind() async {
    final code = await ScannerScreen.scanOnce(context);
    if (code == null) return;
    final hit = Catalog.instance.findByCode(code);
    final row = hit == null ? null : _rows.where((r) => r['variant_id'] == hit.variant.id).firstOrNull;
    if (row == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No stock record for $code')));
      return;
    }
    await _adjust(row);
  }

  @override
  Widget build(BuildContext context) {
    if (_s.outlet?.id != _outletId && !_loading) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    final q = _q.toLowerCase();
    final list = _rows
        .where((r) => !_lowOnly || _isLow(r))
        .where((r) => q.isEmpty || _label(r).toLowerCase().contains(q) || (r['product_variants']['sku'] as String).toLowerCase().contains(q))
        .toList();
    final lowCount = _rows.where(_isLow).length;

    return Scaffold(
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search stock',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            FilterChip(
              label: Text('Low stock ($lowCount)'),
              selected: _lowOnly,
              onSelected: (v) => setState(() => _lowOnly = v),
            ),
            const Spacer(),
            Text(_s.outlet?.name ?? ''),
          ]),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: list.isEmpty
                      ? ListView(children: const [SizedBox(height: 80), Center(child: Text('Nothing here'))])
                      : ListView.builder(
                          itemCount: list.length,
                          itemBuilder: (_, i) {
                            final r = list[i];
                            final low = _isLow(r);
                            return ListTile(
                              title: Text(_label(r)),
                              subtitle: Text([
                                r['product_variants']['sku'],
                                if (r['reorder_point'] != null) 'reorder at ${_fmt((r['reorder_point'] as num).toDouble())}',
                                if (r['bin_location'] != null) 'bin ${r['bin_location']}',
                              ].join(' · ')),
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                Text(_fmt((r['qty'] as num).toDouble()),
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      color: low ? Theme.of(context).colorScheme.error : null,
                                    )),
                                if (_s.can('inv.stock.adjust') && _s.outlets.length > 1)
                                  IconButton(
                                    icon: const Icon(Icons.swap_horiz),
                                    tooltip: 'Transfer',
                                    onPressed: () => _transfer(r),
                                  ),
                              ]),
                              onTap: () => _adjust(r),
                            );
                          },
                        ),
                ),
        ),
      ]),
      floatingActionButton: _s.can('inv.stock.adjust')
          ? FloatingActionButton.extended(
              onPressed: _scanToFind,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan to count'),
            )
          : null,
    );
  }

  String _fmt(double q) => q == q.roundToDouble() ? q.toInt().toString() : q.toStringAsFixed(2);
}
