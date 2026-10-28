import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/crm.dart';
import '../services/session.dart';
import '../widgets/contact_picker.dart';
import '../widgets/timeline.dart';
import 'contact_screen.dart';

const _reasonLabels = {
  'stage': 'Pipeline stage',
  'has_phone': 'Has phone',
  'has_email': 'Has email',
  'existing_customer': 'Already a customer',
  'consented': 'Agreed to offers',
  'recent_activity': 'Contacted this week',
  'engagement': 'Engagement',
  'above_avg_value': 'Above-average value',
  'closing_soon': 'Closing within 30 days',
  'no_contact_14d': 'No contact for 14+ days',
  'past_close_date': 'Past expected close date',
};

class DealScreen extends StatefulWidget {
  final String? dealId;
  final String? contactId; // for new deals started from a customer
  final String? contactName;
  const DealScreen({super.key, this.dealId, this.contactId, this.contactName});
  @override
  State<DealScreen> createState() => _DealScreenState();
}

class _DealScreenState extends State<DealScreen> {
  String? _id;
  Map<String, dynamic>? _d;
  List<Map<String, dynamic>> _stages = [];
  final _title = TextEditingController();
  final _value = TextEditingController();
  String? _contactId;
  String? _contactName;
  String? _contactPhone;
  String? _stageId;
  DateTime? _close;
  bool _loading = true;
  bool _busy = false;

  Session get _s => Session.instance;
  bool get _canEdit => _s.can('crm.deal.manage');
  NumberFormat get _money => NumberFormat.currency(symbol: '${_s.currency} ');

  @override
  void initState() {
    super.initState();
    _id = widget.dealId;
    _contactId = widget.contactId;
    _contactName = widget.contactName;
    _load();
  }

