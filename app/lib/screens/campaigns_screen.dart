import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/contact_links.dart';
import '../services/session.dart';

class CampaignsScreen extends StatefulWidget {
  const CampaignsScreen({super.key});
  @override
  State<CampaignsScreen> createState() => _CampaignsScreenState();
}

class _CampaignsScreenState extends State<CampaignsScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await _s.db.from('campaigns').select().eq('tenant_id', _s.tenantId!).order('created_at', ascending: false);
      _rows = List<Map<String, dynamic>>.from(r);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open([Map<String, dynamic>? c]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CampaignEditScreen(campaign: c)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Campaigns')),
      floatingActionButton:
          FloatingActionButton.extended(onPressed: () => _open(), icon: const Icon(Icons.campaign_outlined), label: const Text('New')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _rows.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 80),
                      Center(child: Text('Send a WhatsApp or email offer to the right customers.')),
                    ])
                  : ListView(children: [
                      for (final c in _rows)
                        ListTile(
                          leading: Icon(c['channel'] == 'whatsapp' ? Icons.chat : Icons.email_outlined),
                          title: Text(c['name'] as String),
                          subtitle: Text('${c['status']} · ${c['sent_count']}/${c['queued_count']} sent'
                              '${(c['failed_count'] as int) > 0 ? ' · ${c['failed_count']} failed' : ''}'),
                          trailing: Text(DateFormat('d MMM').format(DateTime.parse(c['created_at'] as String).toLocal())),
                          onTap: () => _open(c),
                        ),
                    ]),
            ),
    );
  }
}

class CampaignEditScreen extends StatefulWidget {
  final Map<String, dynamic>? campaign;
  const CampaignEditScreen({super.key, this.campaign});
  @override
  State<CampaignEditScreen> createState() => _CampaignEditScreenState();
}

class _CampaignEditScreenState extends State<CampaignEditScreen> {
  final _name = TextEditingController();
  final _subject = TextEditingController();
  final _message = TextEditingController();
  final _template = TextEditingController();
  final _lang = TextEditingController(text: 'en');
  final _tags = TextEditingController();
  final _minSpend = TextEditingController();
  String _channel = 'whatsapp';
  final Set<String> _lifecycle = {};
  int? _within; // bought in last N days
  int? _lapsed; // no purchase in N days
  bool _hasPoints = false;
  bool _birthday = false;
  int? _audience;
  String? _id;
  String _status = 'draft';
  bool _busy = false;
  String _progress = '';

  Session get _s => Session.instance;
  bool get _draft => _status == 'draft';

  @override
  void initState() {
    super.initState();
    final c = widget.campaign;
    if (c != null) {
      _id = c['id'] as String;
      _status = c['status'] as String;
      _name.text = c['name'] as String;
      _subject.text = (c['subject'] ?? '') as String;
      _message.text = c['message'] as String;
      _template.text = (c['wa_template_name'] ?? '') as String;
      _lang.text = (c['wa_template_lang'] ?? 'en') as String;
      _channel = c['channel'] as String;
      final f = Map<String, dynamic>.from(c['segment_filter'] as Map);
      _lifecycle.addAll(((f['lifecycle'] as List?) ?? []).cast<String>());
      _tags.text = ((f['tags_any'] as List?) ?? []).join(', ');
      if (f['min_spend'] != null) _minSpend.text = '${f['min_spend']}';
      _within = f['purchased_within_days'] as int?;
      _lapsed = f['not_purchased_days'] as int?;
      _hasPoints = f['has_points'] == true;
      _birthday = f['birthday_this_month'] == true;
    } else {
      _message.text = 'Hi {{first_name}}, ';
    }
    _count();
  }

  Map<String, dynamic> get _filter => {
        if (_lifecycle.isNotEmpty) 'lifecycle': _lifecycle.toList(),
        if (_tags.text.trim().isNotEmpty)
          'tags_any': _tags.text.split(',').map((t) => t.trim().toLowerCase()).where((t) => t.isNotEmpty).toList(),
        if (double.tryParse(_minSpend.text) != null) 'min_spend': double.parse(_minSpend.text),
        if (_within != null) 'purchased_within_days': _within,
        if (_lapsed != null) 'not_purchased_days': _lapsed,
        if (_hasPoints) 'has_points': true,
        if (_birthday) 'birthday_this_month': true,
      };

