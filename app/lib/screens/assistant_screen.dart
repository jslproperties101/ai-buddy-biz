import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

String _err(Object e) {
  if (e is PostgrestException) return e.message;
  if (e is FunctionException) {
    final d = e.details;
    return d is Map && d['error'] != null ? '${d['error']}' : 'AI request failed (${e.status})';
  }
  final t = e.toString();
  return t.startsWith('Exception: ') ? t.substring(11) : t;
}

Future<Map<String, dynamic>> _agent(Map<String, dynamic> body) async {
  final s = AppSession.instance;
  final r = await s.db.functions.invoke('ai-agent', body: {'tenant_id': s.tenantId, ...body});
  final d = r.data;
  if (d is Map && d['error'] == null) return Map<String, dynamic>.from(d);
  throw Exception(d is Map ? d['error'] : 'No answer from the AI');
}

/// AI business assistant: ask questions about your business, review AI suggestions, read the daily briefing.
class AssistantScreen extends StatelessWidget {
  const AssistantScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSession.instance;
    return DefaultTabController(
      length: 3,
      child: Column(children: [
        Row(children: [
          const Expanded(child: TabBar(tabs: [Tab(text: 'Ask'), Tab(text: 'To approve'), Tab(text: 'Briefing')])),
          if (s.can('ai.settings'))
            IconButton(
              tooltip: 'AI settings',
              icon: const Icon(Icons.tune),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AiSettingsScreen())),
            ),
        ]),
        const Expanded(child: TabBarView(children: [_AskTab(), SuggestionsTab(), _BriefingTab()])),
      ]),
    );
  }
}

// ───────────────────────── Ask ─────────────────────────

class _AskTab extends StatefulWidget {
  const _AskTab();
  @override
  State<_AskTab> createState() => _AskTabState();
}

class _AskTabState extends State<_AskTab> with AutomaticKeepAliveClientMixin {
  final _t = TextEditingController();
  final _scroll = ScrollController();
  String? _conversation;
  final List<(String, String, List<String>)> _msgs = []; // role, text, suggestion ids
  bool _busy = false;
  AppSession get _s => AppSession.instance;

  static const _starters = [
    'How were sales this week compared with last week?',
    'What should I reorder this week?',
    'Who owes me money and what should I do about it?',
    'Which customers haven\'t come back lately?',
    'Any deadlines I must not miss this month?',
    'What were my busiest hours yesterday?',
  ];

  @override
  bool get wantKeepAlive => true;

  Future<void> _send([String? text]) async {
    final q = (text ?? _t.text).trim();
    if (q.isEmpty || _busy) return;
    _t.clear();
    setState(() {
      _msgs.add(('user', q, const []));
      _busy = true;
    });
    _toEnd();
    try {
      final r = await _agent({'mode': 'chat', 'message': q, if (_conversation != null) 'conversation_id': _conversation});
      _conversation = r['conversation_id'] as String?;
      setState(() => _msgs.add(('assistant', '${r['reply']}', [for (final x in (r['suggestions'] as List? ?? const [])) '$x'])));
    } catch (e) {
      setState(() => _msgs.add(('error', _err(e), const [])));
    }
    if (mounted) setState(() => _busy = false);
    _toEnd();
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      });

  Future<void> _history() async {
    final rows = await _s.db.from('ai_conversations').select('id, title, updated_at').eq('tenant_id', _s.tenantId!).order('updated_at', ascending: false).limit(30);
    if (!mounted) return;
    final id = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(leading: const Icon(Icons.add), title: const Text('New conversation'), onTap: () => Navigator.pop(context, '')),
          for (final c in rows)
            ListTile(
              title: Text('${c['title'] ?? 'Conversation'}', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(DateFormat('d MMM, HH:mm').format(DateTime.parse(c['updated_at'] as String).toLocal())),
              onTap: () => Navigator.pop(context, c['id'] as String),
            ),
        ]),
      ),
    );
    if (id == null) return;
    if (id.isEmpty) {
      setState(() {
        _conversation = null;
        _msgs.clear();
      });
      return;
    }
    final msgs = await _s.db.from('ai_messages').select('role, content').eq('conversation_id', id).order('id');
    setState(() {
      _conversation = id;
      _msgs
        ..clear()
        ..addAll([for (final m in msgs) ('${m['role']}', '${m['content']}', const <String>[])]);
    });
    _toEnd();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      Expanded(
        child: _msgs.isEmpty
            ? ListView(padding: const EdgeInsets.all(16), children: [
                Text('Ask about your business', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                const Text('The assistant reads only what your role can see, and can only suggest actions — you approve them.',
                    style: TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [for (final q in _starters) ActionChip(label: Text(q), onPressed: () => _send(q))]),
                const SizedBox(height: 12),
                TextButton.icon(onPressed: _history, icon: const Icon(Icons.history), label: const Text('Earlier conversations')),
              ])
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                itemCount: _msgs.length + (_busy ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i == _msgs.length) {
                    return const Padding(padding: EdgeInsets.all(12), child: Row(children: [
                      SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 10),
                      Text('Looking at your numbers…'),
                    ]));
                  }
                  final m = _msgs[i];
                  final mine = m.$1 == 'user';
                  return Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
                    Container(
                      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.86),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: m.$1 == 'error' ? cs.errorContainer : mine ? cs.primaryContainer : cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: SelectableText(m.$2),
                    ),
                    for (final id in m.$3) SuggestionCard(id: id, compact: true),
                  ]);
                },
              ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(children: [
            IconButton(tooltip: 'Conversations', onPressed: _history, icon: const Icon(Icons.history)),
            Expanded(
              child: TextField(
                controller: _t,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(hintText: 'Ask about sales, stock, customers…', isDense: true),
              ),
            ),
            IconButton(onPressed: _busy ? null : () => _send(), icon: const Icon(Icons.send)),
          ]),
        ),
      ),
    ]);
  }
}

