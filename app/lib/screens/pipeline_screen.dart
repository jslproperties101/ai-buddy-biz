import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';
import 'contact_screen.dart';
import 'deal_sheet.dart';

/// Sales pipeline as a board: one column per stage, swipe sideways between stages.
class PipelineScreen extends StatefulWidget {
  const PipelineScreen({super.key});
  @override
  State<PipelineScreen> createState() => _PipelineScreenState();
}

class _PipelineScreenState extends State<PipelineScreen> {
  List<Map<String, dynamic>> _stages = [];
  List<Map<String, dynamic>> _deals = [];
  bool _loading = true;
  bool _mine = false;
  String? _error;

  Session get _s => Session.instance;
  NumberFormat get _money => NumberFormat.compactCurrency(symbol: '${_s.currency} ');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final p = await _s.db
          .from('pipelines')
          .select('id')
          .eq('tenant_id', _s.tenantId!)
          .order('is_default', ascending: false)
          .limit(1)
          .maybeSingle();
      if (p == null) {
        _error = 'No pipeline yet. Add your first customer to set one up.';
      } else {
        final st = await _s.db.from('pipeline_stages').select().eq('pipeline_id', p['id'] as String).order('sort_order');
        var q = _s.db
            .from('deals')
            .select('*, contacts(id, name, company)')
            .eq('pipeline_id', p['id'] as String)
            .or('status.eq.open,closed_at.gte.${DateFormat('yyyy-MM-dd').format(DateTime.now().subtract(const Duration(days: 30)))}');
        if (_mine) q = q.eq('owner_id', _s.db.auth.currentUser!.id);
        final ds = await q.order('updated_at', ascending: false);
        _stages = List<Map<String, dynamic>>.from(st);
        _deals = List<Map<String, dynamic>>.from(ds);
        _error = null;
      }
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'The pipeline needs a connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _move(Map<String, dynamic> deal) async {
    final to = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text('Move "${deal['title']}" to…', style: Theme.of(context).textTheme.titleMedium)),
          for (final s in _stages)
            ListTile(
              leading: Icon(s['kind'] == 'won'
                  ? Icons.emoji_events_outlined
                  : s['kind'] == 'lost'
                      ? Icons.cancel_outlined
                      : Icons.circle_outlined),
              title: Text(s['name'] as String),
              trailing: s['id'] == deal['stage_id'] ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, s),
            ),
        ]),
      ),
    );
    if (to == null || to['id'] == deal['stage_id']) return;
    String? reason;
    if (to['kind'] == 'lost') {
      final c = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Why was it lost?'),
          content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'e.g. price, timing, competitor')),
          actions: [FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save'))],
        ),
      );
      if (ok != true) return;
      reason = c.text.trim().isEmpty ? null : c.text.trim();
    }
    try {
      await _s.db.from('deals').update({'stage_id': to['id'], 'lost_reason': reason}).eq('id', deal['id'] as String);
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = _deals.where((d) => d['status'] == 'open');
    final weighted = open.fold<double>(0.0, (a, d) {
      final st = _stages.where((s) => s['id'] == d['stage_id']).firstOrNull;
      return a + (d['value'] as num).toDouble() * ((st?['probability'] ?? 0) as int) / 100;
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pipeline'),
        actions: [
          FilterChip(
            label: const Text('Mine'),
            selected: _mine,
            onSelected: (v) {
              setState(() => _mine = v);
              _load();
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: _s.can('crm.deal.manage')
          ? FloatingActionButton.extended(
              onPressed: () async {
                if (await DealSheet.show(context)) _load();
              },
              icon: const Icon(Icons.add),
              label: const Text('Deal'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(children: [
                      Text('${open.length} open · ${_money.format(open.fold<double>(0.0, (a, d) => a + (d['value'] as num).toDouble()))}'),
                      const Spacer(),
                      Text('Forecast ${_money.format(weighted)}', style: Theme.of(context).textTheme.titleSmall),
                    ]),
                  ),
                  Expanded(
                    child: PageView(
                      controller: PageController(viewportFraction: 0.88),
                      children: [for (final s in _stages) _column(s)],
                    ),
                  ),
                ]),
    );
  }

  Widget _column(Map<String, dynamic> stage) {
    final deals = _deals.where((d) => d['stage_id'] == stage['id']).toList();
    final total = deals.fold<double>(0.0, (a, d) => a + (d['value'] as num).toDouble());
    final c = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(6, 6, 6, 80),
      color: stage['kind'] == 'won'
          ? c.primaryContainer
          : stage['kind'] == 'lost'
              ? c.surfaceContainerHighest
              : c.surfaceContainerLow,
      child: Column(children: [
        ListTile(
          title: Text(stage['name'] as String, style: Theme.of(context).textTheme.titleMedium),
          subtitle: Text('${deals.length} · ${_money.format(total)}${stage['kind'] == 'open' ? ' · ${stage['probability']}%' : ' · last 30 days'}'),
        ),
        Expanded(
          child: deals.isEmpty
              ? const Center(child: Text('Nothing here'))
              : ListView(padding: const EdgeInsets.symmetric(horizontal: 8), children: [
                  for (final d in deals)
                    Card(
                      child: ListTile(
                        title: Text(d['title'] as String),
                        subtitle: Text([
                          if (d['contacts'] != null) (d['contacts']['company'] ?? d['contacts']['name']),
                          if (d['expected_close'] != null) 'close ${d['expected_close']}',
                          if (d['lost_reason'] != null) d['lost_reason'],
                        ].join(' · ')),
                        trailing: Text(_money.format(d['value'])),
                        onTap: _s.can('crm.deal.manage') ? () => _move(d) : null,
                        onLongPress: () async {
                          if (d['contacts'] != null) {
                            await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => ContactScreen(contactId: d['contacts']['id'] as String)));
                          } else if (await DealSheet.show(context, deal: d)) {
                            _load();
                          }
                        },
                      ),
                    ),
                ]),
        ),
      ]),
    );
  }
}