  Future<void> _load() async {
    try {
      _stages = List<Map<String, dynamic>>.from(await _s.db
          .from('pipeline_stages')
          .select('id, name, kind, probability, pipeline_id, pipelines!inner(is_default)')
          .eq('tenant_id', _s.tenantId!)
          .eq('pipelines.is_default', true)
          .order('sort_order'));
      if (_id != null) {
        _d = await _s.db.from('deal_board').select().eq('id', _id!).single();
        _title.text = _d!['title'] as String;
        _value.text = (_d!['value'] as num) == 0 ? '' : (_d!['value'] as num).toStringAsFixed(2);
        _contactId = _d!['contact_id'] as String?;
        _contactName = _d!['contact_name'] as String?;
        _contactPhone = _d!['contact_phone'] as String?;
        _stageId = _d!['stage_id'] as String;
        _close = _d!['expected_close'] == null ? null : DateTime.parse(_d!['expected_close'] as String);
      } else {
        _stageId = _stages.where((s) => s['kind'] == 'open').firstOrNull?['id'] as String?;
      }
    } catch (e) {
      _snack('Could not load: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _save({String? stageId, String? lostReason}) async {
    if (_title.text.trim().isEmpty) {
      _snack('Give the lead a title, e.g. "50 units bulk order"');
      return;
    }
    final stage = stageId ?? _stageId;
    final pipelineId = _stages.firstWhere((s) => s['id'] == stage)['pipeline_id'];
    setState(() => _busy = true);
    try {
      final data = {
        'tenant_id': _s.tenantId,
        'pipeline_id': pipelineId,
        'stage_id': stage,
        'contact_id': _contactId,
        'title': _title.text.trim(),
        'value': double.tryParse(_value.text) ?? 0,
        'currency': _s.currency,
        'expected_close': _close == null ? null : DateFormat('yyyy-MM-dd').format(_close!),
        if (lostReason != null) 'lost_reason': lostReason,
      };
      if (_id == null) {
        final r = await _s.db.from('deals').insert({...data, 'source': 'manual'}).select('id').single();
        _id = r['id'] as String;
      } else {
        await _s.db.from('deals').update(data).eq('id', _id!);
      }
      setState(() => _loading = true);
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _won() async {
    final st = _stages.where((s) => s['kind'] == 'won').firstOrNull;
    if (st != null) await _save(stageId: st['id'] as String);
  }

  Future<void> _lost() async {
    final st = _stages.where((s) => s['kind'] == 'lost').firstOrNull;
    if (st == null) return;
    String? reason;
    final other = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Why was it lost?'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final r in const ['Price', 'Chose a competitor', 'No budget', 'No response', 'Timing', 'Other'])
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                value: r,
                groupValue: reason,
                title: Text(r),
                onChanged: (v) => set(() => reason = v),
              ),
            if (reason == 'Other') TextField(controller: other, decoration: const InputDecoration(labelText: 'Reason')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: reason == null ? null : () => Navigator.pop(context, true), child: const Text('Mark lost')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _save(stageId: st['id'] as String, lostReason: reason == 'Other' ? (other.text.trim().isEmpty ? 'Other' : other.text.trim()) : reason);
  }

  Future<void> _pickContact() async {
    final c = await ContactPicker.show(context);
    if (c == null) return;
    setState(() {
      _contactId = c['id'] as String;
      _contactName = c['name'] as String;
      _contactPhone = c['phone'] as String?;
      if (_title.text.isEmpty) _title.text = 'Enquiry from ${c['name']}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final status = d?['status'] as String? ?? 'open';
    final reasons = ((d?['score_reasons'] as List?) ?? []).cast<Map<String, dynamic>>();
    return Scaffold(
      appBar: AppBar(
        title: Text(_id == null ? 'New lead' : 'Lead'),
        actions: [
          if (_canEdit) TextButton(onPressed: _busy || _loading ? null : () => _save(), child: const Text('Save')),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (d != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text(status == 'open' ? 'Score ${d['score']}/100' : status.toUpperCase(),
                            style: Theme.of(context).textTheme.titleLarge),
                        const Spacer(),
                        if (d['lost_reason'] != null) Text(d['lost_reason'] as String),
                      ]),
                      if (status == 'open') ...[
                        const SizedBox(height: 4),
                        LinearProgressIndicator(value: (d['score'] as int) / 100),
                        const SizedBox(height: 4),
                        Wrap(spacing: 6, runSpacing: 4, children: [
                          for (final r in reasons)
                            for (final e in r.entries)
                              Chip(
                                visualDensity: VisualDensity.compact,
                                label: Text('${_reasonLabels[e.key] ?? e.key} ${(e.value as num) > 0 ? '+' : ''}${e.value}',
                                    style: const TextStyle(fontSize: 12)),
                              ),
                        ]),
                      ],
                    ]),
                  ),
                ),
              TextField(
                controller: _title,
                enabled: _canEdit,
                decoration: const InputDecoration(labelText: 'What is the lead for?', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(_contactName ?? 'Choose customer'),
                  subtitle: _contactPhone == null ? null : Text(_contactPhone!),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (_contactPhone != null) ...[
                      IconButton(onPressed: () => callPhone(_contactPhone!), icon: const Icon(Icons.call_outlined)),
                      IconButton(onPressed: () => openWhatsApp(_contactPhone!), icon: const Icon(Icons.chat_outlined)),
                    ],
                    if (_canEdit) IconButton(onPressed: _pickContact, icon: const Icon(Icons.swap_horiz)),
                  ]),
                  onTap: _contactId == null
                      ? (_canEdit ? _pickContact : null)
                      : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ContactScreen(contactId: _contactId!))),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _value,
                    enabled: _canEdit,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: 'Value', prefixText: '${_s.currency} ', border: const OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: !_canEdit
                        ? null
                        : () async {
                            final x = await showDatePicker(
                              context: context,
                              initialDate: _close ?? DateTime.now().add(const Duration(days: 14)),
                              firstDate: DateTime.now().subtract(const Duration(days: 365)),
                              lastDate: DateTime.now().add(const Duration(days: 730)),
                            );
                            if (x != null) setState(() => _close = x);
                          },
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Expected close', border: OutlineInputBorder()),
                      child: Text(_close == null ? '—' : DateFormat('d MMM yyyy').format(_close!)),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Text('Stage', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final st in _stages.where((s) => s['kind'] == 'open'))
                  ChoiceChip(
                    label: Text(st['name'] as String),
                    selected: _stageId == st['id'],
                    onSelected: !_canEdit
                        ? null
                        : (_) {
                            setState(() => _stageId = st['id'] as String);
                            if (_id != null) _save();
                          },
                  ),
              ]),
              if (_id != null && _canEdit) ...[
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: status == 'won' || _busy ? null : _won,
                      icon: const Icon(Icons.emoji_events_outlined),
                      label: const Text('Won'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: status == 'lost' || _busy ? null : _lost,
                      icon: const Icon(Icons.close),
                      label: const Text('Lost'),
                    ),
                  ),
                ]),
                if (status != 'open')
                  TextButton(
                    onPressed: () {
                      final first = _stages.where((s) => s['kind'] == 'open').first;
                      _save(stageId: first['id'] as String);
                    },
                    child: const Text('Reopen'),
                  ),
              ],
              if (_id == null && _canEdit)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: FilledButton(onPressed: _busy ? null : () => _save(), child: const Text('Create lead')),
                ),
              if (_id != null) ...[
                const Divider(height: 32),
                Timeline(dealId: _id, contactId: _contactId, onChanged: () async {
                  final r = await _s.db.from('deal_board').select().eq('id', _id!).single();
                  if (mounted) setState(() => _d = r);
                }),
              ],
              if (d != null && (d['value'] as num) > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text('Weighted value ${_money.format((d['value'] as num) * (d['probability'] as int) / 100)}',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              const SizedBox(height: 40),
            ]),
    );
  }
}