// ───────────────────────── Suggestions ─────────────────────────

class SuggestionsTab extends StatefulWidget {
  const SuggestionsTab({super.key});
  @override
  State<SuggestionsTab> createState() => _SuggestionsTabState();
}

class _SuggestionsTabState extends State<SuggestionsTab> with AutomaticKeepAliveClientMixin {
  List<String> _ids = [];
  String _filter = 'pending';
  bool _loading = true;
  AppSession get _s => AppSession.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var q = _s.db.from('ai_suggestions').select('id').eq('tenant_id', _s.tenantId!);
      q = _filter == 'pending' ? q.eq('status', 'pending').gt('expires_at', DateTime.now().toUtc().toIso8601String()) : q.neq('status', 'pending');
      _ids = [for (final r in await q.order('created_at', ascending: false).limit(100)) r['id'] as String];
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          ChoiceChip(label: const Text('Waiting'), selected: _filter == 'pending', onSelected: (_) {
            setState(() => _filter = 'pending');
            _load();
          }),
          const SizedBox(width: 6),
          ChoiceChip(label: const Text('Decided'), selected: _filter == 'done', onSelected: (_) {
            setState(() => _filter = 'done');
            _load();
          }),
        ]),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: _ids.isEmpty
                    ? ListView(children: const [
                        Padding(
                          padding: EdgeInsets.all(32),
                          child: Text('Nothing to approve. Suggestions appear here from the daily briefing and when you ask the assistant.',
                              textAlign: TextAlign.center),
                        )
                      ])
                    : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                        for (final id in _ids) SuggestionCard(key: ValueKey(id), id: id, onDecided: _load),
                      ]),
              ),
      ),
    ]);
  }
}

/// One AI suggestion with readable details, editable fields, and approve / reject.
class SuggestionCard extends StatefulWidget {
  final String id;
  final bool compact;
  final VoidCallback? onDecided;
  const SuggestionCard({super.key, required this.id, this.compact = false, this.onDecided});
  @override
  State<SuggestionCard> createState() => _SuggestionCardState();
}

class _SuggestionCardState extends State<SuggestionCard> {
  Map<String, dynamic>? _sg;
  Map<String, String> _names = {}; // id → readable name
  final Map<String, TextEditingController> _edit = {};
  bool _busy = false;
  AppSession get _s => AppSession.instance;

