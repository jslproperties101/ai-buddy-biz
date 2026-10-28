import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';
import 'campaign_edit_screen.dart';
import 'contact_screen.dart';
import 'deal_screen.dart';

class CrmScreen extends StatelessWidget {
  const CrmScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    final tabs = <(String, Widget)>[
      if (s.can('crm.deal.view')) ('Leads', const _LeadsTab()),
      if (s.can('crm.contact.view')) ('Customers', const _CustomersTab()),
      if (s.can('crm.deal.view')) ('Tasks', const _TasksTab()),
      if (s.can('crm.campaign.manage')) ('Campaigns', const _CampaignsTab()),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Column(children: [
        TabBar(isScrollable: tabs.length > 3, tabs: [for (final t in tabs) Tab(text: t.$1)]),
        Expanded(child: TabBarView(children: [for (final t in tabs) t.$2])),
      ]),
    );
  }
}

// ---------------- Leads (pipeline) ----------------

class _LeadsTab extends StatefulWidget {
  const _LeadsTab();
  @override
  State<_LeadsTab> createState() => _LeadsTabState();
}

class _LeadsTabState extends State<_LeadsTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _stages = [];
  List<Map<String, dynamic>> _deals = [];
  Map<String, dynamic>? _summary;
  String? _stageFilter; // null = all open
  bool _mine = false;
  bool _loading = true;
  String? _error;

  Session get _s => Session.instance;
  NumberFormat get _money => NumberFormat.compactCurrency(symbol: '${_s.currency} ');

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final t = _s.tenantId!;
      _stages = List<Map<String, dynamic>>.from(await _s.db
          .from('pipeline_stages')
          .select('id, name, sort_order, probability, kind, pipelines!inner(is_default)')
          .eq('tenant_id', t)
          .eq('pipelines.is_default', true)
          .order('sort_order'));
      var q = _s.db.from('deal_board').select().eq('tenant_id', t);
      if (_stageFilter == null) {
        q = q.eq('status', 'open');
      } else {
        q = q.eq('stage_id', _stageFilter!);
      }
      if (_mine) q = q.eq('owner_id', _s.db.auth.currentUser!.id);
      _deals = List<Map<String, dynamic>>.from(await q.order('score', ascending: false).limit(300));
      _summary = Map<String, dynamic>.from(await _s.db.rpc('pipeline_summary', params: {'p_tenant': t}) as Map);
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Offline. Leads need a connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open([String? id]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => DealScreen(dealId: id)));
    _load();
  }

  Color _scoreColor(int score) {
    final c = Theme.of(context).colorScheme;
    if (score >= 60) return c.primary;
    if (score >= 30) return c.tertiary;
    return c.outline;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final sm = _summary;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: [
          if (sm != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Row(children: [
                _kpi('Open', '${sm['open_count']} · ${_money.format(sm['open_value'])}'),
                _kpi('Weighted', _money.format(sm['weighted_value'])),
                _kpi('Win rate 90d', sm['win_rate_90d'] == null ? '—' : '${sm['win_rate_90d']}%'),
              ]),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('All open'),
                  selected: _stageFilter == null,
                  onSelected: (_) {
                    _stageFilter = null;
                    _load();
                  },
                ),
              ),
              for (final st in _stages)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(st['name'] as String),
                    selected: _stageFilter == st['id'],
                    onSelected: (_) {
                      _stageFilter = st['id'] as String;
                      _load();
                    },
                  ),
                ),
              FilterChip(
                label: const Text('Mine'),
                selected: _mine,
                onSelected: (v) {
                  _mine = v;
                  _load();
                },
              ),
            ]),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          if (_loading) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          if (!_loading && _deals.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('No leads here. Tap + to add one, or connect your website form in More → CRM settings.')),
            ),
          for (final d in _deals)
            Card(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: ListTile(
                onTap: () => _open(d['id'] as String),
                leading: CircleAvatar(
                  backgroundColor: _scoreColor(d['score'] as int).withValues(alpha: 0.15),
                  child: Text('${d['score']}', style: TextStyle(color: _scoreColor(d['score'] as int), fontWeight: FontWeight.bold)),
                ),
                title: Text(d['title'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text([
                  d['contact_name'] ?? 'No contact',
                  d['stage_name'],
                  if (d['last_activity_at'] != null)
                    'last touch ${_ago(DateTime.parse(d['last_activity_at'] as String))}'
                  else
                    'not contacted yet',
                ].join(' · ')),
                trailing: Text(_money.format(d['value'])),
              ),
            ),
          const SizedBox(height: 80),
        ]),
      ),
      floatingActionButton: _s.can('crm.deal.manage')
          ? FloatingActionButton.extended(heroTag: null, onPressed: () => _open(), icon: const Icon(Icons.add), label: const Text('Lead'))
          : null,
    );
  }

  Widget _kpi(String label, String value) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              FittedBox(child: Text(value, style: Theme.of(context).textTheme.titleMedium)),
            ]),
          ),
        ),
      );
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t.toLocal());
  if (d.inDays > 0) return '${d.inDays}d ago';
  if (d.inHours > 0) return '${d.inHours}h ago';
  return '${d.inMinutes}m ago';
}