  Future<void> _count() async {
    try {
      final n = await _s.db.rpc('segment_count', params: {
        'p_tenant': _s.tenantId,
        'p_filter': {..._filter, 'channel': _channel},
      });
      if (mounted) setState(() => _audience = (n as num).toInt());
    } catch (_) {}
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<bool> _save() async {
    if (_name.text.trim().isEmpty || _message.text.trim().isEmpty) {
      _snack('Give the campaign a name and a message');
      return false;
    }
    final data = {
      'tenant_id': _s.tenantId,
      'name': _name.text.trim(),
      'channel': _channel,
      'segment_filter': _filter,
      'subject': _subject.text.trim().isEmpty ? null : _subject.text.trim(),
      'message': _message.text.trim(),
      'wa_template_name': _template.text.trim().isEmpty ? null : _template.text.trim(),
      'wa_template_lang': _lang.text.trim().isEmpty ? 'en' : _lang.text.trim(),
    };
    try {
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
    }
  }

  /// Sends through the server (WhatsApp Cloud API / email provider).
  Future<void> _sendAutomatic() async {
    if (_draft) {
      if (!await _save()) return;
      try {
        final n = await _s.db.rpc('queue_campaign', params: {'p_campaign': _id});
        setState(() => _status = 'queued');
        _progress = 'Queued $n';
      } on PostgrestException catch (e) {
        _snack(e.message);
        return;
      }
    }
    setState(() => _busy = true);
    var sent = 0, failed = 0;
    try {
      while (true) {
        final res = await _s.db.functions.invoke('send-messages', body: {'campaign_id': _id});
        final d = Map<String, dynamic>.from(res.data as Map);
        sent += (d['sent'] as num? ?? 0).toInt();
        failed += (d['failed'] as num? ?? 0).toInt();
        setState(() => _progress = 'Sent $sent · failed $failed · ${d['remaining']} left');
        if ((d['remaining'] as num? ?? 0) == 0 || ((d['sent'] as num? ?? 0) == 0 && (d['failed'] as num? ?? 0) == 0)) break;
      }
      setState(() => _status = 'sent');
    } on FunctionException catch (e) {
      final details = e.details;
      final msg = details is Map ? (details['error'] ?? details).toString() : '$details';
      _snack(msg.contains('not set up')
          ? '$msg. Until it is set up, use "Send one by one" instead.'
          : 'Sending stopped: $msg');
    } catch (e) {
      _snack('Sending stopped: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// No API needed: opens WhatsApp / email for each opted-in customer in turn.
  Future<void> _sendManual() async {
    if (_draft && !await _save()) return;
    final ids = await _s.db.rpc('segment_contacts', params: {
      'p_tenant': _s.tenantId,
      'p_filter': {..._filter, 'channel': _channel},
    }) as List;
    if (ids.isEmpty) {
      _snack('Nobody in this audience has opted in to $_channel');
      return;
    }
    final people = await _s.db
        .from('contacts')
        .select('id, name, phone_norm, email')
        .inFilter('id', ids.map((e) => e is Map ? e['segment_contacts'] : e).toList());
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _ManualSendScreen(
        people: List<Map<String, dynamic>>.from(people),
        channel: _channel,
        message: _message.text,
        subject: _subject.text,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget days(String label, int? value, void Function(int?) set) => DropdownButtonFormField<int?>(
          value: value,
          decoration: InputDecoration(labelText: label, isDense: true),
          items: const [
            DropdownMenuItem<int?>(value: null, child: Text('Any')),
            DropdownMenuItem<int?>(value: 7, child: Text('7 days')),
            DropdownMenuItem<int?>(value: 30, child: Text('30 days')),
            DropdownMenuItem<int?>(value: 60, child: Text('60 days')),
            DropdownMenuItem<int?>(value: 90, child: Text('90 days')),
            DropdownMenuItem<int?>(value: 180, child: Text('180 days')),
          ],
          onChanged: _draft
              ? (v) {
                  set(v);
                  _count();
                }
              : null,
        );
    return Scaffold(
      appBar: AppBar(
        title: Text(_id == null ? 'New campaign' : _name.text),
        actions: [
          if (_draft)
            TextButton(
              onPressed: () async {
                if (await _save()) _snack('Saved');
              },
              child: const Text('Save'),
            ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (!_draft) Card(child: ListTile(title: Text('Status: $_status'), subtitle: _progress.isEmpty ? null : Text(_progress))),
        TextField(controller: _name, enabled: _draft, decoration: const InputDecoration(labelText: 'Campaign name *')),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'whatsapp', icon: Icon(Icons.chat), label: Text('WhatsApp')),
            ButtonSegment(value: 'email', icon: Icon(Icons.email_outlined), label: Text('Email')),
          ],
          selected: {_channel},
          onSelectionChanged: _draft
              ? (s) {
                  setState(() => _channel = s.first);
                  _count();
                }
              : null,
        ),
        const SizedBox(height: 16),
        Text('Who gets it', style: t.titleMedium),
        Wrap(spacing: 8, children: [
          for (final l in const ['lead', 'prospect', 'customer', 'inactive'])
            FilterChip(
              label: Text(l),
              selected: _lifecycle.contains(l),
              onSelected: _draft
                  ? (v) {
                      setState(() => v ? _lifecycle.add(l) : _lifecycle.remove(l));
                      _count();
                    }
                  : null,
            ),
        ]),
        TextField(
          controller: _tags,
          enabled: _draft,
          decoration: const InputDecoration(labelText: 'Has any of these tags', hintText: 'vip, wholesale'),
          onSubmitted: (_) => _count(),
        ),
        TextField(
          controller: _minSpend,
          enabled: _draft,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: 'Spent at least', prefixText: '${_s.currency} '),
          onSubmitted: (_) => _count(),
        ),
        Row(children: [
          Expanded(child: days('Bought in last', _within, (v) => setState(() => _within = v))),
          const SizedBox(width: 12),
          Expanded(child: days('Not bought in', _lapsed, (v) => setState(() => _lapsed = v))),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Has loyalty points'),
          value: _hasPoints,
          onChanged: _draft
              ? (v) {
                  setState(() => _hasPoints = v);
                  _count();
                }
              : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Birthday this month'),
          value: _birthday,
          onChanged: _draft
              ? (v) {
                  setState(() => _birthday = v);
                  _count();
                }
              : null,
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.groups_outlined),
            title: Text(_audience == null ? 'Counting…' : '$_audience people will receive this'),
            subtitle: const Text('Only customers who opted in to this channel'),
            trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: _count),
          ),
        ),
        const SizedBox(height: 16),
        Text('Message', style: t.titleMedium),
        if (_channel == 'email')
          TextField(controller: _subject, enabled: _draft, decoration: const InputDecoration(labelText: 'Email subject')),
        TextField(
          controller: _message,
          enabled: _draft,
          maxLines: 6,
          decoration: const InputDecoration(
            helperText: 'Use {{first_name}}, {{name}}, {{points}}, {{business}}',
            helperMaxLines: 2,
          ),
        ),
        if (_channel == 'whatsapp') ...[
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('WhatsApp template (for automatic sending)'),
            subtitle: const Text('WhatsApp only delivers approved templates to people who have not messaged you in 24 hours.'),
            children: [
              TextField(controller: _template, enabled: _draft, decoration: const InputDecoration(labelText: 'Approved template name')),
              TextField(controller: _lang, enabled: _draft, decoration: const InputDecoration(labelText: 'Template language code (e.g. en, ms)')),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('The template\'s {{1}} is filled with the customer\'s first name.', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        if (_status != 'sent' && _status != 'cancelled') ...[
          FilledButton.icon(
            onPressed: _busy ? null : _sendAutomatic,
            icon: const Icon(Icons.send),
            label: Text(_busy ? _progress : (_draft ? 'Send to $_audience now' : 'Continue sending')),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _sendManual,
            icon: const Icon(Icons.touch_app_outlined),
            label: const Text('Send one by one from this phone'),
          ),
        ],
        if (_progress.isNotEmpty && !_busy) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_progress)),
        const SizedBox(height: 40),
      ]),
    );
  }
}

class _ManualSendScreen extends StatefulWidget {
  final List<Map<String, dynamic>> people;
  final String channel;
  final String message;
  final String subject;
  const _ManualSendScreen({required this.people, required this.channel, required this.message, required this.subject});
  @override
  State<_ManualSendScreen> createState() => _ManualSendScreenState();
}

class _ManualSendScreenState extends State<_ManualSendScreen> {
  final Set<String> _done = {};