  static const _icons = {
    'purchase_order': Icons.local_shipping_outlined,
    'send_message': Icons.chat_outlined,
    'create_task': Icons.task_alt,
    'price_change': Icons.sell_outlined,
    'note': Icons.lightbulb_outline,
  };
  static const _agents = {
    'assistant': 'Assistant',
    'reorder': 'Stock',
    'collections': 'Money owed',
    'leads': 'Sales leads',
    'customers': 'Customers',
    'compliance': 'Deadlines',
    'pricing': 'Pricing',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sg = await _s.db.from('ai_suggestions').select().eq('id', widget.id).maybeSingle();
      if (sg == null) return;
      final p = Map<String, dynamic>.from(sg['payload'] as Map);
      final names = <String, String>{};
      Future<void> look(String table, String col, Iterable<String> ids, String Function(Map<String, dynamic>) label) async {
        final list = ids.where((x) => x.isNotEmpty).toSet().toList();
        if (list.isEmpty) return;
        try {
          for (final r in await _s.db.from(table).select(col).inFilter('id', list)) {
            names[r['id'] as String] = label(r);
          }
        } catch (_) {}
      }

      final variants = <String>[
        if (p['variant_id'] != null) '${p['variant_id']}',
        for (final l in (p['lines'] as List? ?? const [])) '${l['variant_id']}',
      ];
      await Future.wait([
        look('product_variants', 'id, name, price, products(name)', variants,
            (r) => '${r['products']?['name'] ?? ''}${r['name'] != null ? ' — ${r['name']}' : ''} (now ${(r['price'] as num).toStringAsFixed(2)})'),
        look('suppliers', 'id, name', [if (p['supplier_id'] != null) '${p['supplier_id']}'], (r) => '${r['name']}'),
        look('contacts', 'id, name', [if (p['contact_id'] != null) '${p['contact_id']}'], (r) => '${r['name']}'),
        look('outlets', 'id, name', [if (p['outlet_id'] != null) '${p['outlet_id']}'], (r) => '${r['name']}'),
        look('deals', 'id, title', [if (p['deal_id'] != null) '${p['deal_id']}'], (r) => '${r['title']}'),
      ]);
      _edit.clear();
      if (sg['kind'] == 'send_message') {
        _edit['subject'] = TextEditingController(text: (p['subject'] ?? '') as String);
        _edit['body'] = TextEditingController(text: (p['body'] ?? '') as String);
      } else if (sg['kind'] == 'price_change') {
        _edit['new_price'] = TextEditingController(text: '${p['new_price'] ?? ''}');
      } else if (sg['kind'] == 'create_task') {
        _edit['body'] = TextEditingController(text: (p['body'] ?? sg['title'] ?? '') as String);
      } else if (sg['kind'] == 'purchase_order') {
        for (final (i, l) in (p['lines'] as List? ?? const []).indexed) {
          _edit['qty$i'] = TextEditingController(text: '${l['qty']}');
        }
      }
      if (mounted) {
        setState(() {
          _sg = Map<String, dynamic>.from(sg);
          _names = names;
        });
      }
    } catch (_) {}
  }

  Map<String, dynamic> _edits() {
    final k = _sg!['kind'];
    final p = Map<String, dynamic>.from(_sg!['payload'] as Map);
    if (k == 'send_message') return {'subject': _edit['subject']!.text.trim(), 'body': _edit['body']!.text.trim()};
    if (k == 'price_change') return {'new_price': double.tryParse(_edit['new_price']!.text.replaceAll(',', '.'))};
    if (k == 'create_task') return {'body': _edit['body']!.text.trim()};
    if (k == 'purchase_order') {
      return {
        'lines': [
          for (final (i, l) in (p['lines'] as List? ?? const []).indexed) {...Map<String, dynamic>.from(l as Map), 'qty': double.tryParse(_edit['qty$i']!.text) ?? 0}
        ]
      };
    }
    return {};
  }

  Future<void> _decide(bool approve) async {
    setState(() => _busy = true);
    try {
      final r = await _s.db.rpc('ai_decide', params: {'p_suggestion': widget.id, 'p_approve': approve, 'p_edits': approve ? _edits() : null}) as Map;
      final res = r['result'] as Map?;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(!approve
                ? 'Dismissed'
                : res?['number'] != null
                    ? 'Draft purchase order ${res!['number']} created — review and send it in Suppliers'
                    : res?['queued_to'] != null
                        ? 'Message queued to ${res!['queued_to']}'
                        : res?['new_price'] != null
                            ? 'Price changed to ${res!['new_price']}'
                            : 'Done')));
      }
      widget.onDecided?.call();
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final sg = _sg;
    if (sg == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final p = Map<String, dynamic>.from(sg['payload'] as Map);
    final pending = sg['status'] == 'pending' && DateTime.parse(sg['expires_at'] as String).isAfter(DateTime.now());
    String n(dynamic id) => _names['$id'] ?? '—';
    final details = <Widget>[];
    switch (sg['kind']) {
      case 'purchase_order':
        details.add(Text('Supplier: ${n(p['supplier_id'])} · deliver to ${n(p['outlet_id'])}'));
        for (final (i, l) in (p['lines'] as List? ?? const []).indexed) {
          details.add(Row(children: [
            Expanded(child: Text(n(l['variant_id']), style: const TextStyle(fontSize: 13))),
            SizedBox(
              width: 72,
              child: pending
                  ? TextField(controller: _edit['qty$i'], keyboardType: TextInputType.number, decoration: const InputDecoration(isDense: true, labelText: 'Qty'))
                  : Text('× ${l['qty']}'),
            ),
          ]));
        }
      case 'send_message':
        details.add(Text('To: ${n(p['contact_id'])}${p['purpose'] == 'marketing' ? ' (marketing)' : ''}'));
        if (pending) {
          details.add(TextField(controller: _edit['subject'], decoration: const InputDecoration(isDense: true, labelText: 'Subject (email)')));
          details.add(TextField(controller: _edit['body'], maxLines: null, decoration: const InputDecoration(isDense: true, labelText: 'Message')));
        } else {
          details.add(Text('${p['body'] ?? ''}', style: const TextStyle(fontStyle: FontStyle.italic)));
        }
      case 'create_task':
        details.add(Text('For: ${p['contact_id'] != null ? n(p['contact_id']) : n(p['deal_id'])}'));
        if (pending) details.add(TextField(controller: _edit['body'], decoration: const InputDecoration(isDense: true, labelText: 'Task')));
      case 'price_change':
        details.add(Text(n(p['variant_id'])));
        if (pending) {
          details.add(TextField(controller: _edit['new_price'], keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true, labelText: 'New price')));
        } else {
          details.add(Text('New price ${p['new_price']}'));
        }
    }
    return Card(
      margin: widget.compact ? const EdgeInsets.symmetric(vertical: 4) : const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(_icons[sg['kind']] ?? Icons.lightbulb_outline, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(child: Text('${sg['title']}', style: const TextStyle(fontWeight: FontWeight.bold))),
            Text(_agents[sg['agent']] ?? '${sg['agent']}', style: TextStyle(fontSize: 11, color: cs.outline)),
          ]),
          if (sg['reason'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${sg['reason']}', style: const TextStyle(fontSize: 13))),
          ...details.map((w) => Padding(padding: const EdgeInsets.only(top: 4), child: w)),
          const SizedBox(height: 8),
          if (pending)
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: _busy ? null : () => _decide(false), child: const Text('Dismiss')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _busy ? null : () => _decide(true), child: Text(sg['kind'] == 'note' ? 'Got it' : 'Approve')),
            ])
          else
            Text(
              {'approved': '✔ Approved', 'rejected': 'Dismissed', 'failed': 'Failed: ${sg['error'] ?? ''}', 'expired': 'Expired', 'pending': 'Expired'}[sg['status']] ??
                  '${sg['status']}',
              style: TextStyle(color: sg['status'] == 'approved' ? Colors.green.shade700 : cs.outline),
            ),
        ]),
      ),
    );
  }
}