// ---------------- Customers ----------------

class _CustomersTab extends StatefulWidget {
  const _CustomersTab();
  @override
  State<_CustomersTab> createState() => _CustomersTabState();
}

class _CustomersTabState extends State<_CustomersTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _rows = [];
  String _q = '';
  String? _lifecycle;
  String _sort = 'recent';
  bool _loading = true;
  String? _error;

  Session get _s => Session.instance;
  NumberFormat get _money => NumberFormat.compactCurrency(symbol: '${_s.currency} ');

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      var q = _s.db.from('contacts').select().eq('tenant_id', _s.tenantId!).inFilter('kind', ['customer', 'both']);
      if (_lifecycle != null) q = q.eq('lifecycle', _lifecycle!);
      final term = _q.replaceAll(RegExp(r'[,()%]'), ' ').trim();
      if (term.isNotEmpty) {
        q = q.or('name.ilike.%$term%,company.ilike.%$term%,email.ilike.%$term%,phone.ilike.%$term%');
      }
      final ordered = switch (_sort) {
        'spent' => q.order('total_spent', ascending: false),
        'points' => q.order('loyalty_points', ascending: false),
        'name' => q.order('name'),
        _ => q.order('updated_at', ascending: false),
      };
      _rows = List<Map<String, dynamic>>.from(await ordered.limit(300));
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Offline. Customers need a connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(String id) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ContactScreen(contactId: id)));
    _load();
  }

  Future<void> _add() async {
    final row = await editContact(context, null);
    if (row != null) _open(row['id'] as String);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search name, phone, email',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) {
              _q = v;
              _load();
            },
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(children: [
            for (final l in const [null, 'lead', 'prospect', 'customer', 'inactive'])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(l == null ? 'All' : '${l[0].toUpperCase()}${l.substring(1)}s'),
                  selected: _lifecycle == l,
                  onSelected: (_) {
                    _lifecycle = l;
                    _load();
                  },
                ),
              ),
            PopupMenuButton<String>(
              initialValue: _sort,
              onSelected: (v) {
                _sort = v;
                _load();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'recent', child: Text('Recently updated')),
                PopupMenuItem(value: 'spent', child: Text('Top spenders')),
                PopupMenuItem(value: 'points', child: Text('Most points')),
                PopupMenuItem(value: 'name', child: Text('Name A–Z')),
              ],
              child: const Chip(avatar: Icon(Icons.sort, size: 18), label: Text('Sort')),
            ),
          ]),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: _rows.length,
                    itemBuilder: (_, i) {
                      final c = _rows[i];
                      final tags = (c['tags'] as List?)?.cast<String>() ?? [];
                      return ListTile(
                        leading: CircleAvatar(child: Text((c['name'] as String)[0].toUpperCase())),
                        title: Text(c['company'] as String? ?? c['name'] as String),
                        subtitle: Text([
                          c['lifecycle'],
                          if (c['phone'] != null) c['phone'],
                          if (tags.isNotEmpty) tags.map((t) => '#$t').join(' '),
                        ].join(' · ')),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(_money.format(c['total_spent'])),
                            if (((c['loyalty_points'] ?? 0) as num) > 0)
                              Text('${(c['loyalty_points'] as num).toInt()} pts', style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                        onTap: () => _open(c['id'] as String),
                      );
                    },
                  ),
                ),
        ),
      ]),
      floatingActionButton: (_s.can('crm.contact.manage') || _s.can('crm.contact.create'))
          ? FloatingActionButton(heroTag: null, onPressed: _add, child: const Icon(Icons.person_add_alt))
          : null,
    );
  }
}