  Future<void> _send(Map<String, dynamic> p) async {
    final s = Session.instance;
    final name = p['name'] as String;
    int points = 0;
    try {
      points = ((await s.db.rpc('points_balance', params: {'p_contact': p['id']})) as num).toInt();
    } catch (_) {}
    final vars = {'name': name, 'first_name': name.split(' ').first, 'points': '$points', 'business': s.tenantName};
    final text = ContactLinks.fill(widget.message, vars);
    if (widget.channel == 'whatsapp') {
      await ContactLinks.whatsapp(p['phone_norm'] as String, text: text);
    } else {
      await ContactLinks.email(p['email'] as String, subject: ContactLinks.fill(widget.subject, vars), body: text);
    }
    try {
      await s.db.from('activities').insert({
        'tenant_id': s.tenantId,
        'contact_id': p['id'],
        'kind': widget.channel,
        'subject': 'Campaign message sent by hand',
        'body': text,
      });
    } catch (_) {}
    setState(() => _done.add(p['id'] as String));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Send one by one · ${_done.length}/${widget.people.length}')),
      body: ListView(children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Tap each person: WhatsApp or your email app opens with the message ready. Press send there, then come back.'),
        ),
        for (final p in widget.people)
          ListTile(
            leading: Icon(_done.contains(p['id']) ? Icons.check_circle : Icons.radio_button_unchecked),
            title: Text(p['name'] as String),
            subtitle: Text((widget.channel == 'whatsapp' ? p['phone_norm'] : p['email']) as String? ?? ''),
            onTap: () => _send(p),
          ),
      ]),
    );
  }
}
