import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/contact_links.dart';
import '../services/session.dart';
import 'contact_form_screen.dart';
import 'deal_sheet.dart';

/// Customer 360: profile, spend, points, deals and full activity timeline.
class ContactScreen extends StatefulWidget {
  final String contactId;
  const ContactScreen({super.key, required this.contactId});
  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  Map<String, dynamic>? _c;
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _acts = [];
  List<Map<String, dynamic>> _deals = [];
  List<Map<String, dynamic>> _points = [];
  bool _loading = true;

  Session get _s => Session.instance;
  NumberFormat get _money => NumberFormat.currency(symbol: '${_s.currency} ');
  final _dt = DateFormat('d MMM yyyy, HH:mm');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = widget.contactId;
      final c = await _s.db.from('contacts').select().eq('id', id).single();
      final stats = await _s.db.from('contact_stats').select().eq('contact_id', id).maybeSingle();
      final acts = await _s.db.from('activities').select().eq('contact_id', id).order('created_at', ascending: false).limit(100);
      final deals = await _s.db
          .from('deals')
          .select('*, pipeline_stages(name, kind)')
          .eq('contact_id', id)
          .order('created_at', ascending: false);
      final pts = await _s.db.from('loyalty_ledger').select().eq('contact_id', id).order('created_at', ascending: false).limit(50);
      setState(() {
        _c = c;
        _stats = stats;
        _acts = List<Map<String, dynamic>>.from(acts);
        _deals = List<Map<String, dynamic>>.from(deals);
        _points = List<Map<String, dynamic>>.from(pts);
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load: $e')));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _log(String kind, {String? subject, bool task = false}) async {
    final subj = TextEditingController(text: subject ?? '');
    final body = TextEditingController();
    DateTime due = DateTime.now().add(const Duration(days: 1));
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(task ? 'New follow-up task' : 'Log ${kind == 'note' ? 'a note' : kind}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: subj, autofocus: true, decoration: InputDecoration(labelText: task ? 'What to do' : 'Summary')),
            if (!task) TextField(controller: body, maxLines: 3, decoration: const InputDecoration(labelText: 'Details (optional)')),
            if (task)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: Text('Due ${DateFormat('d MMM yyyy').format(due)}'),
                onTap: () async {
                  final d = await showDatePicker(
                      context: context, initialDate: due, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (d != null) set(() => due = DateTime(d.year, d.month, d.day, 9));
                },
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || subj.text.trim().isEmpty) return;
    try {
      await _s.db.from('activities').insert({
        'tenant_id': _s.tenantId,
        'contact_id': widget.contactId,
        'kind': task ? 'task' : kind,
        'subject': subj.text.trim(),
        'body': body.text.trim().isEmpty ? null : body.text.trim(),
        if (task) 'due_at': due.toUtc().toIso8601String(),
        if (task) 'assigned_to': _s.db.auth.currentUser!.id,
      });
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _call() async {
    final p = _c!['phone'] as String?;
    if (p == null) return;
    await ContactLinks.call(p);
    if (mounted) await _log('call', subject: 'Called ${_c!['name']}');
  }

  Future<void> _whatsapp() async {
    final p = _c!['phone_norm'] as String?;
    if (p == null) return;
    final first = (_c!['name'] as String).split(' ').first;
    await ContactLinks.whatsapp(p, text: 'Hi $first, ');
    if (mounted) await _log('whatsapp', subject: 'WhatsApp to ${_c!['name']}');
  }

  Future<void> _email() async {
    final e = _c!['email'] as String?;
    if (e == null) return;
    await ContactLinks.email(e, subject: _s.tenantName);
    if (mounted) await _log('email', subject: 'Email to ${_c!['name']}');
  }

  Future<void> _adjustPoints() async {
    final n = TextEditingController();
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Adjust points'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: n,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            decoration: const InputDecoration(labelText: 'Points (+ to add, − to remove)'),
          ),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'Reason')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _s.db.rpc('adjust_points', params: {
        'p_contact': widget.contactId,
        'p_points': int.tryParse(n.text) ?? 0,
        'p_note': note.text.trim().isEmpty ? 'Manual adjustment' : note.text.trim(),
      });
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _toggleTask(Map<String, dynamic> a) async {
    try {
      await _s.db
          .from('activities')
          .update({'done_at': a['done_at'] == null ? DateTime.now().toUtc().toIso8601String() : null}).eq('id', a['id'] as String);
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  IconData _icon(String kind) => switch (kind) {
        'call' => Icons.call,
        'whatsapp' => Icons.chat,
        'email' => Icons.email_outlined,
        'meeting' => Icons.groups_outlined,
        'visit' => Icons.storefront,
        'task' => Icons.task_alt,
        'system' => Icons.auto_awesome_outlined,
        'sms' => Icons.sms_outlined,
        _ => Icons.sticky_note_2_outlined,
      };

  @override
  Widget build(BuildContext context) {
    if (_loading || _c == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final c = _c!;
    final st = _stats ?? {};
    final canEdit = _s.can('crm.contact.manage');
    final t = Theme.of(context).textTheme;
    final loyaltyOn = _s.loyalty?.on ?? false;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text((c['company'] as String?) ?? c['name'] as String),
          actions: [
            if (canEdit)
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final id = await Navigator.of(context)
                      .push<String>(MaterialPageRoute(builder: (_) => ContactFormScreen(existing: c)));
                  if (id != null) _load();
                },
              ),
          ],
        ),
        body: NestedScrollView(
          headerSliverBuilder: (_, __) => [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text([
                    c['lifecycle'],
                    if (c['company'] != null) c['name'],
                    'score ${c['score']}',
                  ].join(' · '), style: t.bodyMedium),
                  if ((c['tags'] as List).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final tag in (c['tags'] as List)) Chip(label: Text(tag as String), visualDensity: VisualDensity.compact),
                      ]),
                    ),
                  const SizedBox(height: 12),
                  Row(children: [
                    _stat('Spent', _money.format(st['total_spend'] ?? 0)),
                    _stat('Orders', '${st['orders'] ?? 0}'),
                    if (loyaltyOn) _stat('Points', '${st['points'] ?? 0}'),
                    if ((st['owed'] ?? 0) != 0) _stat('Owes', _money.format(st['owed'])),
                  ]),
                  if (st['last_purchase_at'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('Last purchase ${DateFormat('d MMM yyyy').format(DateTime.parse(st['last_purchase_at'] as String).toLocal())}',
                          style: t.bodySmall),
                    ),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (c['phone'] != null) _action(Icons.call, 'Call', _call),
                    if (c['phone_norm'] != null) _action(Icons.chat, 'WhatsApp', _whatsapp),
                    if (c['email'] != null) _action(Icons.email_outlined, 'Email', _email),
                    if (canEdit) _action(Icons.sticky_note_2_outlined, 'Note', () => _log('note')),
                    if (canEdit) _action(Icons.groups_outlined, 'Meeting', () => _log('meeting')),
                    if (canEdit) _action(Icons.task_alt, 'Task', () => _log('task', task: true)),
                    if (_s.can('crm.deal.manage'))
                      _action(Icons.handshake_outlined, 'Deal', () async {
                        if (await DealSheet.show(context, contact: c)) _load();
                      }),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    [
                      c['whatsapp_opt_in'] == true ? 'WhatsApp ✓' : 'WhatsApp ✗',
                      c['email_opt_in'] == true ? 'Email ✓' : 'Email ✗',
                      if (c['consent_at'] != null)
                        'consent ${DateFormat('d MMM yyyy').format(DateTime.parse(c['consent_at'] as String).toLocal())}',
                    ].join(' · '),
                    style: t.bodySmall,
                  ),
                ]),
              ),
            ),
            const SliverToBoxAdapter(child: TabBar(tabs: [Tab(text: 'Timeline'), Tab(text: 'Deals'), Tab(text: 'Points')])),
          ],
          body: TabBarView(children: [
            _timeline(),
            _dealsTab(),
            _pointsTab(loyaltyOn),
          ]),
        ),
      ),
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          FittedBox(child: Text(value, style: Theme.of(context).textTheme.titleMedium)),
        ]),
      );

  Widget _action(IconData icon, String label, VoidCallback onTap) =>
      ActionChip(avatar: Icon(icon, size: 18), label: Text(label), onPressed: onTap);

  Widget _timeline() {
    if (_acts.isEmpty) return const Center(child: Text('No activity yet'));
    return ListView.builder(
      itemCount: _acts.length,
      itemBuilder: (_, i) {
        final a = _acts[i];
        final isTask = a['kind'] == 'task';
        final done = a['done_at'] != null;
        return ListTile(
          leading: isTask
              ? Checkbox(value: done, onChanged: _s.can('crm.contact.manage') ? (_) => _toggleTask(a) : null)
              : Icon(_icon(a['kind'] as String)),
          title: Text(a['subject'] as String, style: TextStyle(decoration: isTask && done ? TextDecoration.lineThrough : null)),
          subtitle: Text([
            if (a['body'] != null) a['body'],
            isTask && a['due_at'] != null
                ? 'due ${_dt.format(DateTime.parse(a['due_at'] as String).toLocal())}'
                : _dt.format(DateTime.parse(a['created_at'] as String).toLocal()),
          ].join('\n')),
          isThreeLine: a['body'] != null,
        );
      },
    );
  }

  Widget _dealsTab() {
    if (_deals.isEmpty) return const Center(child: Text('No deals yet'));
    return ListView(children: [
      for (final d in _deals)
        ListTile(
          leading: Icon(switch (d['status']) {
            'won' => Icons.emoji_events_outlined,
            'lost' => Icons.cancel_outlined,
            _ => Icons.handshake_outlined,
          }),
          title: Text(d['title'] as String),
          subtitle: Text('${d['pipeline_stages']?['name'] ?? ''}'
              '${d['expected_close'] != null ? ' · close by ${d['expected_close']}' : ''}'),
          trailing: Text(_money.format(d['value'])),
          onTap: _s.can('crm.deal.manage')
              ? () async {
                  if (await DealSheet.show(context, deal: d)) _load();
                }
              : null,
        ),
    ]);
  }

  Widget _pointsTab(bool on) {
    return ListView(children: [
      if (!on) const ListTile(title: Text('Loyalty points are off. Turn them on in More → Loyalty.')),
      if (on && _s.can('crm.loyalty.manage'))
        ListTile(leading: const Icon(Icons.tune), title: const Text('Adjust points'), onTap: _adjustPoints),
      for (final p in _points)
        ListTile(
          dense: true,
          title: Text(p['note'] as String? ?? p['kind'] as String),
          subtitle: Text('${p['kind']} · ${_dt.format(DateTime.parse(p['created_at'] as String).toLocal())}'),
          trailing: Text('${(p['points'] as int) > 0 ? '+' : ''}${p['points']}',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: (p['points'] as int) < 0 ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary)),
        ),
    ]);
  }
}
