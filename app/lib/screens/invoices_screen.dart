import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';
import 'invoice_edit_screen.dart';

class InvoicesScreen extends StatefulWidget {
  const InvoicesScreen({super.key});
  @override
  State<InvoicesScreen> createState() => _InvoicesScreenState();
}

class _InvoicesScreenState extends State<InvoicesScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  String _filter = 'open';

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
          .from('invoice_list')
          .select('id, number, status, contact_name, issue_date, due_date, total, balance, overdue, created_at')
          .eq('tenant_id', _s.tenantId!);
      q = switch (_filter) {
        'open' => q.inFilter('status', ['issued', 'partial']),
        'overdue' => q.eq('overdue', true),
        'draft' => q.eq('status', 'draft'),
        'paid' => q.eq('status', 'paid'),
        _ => q,
      };
      final rows = await q.order('created_at', ascending: false).limit(200);
      setState(() => _rows = List<Map<String, dynamic>>.from(rows));
    } on PostgrestException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Offline. Invoices need a connection.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open([String? id]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => InvoiceEditScreen(invoiceId: id)));
    await _load();
  }

  Color? _statusColor(Map<String, dynamic> r) {
    final c = Theme.of(context).colorScheme;
    if (r['overdue'] == true) return c.error;
    return switch (r['status']) {
      'paid' => c.primary,
      'void' => c.outline,
      'draft' => c.tertiary,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final owed = _rows
        .where((r) => r['status'] == 'issued' || r['status'] == 'partial')
        .fold<double>(0.0, (a, r) => a + (r['balance'] as num).toDouble());
    return Scaffold(
      body: Column(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(children: [
            for (final f in const [('open', 'Unpaid'), ('overdue', 'Overdue'), ('draft', 'Drafts'), ('paid', 'Paid'), ('all', 'All')])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(f.$2),
                  selected: _filter == f.$1,
                  onSelected: (_) {
                    setState(() => _filter = f.$1);
                    _load();
                  },
                ),
              ),
          ]),
        ),
        if (_filter == 'open' || _filter == 'overdue')
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              Text('Owed to you: ', style: Theme.of(context).textTheme.bodyMedium),
              Text(_money.format(owed), style: Theme.of(context).textTheme.titleMedium),
            ]),
          ),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _rows.isEmpty
                      ? ListView(children: const [SizedBox(height: 80), Center(child: Text('No invoices here'))])
                      : ListView.builder(
                          itemCount: _rows.length,
                          itemBuilder: (_, i) {
                            final r = _rows[i];
                            final label = r['overdue'] == true ? 'OVERDUE' : (r['status'] as String).toUpperCase();
                            return ListTile(
                              title: Text(r['contact_name'] as String? ?? 'No customer'),
                              subtitle: Text([
                                r['number'] ?? 'Draft',
                                if (r['due_date'] != null) 'due ${r['due_date']}',
                              ].join(' · ')),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(_money.format(r['status'] == 'paid' || r['status'] == 'void' ? r['total'] : r['balance'])),
                                  Text(label, style: TextStyle(fontSize: 11, color: _statusColor(r))),
                                ],
                              ),
                              onTap: () => _open(r['id'] as String),
                            );
                          },
                        ),
                ),
        ),
      ]),
      floatingActionButton: _s.can('fin.invoice.manage')
          ? FloatingActionButton.extended(heroTag: null, onPressed: () => _open(), icon: const Icon(Icons.add), label: const Text('Invoice'))
          : null,
    );
  }
}
