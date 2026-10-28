import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

/// Create or edit a deal. Returns true when something changed.
class DealSheet extends StatefulWidget {
  final Map<String, dynamic>? contact;
  final Map<String, dynamic>? deal;
  final String? initialStageId;
  const DealSheet({super.key, this.contact, this.deal, this.initialStageId});

  static Future<bool> show(BuildContext context, {Map<String, dynamic>? contact, Map<String, dynamic>? deal, String? stageId}) async =>
      await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        builder: (_) => DealSheet(contact: contact, deal: deal, initialStageId: stageId),
      ) ??
      false;

  @override
  State<DealSheet> createState() => _DealSheetState();
}

class _DealSheetState extends State<DealSheet> {
  final _title = TextEditingController();
  final _value = TextEditingController();
  final _lost = TextEditingController();
  DateTime? _close;
  String? _pipelineId;
  String? _stageId;
  List<Map<String, dynamic>> _stages = [];
  Map<String, dynamic>? _contact;
  List<Map<String, dynamic>> _contacts = [];
  bool _loading = true;
  bool _saving = false;

  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    final d = widget.deal;
    _contact = widget.contact;
    if (d != null) {
      _title.text = d['title'] as String;
      _value.text = (d['value'] as num) == 0 ? '' : (d['value'] as num).toStringAsFixed(2);
      _lost.text = (d['lost_reason'] ?? '') as String;
      _close = d['expected_close'] == null ? null : DateTime.parse(d['expected_close'] as String);
      _pipelineId = d['pipeline_id'] as String;
      _stageId = d['stage_id'] as String;
    }
    _load();
  }

  Future<void> _load() async {
    try {
      if (_pipelineId == null) {
        final p = await _s.db
            .from('pipelines')
            .select('id')
            .eq('tenant_id', _s.tenantId!)
            .order('is_default', ascending: false)
            .limit(1)
            .maybeSingle();
        _pipelineId = p?['id'] as String?;
      }
      if (_pipelineId != null) {
        final st = await _s.db.from('pipeline_stages').select().eq('pipeline_id', _pipelineId!).order('sort_order');
        _stages = List<Map<String, dynamic>>.from(st);
        _stageId ??= widget.initialStageId ?? (_stages.isEmpty ? null : _stages.first['id'] as String);
      }
      if (widget.deal != null && widget.deal!['contact_id'] != null && _contact == null) {
        _contact = await _s.db.from('contacts').select('id, name, company').eq('id', widget.deal!['contact_id'] as String).maybeSingle();
      }
      if (_contact == null) {
        final cs = await _s.db.from('contacts').select('id, name, company').eq('tenant_id', _s.tenantId!).order('name').limit(500);
        _contacts = List<Map<String, dynamic>>.from(cs);
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  String get _stageKind => (_stages.where((s) => s['id'] == _stageId).firstOrNull?['kind'] ?? 'open') as String;

  Future<void> _save() async {
    if (_title.text.trim().isEmpty || _stageId == null || _pipelineId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Give the deal a title')));
      return;
    }
    setState(() => _saving = true);
    final data = {
      'tenant_id': _s.tenantId,
      'pipeline_id': _pipelineId,
      'stage_id': _stageId,
      'contact_id': _contact?['id'],
      'title': _title.text.trim(),
      'value': double.tryParse(_value.text) ?? 0,
      'expected_close': _close == null ? null : DateFormat('yyyy-MM-dd').format(_close!),
      'lost_reason': _stageKind == 'lost' && _lost.text.trim().isNotEmpty ? _lost.text.trim() : null,
    };
    try {
      if (widget.deal == null) {
        await _s.db.from('deals').insert(data);
      } else {
        await _s.db.from('deals').update(data).eq('id', widget.deal!['id'] as String);
      }
      if (mounted) Navigator.pop(context, true);
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    try {
      await _s.db.from('deals').delete().eq('id', widget.deal!['id'] as String);
      if (mounted) Navigator.pop(context, true);
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: _loading
            ? const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(widget.deal == null ? 'New deal' : 'Edit deal', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  if (_contact != null)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_outline),
                      title: Text((_contact!['company'] ?? _contact!['name']) as String),
                    )
                  else
                    DropdownButtonFormField<Map<String, dynamic>>(
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Customer (optional)'),
                      items: [
                        for (final c in _contacts)
                          DropdownMenuItem(value: c, child: Text((c['company'] ?? c['name']) as String)),
                      ],
                      onChanged: (v) => setState(() => _contact = v),
                    ),
                  TextField(controller: _title, decoration: const InputDecoration(labelText: 'What is the deal? *')),
                  TextField(
                    controller: _value,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: 'Value', prefixText: '${_s.currency} '),
                  ),
                  DropdownButtonFormField<String>(
                    value: _stageId,
                    decoration: const InputDecoration(labelText: 'Stage'),
                    items: [
                      for (final s in _stages)
                        DropdownMenuItem(value: s['id'] as String, child: Text('${s['name']} (${s['probability']}%)')),
                    ],
                    onChanged: (v) => setState(() => _stageId = v),
                  ),
                  if (_stageKind == 'lost')
                    TextField(controller: _lost, decoration: const InputDecoration(labelText: 'Why was it lost?')),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_outlined),
                    title: Text(_close == null ? 'Expected close date' : 'Close by ${DateFormat('d MMM yyyy').format(_close!)}'),
                    onTap: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: _close ?? DateTime.now().add(const Duration(days: 14)),
                        firstDate: DateTime.now().subtract(const Duration(days: 365)),
                        lastDate: DateTime.now().add(const Duration(days: 730)),
                      );
                      if (d != null) setState(() => _close = d);
                    },
                  ),
                  const SizedBox(height: 8),
                  FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save deal')),
                  if (widget.deal != null) TextButton(onPressed: _delete, child: const Text('Delete deal')),
                ]),
              ),
      ),
    );
  }
}