// ───────────────────────── Briefing ─────────────────────────

class _BriefingTab extends StatefulWidget {
  const _BriefingTab();
  @override
  State<_BriefingTab> createState() => _BriefingTabState();
}

class _BriefingTabState extends State<_BriefingTab> with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _b;
  bool _loading = true;
  bool _making = false;
  AppSession get _s => AppSession.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _b = await _s.db.from('ai_briefings').select().eq('tenant_id', _s.tenantId!).order('for_date', ascending: false).limit(1).maybeSingle();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _make() async {
    setState(() => _making = true);
    try {
      await _agent({'mode': 'briefing'});
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    }
    if (mounted) setState(() => _making = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    final c = _b == null ? null : Map<String, dynamic>.from(_b!['content'] as Map);
    final cs = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        if (c == null) const Text('No briefing yet. Make one now, or turn on the daily briefing in AI settings.'),
        if (c != null) ...[
          Text(DateFormat('EEEE d MMMM').format(DateTime.parse(_b!['for_date'] as String)), style: TextStyle(color: cs.outline)),
          const SizedBox(height: 4),
          Text('${c['headline']}', style: Theme.of(context).textTheme.titleLarge),
          for (final s in (c['sections'] as List? ?? const [])) ...[
            const SizedBox(height: 14),
            Text('${s['title']}', style: Theme.of(context).textTheme.titleSmall),
            for (final pt in (s['points'] as List? ?? const [])) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $pt')),
          ],
          if ((c['watch'] as List? ?? const []).isNotEmpty) ...[
            const SizedBox(height: 14),
            Card(
              color: cs.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Keep an eye on', style: TextStyle(fontWeight: FontWeight.bold)),
                  for (final w in c['watch'] as List) Text('• $w'),
                ]),
              ),
            ),
          ],
          if ((c['suggestions'] ?? 0) as int > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('${c['suggestions']} suggestion(s) are waiting in "To approve".', style: TextStyle(color: cs.primary)),
            ),
        ],
        const SizedBox(height: 20),
        FilledButton.tonalIcon(
          onPressed: _making ? null : _make,
          icon: _making ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome),
          label: Text(_making ? 'Reading your numbers…' : (c == null ? 'Make today\'s briefing' : 'Refresh today\'s briefing')),
        ),
        const SizedBox(height: 8),
        const Text('AI can make mistakes. Check important numbers in Reports before acting.', style: TextStyle(fontSize: 12)),
      ]),
    );
  }
}