// ---------------- Tasks ----------------

class _TasksTab extends StatefulWidget {
  const _TasksTab();
  @override
  State<_TasksTab> createState() => _TasksTabState();
}

class _TasksTabState extends State<_TasksTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _rows = [];
  bool _everyone = false;
  bool _loading = true;
  String? _error;
  Session get _s => Session.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      var q = _s.db.from('my_tasks').select().eq('tenant_id', _s.tenantId!);
      if (!_everyone) q = q.eq('owner_id', _s.db.auth.currentUser!.id);
      _rows = List<Map<String, dynamic>>.from(await q.order('due_at', ascending: true, nullsFirst: false).limit(200));
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Offline. Tasks need a connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _done(Map<String, dynamic> t) async {
    try {
      await _s.db.from('activities').update({'done_at': DateTime.now().toUtc().toIso8601String()}).eq('id', t['id']);
      _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final fmt = DateFormat('EEE d MMM, HH:mm');
    final err = Theme.of(context).colorScheme.error;
    return Column(children: [
      SwitchListTile(
        title: const Text("Everyone's tasks"),
        value: _everyone,
        onChanged: (v) {
          _everyone = v;
          _load();
        },
      ),
      if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: _rows.isEmpty
                    ? ListView(children: const [SizedBox(height: 80), Center(child: Text('No open tasks 🎉'))])
                    : ListView(children: [
                        for (final t in _rows)
                          ListTile(
                            leading: Checkbox(value: false, onChanged: (_) => _done(t)),
                            title: Text(t['body'] as String? ?? ''),
                            subtitle: Text(
                              [
                                if (t['due_at'] != null) fmt.format(DateTime.parse(t['due_at'] as String).toLocal()),
                                t['contact_name'] ?? t['deal_title'],
                              ].whereType<String>().join(' · '),
                              style: TextStyle(color: t['overdue'] == true ? err : null),
                            ),
                            onTap: () async {
                              final w = t['deal_id'] != null
                                  ? DealScreen(dealId: t['deal_id'] as String)
                                  : ContactScreen(contactId: t['contact_id'] as String);
                              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
                              _load();
                            },
                          ),
                      ]),
              ),
      ),
    ]);
  }
}

// ---------------- Campaigns ----------------

class _CampaignsTab extends StatefulWidget {
  const _CampaignsTab();
  @override
  State<_CampaignsTab> createState() => _CampaignsTabState();
}

class _CampaignsTabState extends State<_CampaignsTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  Session get _s => Session.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      _rows = List<Map<String, dynamic>>.from(await _s.db
          .from('campaigns')
          .select()
          .eq('tenant_id', _s.tenantId!)
          .order('created_at', ascending: false)
          .limit(100));
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Offline. Campaigns need a connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open([String? id]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CampaignEditScreen(campaignId: id)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    const icons = {'whatsapp': Icons.chat_outlined, 'email': Icons.email_outlined, 'sms': Icons.sms_outlined};
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(children: [
                if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
                if (_rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No campaigns yet. Send offers to customers who agreed to hear from you.')),
                  ),
                for (final c in _rows)
                  ListTile(
                    leading: Icon(icons[c['channel']]),
                    title: Text(c['name'] as String),
                    subtitle: Text(c['status'] == 'draft'
                        ? 'Draft'
                        : '${c['status']} · ${c['sent_count']}/${c['queued_count']} sent'
                            '${(c['failed_count'] as int) > 0 ? ' · ${c['failed_count']} failed' : ''}'),
                    onTap: () => _open(c['id'] as String),
                  ),
              ]),
            ),
      floatingActionButton:
          FloatingActionButton.extended(heroTag: null, onPressed: () => _open(), icon: const Icon(Icons.campaign_outlined), label: const Text('Campaign')),
    );
  }
}
