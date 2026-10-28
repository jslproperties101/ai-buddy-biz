import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

enum _Range { today, week, month, lastMonth, year }

class _ReportsScreenState extends State<ReportsScreen> with SingleTickerProviderStateMixin {
  _Range _range = _Range.today;
  bool _allOutlets = false;
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _sales;
  Map<String, dynamic>? _pnl;
  List<Map<String, dynamic>> _tax = [];
  List<Map<String, dynamic>> _tb = [];

  Session get _s => Session.instance;
  NumberFormat get _money => NumberFormat.currency(symbol: '${_s.currency} ');
  final _d = DateFormat('yyyy-MM-dd');

  late final List<(String, bool)> _tabs = [
    ('Sales', _s.can('pos.report.view') || _s.can('fin.report.view')),
    ('Profit & loss', _s.can('fin.report.view')),
    ('Tax', _s.can('fin.report.view')),
    ('Trial balance', _s.can('fin.ledger.view')),
  ].where((t) => t.$2).toList();

  late final TabController _tc = TabController(length: _tabs.length, vsync: this);

  (DateTime, DateTime) get _dates {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (_range) {
      _Range.today => (today, today),
      _Range.week => (today.subtract(const Duration(days: 6)), today),
      _Range.month => (DateTime(now.year, now.month, 1), today),
      _Range.lastMonth => (DateTime(now.year, now.month - 1, 1), DateTime(now.year, now.month, 0)),
      _Range.year => (DateTime(now.year, 1, 1), today),
    };
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final (from, to) = _dates;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final t = _s.tenantId!;
      if (_tabs.any((x) => x.$1 == 'Sales')) {
        _sales = Map<String, dynamic>.from(await _s.db.rpc('sales_summary', params: {
          'p_tenant': t,
          'p_from': _d.format(from),
          'p_to': _d.format(to),
          'p_outlet': _allOutlets ? null : _s.outlet?.id,
        }) as Map);
      }
      if (_s.can('fin.report.view')) {
        _pnl = Map<String, dynamic>.from(await _s.db
            .rpc('profit_and_loss', params: {'p_tenant': t, 'p_from': _d.format(from), 'p_to': _d.format(to)}) as Map);
        _tax = List<Map<String, dynamic>>.from(await _s.db
            .rpc('tax_report', params: {'p_tenant': t, 'p_from': _d.format(from), 'p_to': _d.format(to)}) as List);
      }
      if (_s.can('fin.ledger.view')) {
        _tb = List<Map<String, dynamic>>.from(
            await _s.db.rpc('trial_balance', params: {'p_tenant': t, 'p_as_of': _d.format(to)}) as List);
      }
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Reports need a connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        bottom: TabBar(controller: _tc, isScrollable: true, tabs: [for (final t in _tabs) Tab(text: t.$1)]),
      ),
      body: Column(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(children: [
            for (final r in _Range.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(switch (r) {
                    _Range.today => 'Today',
                    _Range.week => '7 days',
                    _Range.month => 'This month',
                    _Range.lastMonth => 'Last month',
                    _Range.year => 'This year',
                  }),
                  selected: _range == r,
                  onSelected: (_) {
                    setState(() => _range = r);
                    _load();
                  },
                ),
              ),
            if (_s.outlets.length > 1)
              FilterChip(
                label: const Text('All outlets'),
                selected: _allOutlets,
                onSelected: (v) {
                  setState(() => _allOutlets = v);
                  _load();
                },
              ),
          ]),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(controller: _tc, children: [
                  for (final t in _tabs)
                    switch (t.$1) {
                      'Sales' => _salesView(),
                      'Profit & loss' => _pnlView(),
                      'Tax' => _taxView(),
                      _ => _tbView(),
                    }
                ]),
        ),
      ]),
    );
  }

  Widget _kpi(String label, String value) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              FittedBox(child: Text(value, style: Theme.of(context).textTheme.titleLarge)),
            ]),
          ),
        ),
      );

  Widget _salesView() {
    final s = _sales;
    if (s == null) return const SizedBox();
    final count = (s['count'] as num).toInt();
    final total = (s['total'] as num).toDouble();
    return ListView(padding: const EdgeInsets.all(12), children: [
      Row(children: [
        _kpi('Sales', _money.format(total)),
        _kpi('Receipts', '$count'),
      ]),
      Row(children: [
        _kpi('Average', _money.format(count == 0 ? 0 : total / count)),
        _kpi('Tax', _money.format(s['tax'])),
      ]),
      if ((s['discount'] as num) > 0 || (s['voided'] as num) > 0)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('Discounts ${_money.format(s['discount'])} · Voided receipts ${s['voided']}'),
        ),
      const SizedBox(height: 8),
      Text('By payment method', style: Theme.of(context).textTheme.titleMedium),
      for (final m in (s['by_method'] as List))
        ListTile(dense: true, title: Text(m['method'] as String), trailing: Text(_money.format(m['amount']))),
      const SizedBox(height: 8),
      Text('By day', style: Theme.of(context).textTheme.titleMedium),
      ..._bars([
        for (final d in (s['by_day'] as List)) (d['day'] as String, (d['total'] as num).toDouble(), '${d['count']} sales')
      ]),
      const SizedBox(height: 8),
      Text('Top items', style: Theme.of(context).textTheme.titleMedium),
      for (final i in (s['top_items'] as List))
        ListTile(
          dense: true,
          title: Text(i['name'] as String),
          subtitle: Text('${i['sku']} · qty ${i['qty']}'),
          trailing: Text(_money.format(i['revenue'])),
        ),
    ]);
  }

  List<Widget> _bars(List<(String, double, String)> rows) {
    if (rows.isEmpty) return [const Padding(padding: EdgeInsets.all(8), child: Text('No sales in this period'))];
    final max = rows.map((r) => r.$2).reduce((a, b) => a > b ? a : b);
    final color = Theme.of(context).colorScheme.primary;
    return [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            SizedBox(width: 84, child: Text(r.$1.substring(5), style: Theme.of(context).textTheme.bodySmall)),
            Expanded(
              child: LayoutBuilder(
                builder: (_, c) => Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    height: 18,
                    width: max == 0 ? 0 : c.maxWidth * (r.$2 / max),
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(width: 96, child: Text(_money.format(r.$2), textAlign: TextAlign.right)),
          ]),
        ),
    ];
  }

  Widget _pnlView() {
    final p = _pnl;
    if (p == null) return const SizedBox();
    final income = (p['income'] as num).toDouble();
    final cogs = (p['cogs'] as num).toDouble();
    final net = (p['net'] as num).toDouble();
    return ListView(padding: const EdgeInsets.all(12), children: [
      Row(children: [
        _kpi('Income', _money.format(income)),
        _kpi('Net profit', _money.format(net)),
      ]),
      Row(children: [
        _kpi('Gross margin', income == 0 ? '—' : '${((income - cogs) / income * 100).toStringAsFixed(1)}%'),
        _kpi('Expenses', _money.format(p['expenses'])),
      ]),
      const SizedBox(height: 8),
      for (final l in (p['lines'] as List))
        ListTile(
          dense: true,
          leading: Text(l['code'] as String),
          title: Text(l['name'] as String),
          trailing: Text(_money.format(l['type'] == 'income' ? l['amount'] : -(l['amount'] as num))),
        ),
      const Divider(),
      ListTile(
        title: const Text('Net profit', style: TextStyle(fontWeight: FontWeight.bold)),
        trailing: Text(_money.format(net), style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    ]);
  }

  Widget _taxView() {
    final total = _tax.fold<double>(0.0, (a, r) => a + (r['tax'] as num).toDouble());
    return ListView(padding: const EdgeInsets.all(12), children: [
      _kpi('Tax collected', _money.format(total)),
      const SizedBox(height: 8),
      if (_tax.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No taxable sales in this period')),
      for (final r in _tax)
        ListTile(
          title: Text(r['tax_name'] as String),
          subtitle: Text('${r['source']} · taxable ${_money.format(r['taxable'])}'),
          trailing: Text(_money.format(r['tax'])),
        ),
      const Padding(
        padding: EdgeInsets.all(8),
        child: Text('Use this to fill your SST / GST / VAT return. Check the figures with your accountant.',
            style: TextStyle(fontSize: 12)),
      ),
    ]);
  }

  Widget _tbView() {
    final rows = _tb.where((r) => (r['debit'] as num) != 0 || (r['credit'] as num) != 0).toList();
    final dr = rows.fold<double>(0.0, (a, r) => a + (r['debit'] as num).toDouble());
    final cr = rows.fold<double>(0.0, (a, r) => a + (r['credit'] as num).toDouble());
    return ListView(padding: const EdgeInsets.all(12), children: [
      Text('As of ${_d.format(_dates.$2)} · all time', style: Theme.of(context).textTheme.bodySmall),
      for (final r in rows)
        ListTile(
          dense: true,
          leading: Text(r['code'] as String),
          title: Text(r['name'] as String),
          subtitle: Text(r['type'] as String),
          trailing: Text(_money.format(r['balance'])),
        ),
      const Divider(),
      ListTile(
        title: Text(dr.toStringAsFixed(2) == cr.toStringAsFixed(2) ? 'Balanced ✓' : 'Out of balance'),
        subtitle: Text('Debits ${_money.format(dr)} · Credits ${_money.format(cr)}'),
      ),
    ]);
  }
}