// ───────────────────────── Settings ─────────────────────────

class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});
  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  Map<String, dynamic>? _st;
  Map<String, dynamic>? _quota;
  final _maxPct = TextEditingController();
  AppSession get _s => AppSession.instance;

  static const _agentInfo = [
    ('reorder', 'Stock', 'Draft purchase orders for items running low'),
    ('collections', 'Money owed', 'Polite reminders for overdue invoices'),
    ('leads', 'Sales leads', 'Follow-up tasks for deals going quiet'),
    ('customers', 'Customers', 'Win-back and birthday messages (only with marketing consent)'),
    ('compliance', 'Deadlines', 'Notes about tax, payroll and licence deadlines'),
    ('pricing', 'Pricing', 'Price change ideas (off by default)'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = await _s.db.from('ai_settings').select().eq('tenant_id', _s.tenantId!).maybeSingle();
    if (st == null) {
      await _s.db.from('ai_settings').insert({'tenant_id': _s.tenantId});
      return _load();
    }
    _st = Map<String, dynamic>.from(st);
    _maxPct.text = '${_st!['max_price_change_pct']}';
    try {
      _quota = Map<String, dynamic>.from(await _s.db.rpc('ai_check_quota', params: {'p_tenant': _s.tenantId}) as Map);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    try {
      await _s.db.from('ai_settings').update({
        'daily_briefing': _st!['daily_briefing'],
        'briefing_hour': _st!['briefing_hour'],
        'email_briefing': _st!['email_briefing'],
        'agents': _st!['agents'],
        'max_price_change_pct': double.tryParse(_maxPct.text) ?? 20,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('tenant_id', _s.tenantId!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = _st;
    if (st == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final agents = Map<String, dynamic>.from(st['agents'] as Map);
    return Scaffold(
      appBar: AppBar(title: const Text('AI settings'), actions: [TextButton(onPressed: _save, child: const Text('Save'))]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (_quota != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.data_usage),
              title: Text('${_quota!['used']} of ${_quota!['limit']} AI requests used this month'),
              subtitle: Text('Plan: ${_quota!['plan']}'),
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Daily briefing'),
          subtitle: const Text('Every morning: yesterday\'s numbers, risks and suggested actions'),
          value: st['daily_briefing'] == true,
          onChanged: (v) => setState(() => st['daily_briefing'] = v),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Ready by'),
          trailing: DropdownButton<int>(
            value: st['briefing_hour'] as int,
            items: [for (var h = 5; h <= 11; h++) DropdownMenuItem(value: h, child: Text('${h.toString().padLeft(2, '0')}:00'))],
            onChanged: (v) => setState(() => st['briefing_hour'] = v ?? 8),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Email it to owners and admins'),
          value: st['email_briefing'] == true,
          onChanged: (v) => setState(() => st['email_briefing'] = v),
        ),
        const Divider(),
        Text('What the AI may suggest', style: Theme.of(context).textTheme.titleSmall),
        for (final a in _agentInfo)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(a.$2),
            subtitle: Text(a.$3),
            value: agents[a.$1] ?? a.$1 != 'pricing',
            onChanged: (v) => setState(() {
              agents[a.$1] = v;
              st['agents'] = agents;
            }),
          ),
        TextField(
          controller: _maxPct,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Largest price change allowed from a suggestion (%)'),
        ),
        const SizedBox(height: 12),
        const Text('Every suggestion waits for a person with the right permission. Messages always go to the address on the customer\'s record, '
            'and marketing messages only to customers who agreed to receive them.', style: TextStyle(fontSize: 12)),
      ]),
    );
  }
}
