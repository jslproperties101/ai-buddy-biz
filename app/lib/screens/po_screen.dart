import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/catalog.dart';
import '../services/session.dart';

class _PoLine {
  String? id;
  Variant? variant;
  String label;
  final qty = TextEditingController(text: '1');
  final cost = TextEditingController();
  double received = 0;
  final receiveNow = TextEditingController();
  _PoLine(this.label);
}

/// Create, send and receive a purchase order.
class PoScreen extends StatefulWidget {
  final String? poId;
  final String? supplierId;
  const PoScreen({super.key, this.poId, this.supplierId});
  @override
  State<PoScreen> createState() => _PoScreenState();
}

class _PoScreenState extends State<PoScreen> {
  String? _id;
  Map<String, dynamic>? _po;
  List<Map<String, dynamic>> _suppliers = [];
  String? _supplierId;
  DateTime? _expected;
  final _notes = TextEditingController();
  final List<_PoLine> _lines = [];
  bool _loading = true;
  bool _busy = false;
  Session get _s => Session.instance;
  String get _status => (_po?['status'] ?? 'draft') as String;
  bool get _draft => _status == 'draft';
  NumberFormat get _money => NumberFormat.currency(symbol: '${_po?['currency'] ?? _s.currency} ');

  @override
  void initState() {
    super.initState();
    _id = widget.poId;
    _supplierId = widget.supplierId;
    _load();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _load() async {
    try {
      _suppliers = List<Map<String, dynamic>>.from(await _s.db
          .from('suppliers')
          .select('id, name, lead_time_days')
          .eq('tenant_id', _s.tenantId!)
          .eq('category', 'vendor')
          .eq('active', true)
          .order('name'));
      if (_id != null) {
        _po = await _s.db.from('po_list').select().eq('id', _id!).single();
        _supplierId = _po!['supplier_id'] as String;
        _expected = _po!['expected_at'] == null ? null : DateTime.parse(_po!['expected_at'] as String);
        _notes.text = (_po!['notes'] ?? '') as String;
        final rows = await _s.db
            .from('purchase_order_lines')
            .select('*, product_variants(id, sku, name, products(name))')
            .eq('po_id', _id!);
        _lines.clear();
        for (final r in rows) {
          final pv = r['product_variants'];
          final name = pv['products']['name'] as String;
          final l = _PoLine('${pv['sku']} · $name${pv['name'] != null ? ' — ${pv['name']}' : ''}')
            ..id = r['id'] as String
            ..variant = Catalog.instance.variants.where((v) => v.id == pv['id']).firstOrNull
            ..received = (r['qty_received'] as num).toDouble();
          l.qty.text = _n(r['qty_ordered']);
          l.cost.text = (r['unit_cost'] as num).toString();
          final left = (r['qty_ordered'] as num) - (r['qty_received'] as num);
          l.receiveNow.text = left > 0 ? _n(left) : '';
          l.variant ??= Variant(
              id: pv['id'] as String, productId: '', productName: name, name: pv['name'] as String?, sku: pv['sku'] as String,
              price: 0, cost: 0, trackStock: true, barcodes: const []);
          _lines.add(l);
        }
      }
    } catch (e) {
      _snack('Could not load: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  String _n(dynamic v) {
    final d = (v as num).toDouble();
    return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
  }

  double get _total => _lines.fold<double>(0.0, (a, l) => a + (double.tryParse(l.qty.text) ?? 0) * (double.tryParse(l.cost.text) ?? 0));

  Future<void> _addLine() async {
    final v = await showModalBottomSheet<Variant>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _VariantPicker(),
    );
    if (v == null) return;
    setState(() {
      final l = _PoLine('${v.sku} · ${v.displayName}')..variant = v;
      l.cost.text = v.cost == 0 ? '' : v.cost.toString();
      _lines.add(l);
    });
  }

  Future<bool> _saveDraft() async {
    if (_supplierId == null) {
      _snack('Choose a supplier');
      return false;
    }
    if (_lines.isEmpty) {
      _snack('Add at least one item');
      return false;
    }
    for (final l in _lines) {
      if ((double.tryParse(l.qty.text) ?? 0) <= 0 || double.tryParse(l.cost.text) == null) {
        _snack('Enter quantity and cost for ${l.label}');
        return false;
      }
    }
    if (_s.outlet == null) {
      _snack('Choose an outlet to receive into');
      return false;
    }
    setState(() => _busy = true);
    try {
      final header = {
        'tenant_id': _s.tenantId,
        'supplier_id': _supplierId,
        'outlet_id': _po?['outlet_id'] ?? _s.outlet!.id,
        'expected_at': _expected == null ? null : DateFormat('yyyy-MM-dd').format(_expected!),
        'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      };
      if (_id == null) {
        final r = await _s.db.from('purchase_orders').insert(header).select('id').single();
        _id = r['id'] as String;
      } else {
        await _s.db.from('purchase_orders').update(header).eq('id', _id!);
        await _s.db.from('purchase_order_lines').delete().eq('po_id', _id!);
      }
      await _s.db.from('purchase_order_lines').insert([
        for (final l in _lines)
          {
            'tenant_id': _s.tenantId,
            'po_id': _id,
            'variant_id': l.variant!.id,
            'qty_ordered': double.parse(l.qty.text),
            'unit_cost': double.parse(l.cost.text),
          }
      ]);
      return true;
    } on PostgrestException catch (e) {
      _snack(e.message);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    if (!await _saveDraft()) return;
    try {
      await _s.db.rpc('send_po', params: {'p_po': _id});
      _snack('Marked as sent. Share it with the supplier from your email or WhatsApp.');
      setState(() => _loading = true);
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _receive() async {
    final lines = [
      for (final l in _lines)
        if ((double.tryParse(l.receiveNow.text) ?? 0) > 0)
          {'line_id': l.id, 'qty': double.parse(l.receiveNow.text), 'unit_cost': double.tryParse(l.cost.text)}
    ];
    if (lines.isEmpty) {
      _snack('Enter quantities received');
      return;
    }
    setState(() => _busy = true);
    try {
      final st = await _s.db.rpc('receive_po', params: {'p_po': _id, 'p_lines': lines});
      _snack(st == 'received' ? 'All received — stock and costs updated' : 'Partly received — stock updated');
      setState(() => _loading = true);
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    await _s.db.from('purchase_orders').update({'status': 'cancelled'}).eq('id', _id!);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final receiving = _status == 'sent' || _status == 'partial';
    return Scaffold(
      appBar: AppBar(
        title: Text(_po?['number'] as String? ?? 'New purchase order'),
        actions: [if (_draft) TextButton(onPressed: _busy ? null : () async { if (await _saveDraft()) _snack('Saved'); }, child: const Text('Save'))],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (_po != null) Chip(label: Text('${_status.toUpperCase()}${_po!['late'] == true ? ' · LATE' : ''}')),
              DropdownButtonFormField<String>(
                value: _suppliers.any((s) => s['id'] == _supplierId) ? _supplierId : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Supplier'),
                items: [for (final s in _suppliers) DropdownMenuItem(value: s['id'] as String, child: Text(s['name'] as String))],
                onChanged: !_draft
                    ? null
                    : (v) => setState(() {
                          _supplierId = v;
                          final lt = _suppliers.firstWhere((s) => s['id'] == v)['lead_time_days'] as int?;
                          if (_expected == null && lt != null) _expected = DateTime.now().add(Duration(days: lt));
                        }),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Expected delivery'),
                subtitle: Text(_expected == null ? '—' : DateFormat('d MMM yyyy').format(_expected!)),
                onTap: !_draft
                    ? null
                    : () async {
                        final d = await showDatePicker(context: context, initialDate: _expected ?? DateTime.now().add(const Duration(days: 7)), firstDate: DateTime.now().subtract(const Duration(days: 30)), lastDate: DateTime.now().add(const Duration(days: 365)));
                        if (d != null) setState(() => _expected = d);
                      },
              ),
              Text('Receives into ${_po?['outlet_name'] ?? _s.outlet?.name ?? '—'}', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              Text('Items', style: Theme.of(context).textTheme.titleMedium),
              for (var i = 0; i < _lines.length; i++)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(_lines[i].label)),
                        if (_draft) IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => setState(() => _lines.removeAt(i))),
                      ]),
                      Row(children: [
                        Expanded(child: TextField(controller: _lines[i].qty, enabled: _draft, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Qty ordered', isDense: true), onChanged: (_) => setState(() {}))),
                        const SizedBox(width: 8),
                        Expanded(child: TextField(controller: _lines[i].cost, enabled: _draft || receiving, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Unit cost', isDense: true), onChanged: (_) => setState(() {}))),
                        if (receiving) ...[
                          const SizedBox(width: 8),
                          Expanded(child: TextField(controller: _lines[i].receiveNow, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Receive now', isDense: true))),
                        ],
                      ]),
                      if (!_draft) Text('Received ${_n(_lines[i].received)} of ${_lines[i].qty.text}', style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ),
                ),
              if (_draft) OutlinedButton.icon(onPressed: _addLine, icon: const Icon(Icons.add), label: const Text('Add item')),
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerRight, child: Text('Total ${_money.format(_total)}', style: Theme.of(context).textTheme.titleMedium)),
              TextField(controller: _notes, enabled: _draft, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes for supplier')),
              const SizedBox(height: 16),
              if (_draft) FilledButton.icon(onPressed: _busy ? null : _send, icon: const Icon(Icons.send), label: const Text('Mark as sent')),
              if (receiving && _s.can('inv.stock.adjust'))
                FilledButton.icon(onPressed: _busy ? null : _receive, icon: const Icon(Icons.inventory), label: const Text('Receive goods')),
              if (receiving)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Receiving adds stock, updates average cost and records the amount owed to the supplier.', style: TextStyle(fontSize: 12)),
                ),
              if (_id != null && (_draft || _status == 'sent')) TextButton(onPressed: _cancel, child: const Text('Cancel PO')),
              const SizedBox(height: 40),
            ]),
    );
  }
}

class _VariantPicker extends StatefulWidget {
  @override
  State<_VariantPicker> createState() => _VariantPickerState();
}

class _VariantPickerState extends State<_VariantPicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final list = Catalog.instance.search(_q).where((v) => v.trackStock).take(60).toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Search stock items', prefixIcon: Icon(Icons.search)),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: ListView(children: [
              for (final v in list)
                ListTile(title: Text(v.displayName), subtitle: Text('${v.sku} · cost ${v.cost}'), onTap: () => Navigator.pop(context, v)),
              if (list.isEmpty) const ListTile(title: Text('No stock items. Add products first (Catalog), then sync.')),
            ]),
          ),
        ]),
      ),
    );
  }
}
