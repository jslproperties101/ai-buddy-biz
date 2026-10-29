import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

class ShiftScreen extends StatefulWidget {
  const ShiftScreen({super.key});
  @override
  State<ShiftScreen> createState() => _ShiftScreenState();
}

class _ShiftScreenState extends State<ShiftScreen> {
  final _cash = TextEditingController();
  final _note = TextEditingController();
  bool _busy = false;
  double? _expected;
  Map<String, dynamic>? _closed;

  AppSession get _s => AppSession.instance;
  NumberFormat get _money => NumberFormat.currency(symbol: '${_s.currency} ');

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    await _s.refreshShift();
    if (_s.openShiftId != null) {
      try {
        final v = await _s.db.rpc('shift_expected_cash', params: {'p_shift': _s.openShiftId});
        _expected = (v as num?)?.toDouble();
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _open() async {
    setState(() => _busy = true);
    try {
      await _s.db.rpc('open_shift', params: {'p_outlet': _s.outlet!.id, 'p_opening_cash': double.tryParse(_cash.text) ?? 0});
      _cash.clear();
      _closed = null;
      await _refresh();
    } on PostgrestException catch (e) {
      _snack(e.message);
    } catch (_) {
      _snack('Needs a connection to open a shift');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    final counted = double.tryParse(_cash.text);
    if (counted == null) {
      _snack('Count the cash in the drawer and enter the total');
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await _s.db.rpc('close_shift', params: {
        'p_shift': _s.openShiftId,
        'p_counted_cash': counted,
        'p_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      });
      _closed = Map<String, dynamic>.from(r as Map);
      _cash.clear();
      _note.clear();
      await _refresh();
    } on PostgrestException catch (e) {
      _snack(e.message);
    } catch (_) {
      _snack('Needs a connection to close a shift. Sync offline sales first.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final open = _s.openShiftId != null;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text('Shift · ${_s.outlet?.name ?? ''}')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (_closed != null) _summary(_closed!),
        Text(open ? 'Shift is open' : 'No shift open', style: t.headlineSmall),
        const SizedBox(height: 8),
        if (open) ...[
          Text('Opening cash: ${_money.format(_s.openShiftCash)}'),
          if (_expected != null) Text('Expected in drawer now: ${_money.format(_expected)}', style: t.titleMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _cash,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Cash counted in drawer', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: 'Note (optional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _close, child: const Text('Close shift')),
        ] else ...[
          TextField(
            controller: _cash,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Opening cash (float)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _open, child: const Text('Open shift')),
        ],
      ]),
    );
  }

  Widget _summary(Map<String, dynamic> r) {
    final expected = ((r['expected_cash'] ?? 0) as num).toDouble();
    final counted = ((r['counted_cash'] ?? 0) as num).toDouble();
    final diff = counted - expected;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Shift closed', style: Theme.of(context).textTheme.titleMedium),
          Text('Expected: ${_money.format(expected)}'),
          Text('Counted: ${_money.format(counted)}'),
          Text(
            diff == 0 ? 'Drawer balanced' : (diff > 0 ? 'Over by ${_money.format(diff)}' : 'Short by ${_money.format(-diff)}'),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: diff < 0 ? Theme.of(context).colorScheme.error : null,
            ),
          ),
        ]),
      ),
    );
  }
}
