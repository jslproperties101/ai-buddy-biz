import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

class CampaignEditScreen extends StatefulWidget {
  final String? campaignId;
  const CampaignEditScreen({super.key, this.campaignId});
  @override
  State<CampaignEditScreen> createState() => _CampaignEditScreenState();
}

class _CampaignEditScreenState extends State<CampaignEditScreen> {
  String? _id;
  Map<String, dynamic>? _c;
  final _name = TextEditingController();
  final _subject = TextEditingController();
  final _body = TextEditingController(text: 'Hi {{first_name}}, ');
  final _template = TextEditingController();
  final _lang = TextEditingController(text: 'en');
  final _tags = TextEditingController();
  final _minSpent = TextEditingController();
  final _inactive = TextEditingController();
  final _active = TextEditingController();
  final _minPoints = TextEditingController();
  String _channel = 'whatsapp';
  final Set<String> _lifecycle = {};
  int? _birthdayMonth;
  Map<String, dynamic>? _preview;
  Map<String, int> _statusCounts = {};
  bool _loading = true;
  bool _busy = false;

  Session get _s => Session.instance;
  bool get _draft => _c == null || _c!['status'] == 'draft';

  @override
  void initState() {
    super.initState();
    _id = widget.campaignId;
    _load();
  }

  Future<void> _load() async {
    if (_id != null) {
      try {
        final c = await _s.db.from('campaigns').select().eq('id', _id!).single();
        _c = c;
        _name.text = c['name'] as String;
        _channel = c['channel'] as String;
        _subject.text = (c['subject'] ?? '') as String;
        _body.text = c['body'] as String;
        _template.text = (c['wa_template'] ?? '') as String;
        _lang.text = (c['wa_language'] ?? 'en') as String;
        final f = Map<String, dynamic>.from(c['filter'] as Map);
        _tags.text = ((f['tags_any'] as List?) ?? []).join(', ');
        _lifecycle
          ..clear()
          ..addAll(((f['lifecycle'] as List?) ?? []).cast<String>());
        _minSpent.text = f['min_spent']?.toString() ?? '';
        _inactive.text = f['inactive_days']?.toString() ?? '';
        _active.text = f['active_days']?.toString() ?? '';
        _minPoints.text = f['min_points']?.toString() ?? '';
        _birthdayMonth = (f['birthday_month'] as num?)?.toInt();
        if (!_draft) {
          final msgs = await _s.db.from('outbound_messages').select('status').eq('campaign_id', _id!);
          _statusCounts = {};
          for (final m in msgs) {
            _statusCounts.update(m['status'] as String, (v) => v + 1, ifAbsent: () => 1);
          }
        }
      } catch (e) {
        _snack('Could not load: $e');
      }
    }
    if (mounted) setState(() => _loading = false);
    if (_draft) _refreshPreview();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Map<String, dynamic> get _filter {
    int? n(TextEditingController c) => int.tryParse(c.text.trim());
    final tags = _tags.text.split(',').map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList();
    return {
      if (tags.isNotEmpty) 'tags_any': tags,
      if (_lifecycle.isNotEmpty) 'lifecycle': _lifecycle.toList(),
      if (double.tryParse(_minSpent.text) != null) 'min_spent': double.parse(_minSpent.text),
      if (n(_inactive) != null) 'inactive_days': n(_inactive),
      if (n(_active) != null) 'active_days': n(_active),
      if (double.tryParse(_minPoints.text) != null) 'min_points': double.parse(_minPoints.text),
      if (_birthdayMonth != null) 'birthday_month': _birthdayMonth,
    };
  }

  Future<void> _refreshPreview() async {
    try {
      final r = await _s.db.rpc('segment_preview', params: {'p_tenant': _s.tenantId, 'p_filter': _filter, 'p_channel': _channel});
      if (mounted) setState(() => _preview = Map<String, dynamic>.from(r as Map));
    } catch (_) {}
  }

  Future<bool> _saveDraft() async {
    if (_name.text.trim().isEmpty || _body.text.trim().isEmpty) {
      _snack('Give the campaign a name and a message');
      return false;
    }
    setState(() => _busy = true);
    try {
      final data = {
        'tenant_id': _s.tenantId,
        'name': _name.text.trim(),
        'channel': _channel,
        'filter': _filter,
        'subject': _channel == 'email' ? _subject.text.trim() : null,
        'body': _body.text.trim(),
        'wa_template': _channel == 'whatsapp' && _template.text.trim().isNotEmpty ? _template.text.trim() : null,
        'wa_language': _lang.text.trim().isEmpty ? 'en' : _lang.text.trim(),
      };
      if (_id == null) {
        final r = await _s.db.from('campaigns').insert(data).select('id').single();
        _id = r['id'] as String;
      } else {
        await _s.db.from('campaigns').update(data).eq('id', _id!);
      }
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
    await _refreshPreview();
    if (!mounted) return;
    final n = _preview?['reachable'] ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Send to $n customer(s)?'),
        content: Text('Only customers who agreed to receive offers are included '
            '(${_preview?['no_consent_or_address'] ?? 0} skipped). Messages go out within a few minutes. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: n == 0 ? null : () => Navigator.pop(context, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final q = await _s.db.rpc('queue_campaign', params: {'p_campaign': _id});
      _snack('$q message(s) queued');
      setState(() => _loading = true);
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _cancel() async {
    try {
      await _s.db.rpc('cancel_campaign', params: {'p_campaign': _id});
      setState(() => _loading = true);
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _delete() async {
    if (_id != null) await _s.db.from('campaigns').delete().eq('id', _id!);
    if (mounted) Navigator.of(context).pop();
  }

  String get _sample => _body.text
      .replaceAll('{{first_name}}', 'Siti')
      .replaceAll('{{name}}', 'Siti Aminah')
      .replaceAll('{{points}}', '270')
      .replaceAll('{{business}}', _s.tenantName);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final ro = !_draft;
    return Scaffold(
      appBar: AppBar(
        title: Text(_id == null ? 'New campaign' : _name.text),
        actions: [if (!ro) TextButton(onPressed: _busy ? null : () async { if (await _saveDraft()) _snack('Draft saved'); }, child: const Text('Save'))],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (ro) _resultCard(),
              TextField(controller: _name, enabled: !ro, decoration: const InputDecoration(labelText: 'Campaign name', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'whatsapp', icon: Icon(Icons.chat_outlined), label: Text('WhatsApp')),
                  ButtonSegment(value: 'email', icon: Icon(Icons.email_outlined), label: Text('Email')),
                  ButtonSegment(value: 'sms', icon: Icon(Icons.sms_outlined), label: Text('SMS')),
                ],
                selected: {_channel},
                onSelectionChanged: ro
                    ? null
                    : (v) {
                        setState(() => _channel = v.first);
                        _refreshPreview();
                      },
              ),
              const SizedBox(height: 16),
              Text('Who gets it', style: t.titleMedium),
              TextField(
                controller: _tags,
                enabled: !ro,
                decoration: const InputDecoration(labelText: 'Has any of these tags', hintText: 'vip, wholesale'),
                onEditingComplete: _refreshPreview,
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 6, children: [
                for (final l in const ['lead', 'prospect', 'customer', 'inactive'])
                  FilterChip(
                    label: Text(l),
                    selected: _lifecycle.contains(l),
                    onSelected: ro
                        ? null
                        : (v) {
                            setState(() => v ? _lifecycle.add(l) : _lifecycle.remove(l));
                            _refreshPreview();
                          },
                  ),
              ]),
              Row(children: [
                Expanded(child: _num(_minSpent, 'Spent at least', ro)),
                const SizedBox(width: 12),
                Expanded(child: _num(_minPoints, 'Points at least', ro)),
              ]),
              Row(children: [
                Expanded(child: _num(_active, 'Bought in last N days', ro)),
                const SizedBox(width: 12),
                Expanded(child: _num(_inactive, 'No purchase for N days', ro)),
              ]),
              DropdownButtonFormField<int?>(
                value: _birthdayMonth,
                decoration: const InputDecoration(labelText: 'Birthday month'),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('Any')),
                  for (var m = 1; m <= 12; m++)
                    DropdownMenuItem<int?>(
                        value: m,
                        child: Text(const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][m - 1])),
                ],
                onChanged: ro
                    ? null
                    : (v) {
                        setState(() => _birthdayMonth = v);
                        _refreshPreview();
                      },
              ),
              if (_preview != null && !ro)
                Card(
                  margin: const EdgeInsets.only(top: 12),
                  child: ListTile(
                    leading: const Icon(Icons.people_outline),
                    title: Text('${_preview!['reachable']} will receive it'),
                    subtitle: Text('${_preview!['matched']} match · ${_preview!['no_consent_or_address']} skipped '
                        '(no consent or no ${_channel == 'email' ? 'email' : 'phone'})'),
                    trailing: IconButton(onPressed: _refreshPreview, icon: const Icon(Icons.refresh)),
                  ),
                ),
              const SizedBox(height: 16),
              Text('Message', style: t.titleMedium),
              if (_channel == 'email')
                TextField(controller: _subject, enabled: !ro, decoration: const InputDecoration(labelText: 'Subject')),
              if (_channel == 'whatsapp') ...[
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _template,
                      enabled: !ro,
                      decoration: const InputDecoration(labelText: 'Approved template name', hintText: 'e.g. monthly_promo'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _lang, enabled: !ro, decoration: const InputDecoration(labelText: 'Language'))),
                ]),
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'WhatsApp only allows business-started marketing messages using a template approved in Meta Business Manager. '
                    "The customer's first name is passed as the template's {{1}}. The text below is your record and preview.",
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: _body,
                enabled: !ro,
                maxLines: 6,
                minLines: 3,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  helperText: 'You can use {{first_name}}, {{name}}, {{points}}, {{business}}',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Card(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(padding: const EdgeInsets.all(12), child: Text('Preview: $_sample')),
              ),
              const SizedBox(height: 16),
              if (!ro) ...[
                FilledButton.icon(onPressed: _busy ? null : _send, icon: const Icon(Icons.send), label: const Text('Send campaign')),
                TextButton(onPressed: _delete, child: const Text('Delete draft')),
              ],
              if (_c?['status'] == 'queued' || _c?['status'] == 'sending')
                OutlinedButton(onPressed: _cancel, child: const Text('Stop sending')),
              const SizedBox(height: 40),
            ]),
    );
  }

  Widget _num(TextEditingController c, String label, bool ro) => TextField(
        controller: c,
        enabled: !ro,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label),
        onEditingComplete: _refreshPreview,
      );

  Widget _resultCard() {
    final c = _c!;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text((c['status'] as String).toUpperCase(), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Queued ${c['queued_count']} · Sent ${_statusCounts['sent'] ?? 0} · '
              'Waiting ${(_statusCounts['queued'] ?? 0) + (_statusCounts['sending'] ?? 0)} · '
              'Failed ${_statusCounts['failed'] ?? 0} · Cancelled ${_statusCounts['cancelled'] ?? 0}'),
          if ((_statusCounts['queued'] ?? 0) > 0 && (_statusCounts['sent'] ?? 0) == 0)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Not sending yet? Check WhatsApp / email is connected in More → CRM settings.', style: TextStyle(fontSize: 12)),
            ),
        ]),
      ),
    );
  }
}
