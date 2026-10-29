import 'package:flutter/material.dart';

import '../services/legal.dart';
import '../services/session.dart';
import 'company_details_screen.dart';
import 'contract_screen.dart';
import 'legal_ai_screen.dart';

/// Legal: contracts & e-signing, the compliance calendar, templates and the AI assistant.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    final tabs = <(String, Widget)>[
      ('Contracts', const _ContractsTab()),
      ('Calendar', const LegalCalendarTab()),
      ('Templates', const _TemplatesTab()),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Column(children: [
        Row(children: [
          Expanded(child: TabBar(tabs: [for (final t in tabs) Tab(text: t.$1)])),
          if (s.can('law.ai'))
            IconButton(
              tooltip: 'Ask the AI legal assistant',
              icon: const Icon(Icons.auto_awesome_outlined),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LegalAiScreen())),
            ),
          if (s.can('core.tenant.manage'))
            IconButton(
              tooltip: 'Company details',
              icon: const Icon(Icons.business_outlined),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CompanyDetailsScreen())),
            ),
        ]),
        Expanded(child: TabBarView(children: [for (final t in tabs) t.$2])),
      ]),
    );
  }
}

/// Creates a contract from a template (or blank) and opens it.
Future<void> newContract(BuildContext context, {Map<String, dynamic>? template, String? title, String? body, String? category}) async {
  final s = Session.instance;
  try {
    var text = body ?? '';
    Map<String, String> values = {};
    if (template != null) {
      final company = await Legal.companyValues();
      values = {
        ...company,
        for (final v in (template['variables'] as List? ?? const []))
          if ((v as Map)['default'] != null && company[v['key']] == null) v['key'] as String: v['default'].toString(),
      };
      values.removeWhere((k, v) => v.trim().isEmpty);
      text = Legal.fill(template['body'] as String, values);
    }
    final row = await s.db
        .from('contracts')
        .insert({
          'tenant_id': s.tenantId,
          'title': title ?? template?['name'] ?? 'New contract',
          'category': category ?? template?['category'] ?? 'other',
          if (template != null) 'template_id': template['id'],
          'variables': values,
          'body': text,
          'governing_law': s.countryCode == 'MY' ? 'Malaysia' : s.countryCode,
        })
        .select('id')
        .single();
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ContractScreen(contractId: row['id'] as String)));
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Legal.errorText(e))));
  }
}

Color statusColor(BuildContext context, String status) {
  final c = Theme.of(context).colorScheme;
  switch (status) {
    case 'signed':
      return Colors.green.shade700;
    case 'out_for_signature':
    case 'partially_signed':
      return Colors.orange.shade800;
    case 'terminated':
    case 'cancelled':
    case 'expired':
      return c.outline;
    default:
      return c.primary;
  }
}

// ───────────────────────── Contracts ─────────────────────────

class _ContractsTab extends StatefulWidget {
  const _ContractsTab();
  @override
  State<_ContractsTab> createState() => _ContractsTabState();
}

class _ContractsTabState extends State<_ContractsTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String _q = '';
  String _filter = 'active'; // active, signing, signed, all
  Session get _s => Session.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var q = _s.db
          .from('contracts')
          .select('id, number, title, category, status, end_date, value, currency, contacts(name), contract_signers(status)')
          .eq('tenant_id', _s.tenantId!);
      switch (_filter) {
        case 'active':
          q = q.inFilter('status', ['draft', 'in_review', 'out_for_signature', 'partially_signed', 'signed']);
        case 'signing':
          q = q.inFilter('status', ['out_for_signature', 'partially_signed']);
        case 'signed':
          q = q.eq('status', 'signed');
      }
      final t = _q.replaceAll(RegExp(r'[,()%]'), ' ').trim();
      if (t.isNotEmpty) q = q.or('title.ilike.%$t%,number.ilike.%$t%');
      final rows = await q.order('updated_at', ascending: false).limit(200);
      _rows = List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Legal.errorText(e))));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _new() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('From a template'),
            subtitle: const Text('NDA, employment, services, sales terms, privacy notice…'),
            onTap: () => Navigator.pop(context, 'template'),
          ),
          if (_s.can('law.ai'))
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('Draft with AI'),
              subtitle: const Text('Describe what you need'),
              onTap: () => Navigator.pop(context, 'ai'),
            ),
          ListTile(
            leading: const Icon(Icons.note_add_outlined),
            title: const Text('Blank / paste your own'),
            subtitle: const Text('Paste a contract you received to track and sign it'),
            onTap: () => Navigator.pop(context, 'blank'),
          ),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'template') {
      DefaultTabController.of(context).animateTo(2);
      return;
    }
    if (choice == 'ai') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LegalAiScreen(startOnDraft: true)));
    } else {
      await newContract(context);
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      floatingActionButton: _s.can('law.manage')
          ? FloatingActionButton.extended(heroTag: null, onPressed: _new, icon: const Icon(Icons.add), label: const Text('Contract'))
          : null,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search title or number', isDense: true),
            onChanged: (v) {
              _q = v;
              _load();
            },
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            for (final f in const [('active', 'Active'), ('signing', 'Awaiting signature'), ('signed', 'Signed'), ('all', 'All')])
              Padding(
                padding: const EdgeInsets.only(right: 6),
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
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _rows.isEmpty
                      ? ListView(children: const [
                          Padding(
                            padding: EdgeInsets.all(32),
                            child: Text('No contracts yet. Tap + Contract to start from a template, draft with AI, or paste your own.',
                                textAlign: TextAlign.center),
                          )
                        ])
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 88),
                          itemCount: _rows.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final r = _rows[i];
                            final status = r['status'] as String;
                            final signers = (r['contract_signers'] as List? ?? const []);
                            final signed = signers.where((x) => (x as Map)['status'] == 'signed').length;
                            final who = (r['contacts'] as Map?)?['name'];
                            return ListTile(
                              title: Text(r['title'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text([
                                r['number'] ?? '',
                                if (who != null) who,
                                if (signers.isNotEmpty && status != 'draft') '$signed/${signers.length} signed',
                                if (r['end_date'] != null) 'ends ${Legal.fmtDate(r['end_date'])}',
                              ].join(' · ')),
                              trailing: Text(Legal.statusLabels[status] ?? status,
                                  style: TextStyle(color: statusColor(context, status), fontWeight: FontWeight.w600, fontSize: 12)),
                              onTap: () async {
                                await Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => ContractScreen(contractId: r['id'] as String)));
                                _load();
                              },
                            );
                          },
                        ),
                ),
        ),
      ]),
    );
  }
}

// ───────────────────────── Calendar ─────────────────────────

/// Compliance deadlines (EPF, SOCSO, PCB, SST, SSM, Form C, …) and contract dates in one list.
class LegalCalendarTab extends StatefulWidget {
  final String? contractId; // only this contract's dates
  const LegalCalendarTab({super.key, this.contractId});
  @override
  State<LegalCalendarTab> createState() => _LegalCalendarTabState();
}

class _LegalCalendarTabState extends State<LegalCalendarTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _showDone = false;
  Session get _s => Session.instance;
  bool get _canEdit => _s.can('law.compliance') || _s.can('law.manage');

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var q = _s.db.from('legal_calendar').select().eq('tenant_id', _s.tenantId!);
      if (!_showDone) q = q.eq('status', 'open');
      final rows = await q.order('due_date', ascending: true, nullsFirst: true).limit(300);
      _rows = List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Legal.errorText(e))));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _run(Future<void> Function() f, String ok) async {
    try {
      await f();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Legal.errorText(e))));
    }
    _load();
  }

  Future<DateTime?> _pickDate(DateTime? initial) => showDatePicker(
        context: context,
        initialDate: initial ?? DateTime.now(),
        firstDate: DateTime.now().subtract(const Duration(days: 365 * 2)),
        lastDate: DateTime.now().add(const Duration(days: 365 * 10)),
      );

  Future<void> _actions(Map<String, dynamic> r) async {
    final compliance = r['source'] == 'compliance';
    final open = r['status'] == 'open';
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(r['title'] as String),
            subtitle: Text([
              if (r['detail'] != null) r['detail'],
              if (r['note'] != null) r['note'],
              if (compliance && r['recurrence'] != 'none') 'Repeats ${r['recurrence']}',
            ].join('\n')),
          ),
          const Divider(height: 1),
          if (open && r['due_date'] != null)
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('Mark done'),
              subtitle: compliance && r['recurrence'] != 'none' ? const Text('The next one is added automatically') : null,
              onTap: () => Navigator.pop(context, 'done'),
            ),
          if (open)
            ListTile(
                leading: const Icon(Icons.event_outlined),
                title: Text(r['due_date'] == null ? 'Set the date' : 'Change the date'),
                onTap: () => Navigator.pop(context, 'date')),
          if (open && compliance)
            ListTile(
                leading: const Icon(Icons.block_outlined),
                title: const Text('Not applicable to us'),
                onTap: () => Navigator.pop(context, 'na')),
          if (open && !compliance)
            ListTile(leading: const Icon(Icons.close), title: const Text('Dismiss'), onTap: () => Navigator.pop(context, 'dismiss')),
          if (r['status'] == 'not_applicable')
            ListTile(leading: const Icon(Icons.undo), title: const Text('Reopen'), onTap: () => Navigator.pop(context, 'reopen')),
        ]),
      ),
    );
    if (a == null || !mounted) return;
    final id = r['id'] as String;
    switch (a) {
      case 'done':
        if (compliance) {
          await _run(() async => _s.db.rpc('complete_compliance', params: {'p_item': id}), 'Done ✓');
        } else {
          await _run(
              () async => _s.db
                  .from('legal_obligations')
                  .update({'status': 'done', 'done_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id),
              'Done ✓');
        }
      case 'na':
        await _run(() async => _s.db.rpc('complete_compliance', params: {'p_item': id, 'p_not_applicable': true}),
            'Marked not applicable');
      case 'dismiss':
        await _run(() async => _s.db.from('legal_obligations').update({'status': 'dismissed'}).eq('id', id), 'Dismissed');
      case 'reopen':
        await _run(() async => _s.db.from('compliance_items').update({'status': 'open', 'done_at': null}).eq('id', id), 'Reopened');
      case 'date':
        final d = await _pickDate(DateTime.tryParse('${r['due_date']}'));
        if (d == null) return;
        await _run(
            () async => _s.db
                .from(compliance ? 'compliance_items' : 'legal_obligations')
                .update({'due_date': Legal.isoDate(d)}).eq('id', id),
            'Date saved');
    }
  }

  Future<void> _add() async {
    final title = TextEditingController();
    final note = TextEditingController();
    DateTime? due;
    String recurrence = 'none';
    String category = 'other';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Add a deadline'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: 'What is due (e.g. Renew business licence)')),
              DropdownButtonFormField<String>(
                value: category,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(value: 'tax', child: Text('Tax')),
                  DropdownMenuItem(value: 'company', child: Text('Company (SSM)')),
                  DropdownMenuItem(value: 'payroll', child: Text('Payroll')),
                  DropdownMenuItem(value: 'licence', child: Text('Licence / permit')),
                  DropdownMenuItem(value: 'data_protection', child: Text('Data protection')),
                  DropdownMenuItem(value: 'contract', child: Text('Contract')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (v) => set(() => category = v ?? 'other'),
              ),
              DropdownButtonFormField<String>(
                value: recurrence,
                decoration: const InputDecoration(labelText: 'Repeats'),
                items: const [
                  DropdownMenuItem(value: 'none', child: Text('Once')),
                  DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
                  DropdownMenuItem(value: 'bimonthly', child: Text('Every 2 months')),
                  DropdownMenuItem(value: 'quarterly', child: Text('Quarterly')),
                  DropdownMenuItem(value: 'annual', child: Text('Yearly')),
                ],
                onChanged: (v) => set(() => recurrence = v ?? 'none'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(due == null ? 'Pick due date' : 'Due ${Legal.dateFmt.format(due!)}'),
                trailing: const Icon(Icons.event),
                onTap: () async {
                  final d = await _pickDate(due);
                  if (d != null) set(() => due = d);
                },
              ),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
                onPressed: title.text.trim().isEmpty || due == null ? null : () => Navigator.pop(context, true),
                child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _run(
        () async => _s.db.from('compliance_items').insert({
              'tenant_id': _s.tenantId,
              'title': title.text.trim(),
              'category': category,
              'recurrence': recurrence,
              'due_date': Legal.isoDate(due!),
              if (note.text.trim().isNotEmpty) 'note': note.text.trim(),
            }),
        'Added');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final today = DateTime.now();
    final day0 = DateTime(today.year, today.month, today.day);
    final groups = <String, List<Map<String, dynamic>>>{
      'Needs a date from you': [],
      'Overdue': [],
      'Due soon': [],
      'Later': [],
      'Done': [],
    };
    for (final r in _rows) {
      final d = DateTime.tryParse('${r['due_date']}');
      if (r['status'] != 'open') {
        groups['Done']!.add(r);
      } else if (d == null) {
        groups['Needs a date from you']!.add(r);
      } else if (d.isBefore(day0)) {
        groups['Overdue']!.add(r);
      } else if (d.difference(day0).inDays <= ((r['remind_days'] ?? 7) as int)) {
        groups['Due soon']!.add(r);
      } else {
        groups['Later']!.add(r);
      }
    }
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: _canEdit
          ? FloatingActionButton(heroTag: null, tooltip: 'Add a deadline', onPressed: _add, child: const Icon(Icons.add))
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
                SwitchListTile(
                  title: const Text('Show done'),
                  value: _showDone,
                  onChanged: (v) {
                    setState(() => _showDone = v);
                    _load();
                  },
                ),
                for (final g in groups.entries)
                  if (g.value.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text('${g.key} (${g.value.length})',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: g.key == 'Overdue' ? cs.error : g.key == 'Due soon' ? Colors.orange.shade800 : null)),
                    ),
                    for (final r in g.value)
                      ListTile(
                        leading: Icon(
                          r['source'] == 'compliance' ? Icons.account_balance_outlined : Icons.description_outlined,
                          color: r['status'] == 'open' ? null : cs.outline,
                        ),
                        title: Text(r['title'] as String,
                            style: r['status'] == 'open' ? null : TextStyle(decoration: TextDecoration.lineThrough, color: cs.outline)),
                        subtitle: Text([
                          if (r['due_date'] != null) Legal.fmtDate(r['due_date']),
                          if (r['detail'] != null) r['detail'],
                          if (r['status'] == 'not_applicable') 'not applicable',
                        ].join(' · ')),
                        onTap: _canEdit ? () => _actions(r) : null,
                      ),
                  ],
                if (_rows.isEmpty)
                  const Padding(padding: EdgeInsets.all(32), child: Text('Nothing due. 🎉', textAlign: TextAlign.center)),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Dates follow the usual Malaysian deadlines (EPF/SOCSO/EIS/PCB by the 15th, SST by the end of the month after each period, '
                    'Form E by 31 March, Form C within 7 months of year end, SSM annual return within 30 days of your incorporation anniversary). '
                    'Always check the official portals for changes or extensions.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ]),
            ),
    );
  }
}

// ───────────────────────── Templates ─────────────────────────

class _TemplatesTab extends StatefulWidget {
  const _TemplatesTab();
  @override
  State<_TemplatesTab> createState() => _TemplatesTabState();
}

class _TemplatesTabState extends State<_TemplatesTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  Session get _s => Session.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _s.db
          .from('legal_templates')
          .select()
          .or('tenant_id.is.null,tenant_id.eq.${_s.tenantId}')
          .eq('active', true)
          .order('name');
      _rows = List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Legal.errorText(e))));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(Map<String, dynamic> t) async {
    final mine = t['tenant_id'] != null;
    final a = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(t['name'] as String)),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (t['description'] != null) Text(t['description'] as String),
          const SizedBox(height: 8),
          Wrap(spacing: 6, children: [
            Chip(label: Text(Legal.categories[t['category']] ?? '${t['category']}')),
            Chip(label: Text(mine ? 'Your template' : 'Starter template')),
            if (t['e_signable'] != true) const Chip(label: Text('Print & sign only')),
          ]),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(t['body'] as String, style: const TextStyle(fontFamily: 'serif', fontSize: 14)),
            ),
          ),
          const Text('Starter templates are a starting point, not legal advice. Have a lawyer check them for high-value or unusual deals.',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 80),
        ]),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              if (_s.can('law.manage'))
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, mine ? 'edit' : 'copy'),
                      child: Text(mine ? 'Edit template' : 'Customise')),
                ),
              const SizedBox(width: 8),
              if (_s.can('law.manage'))
                Expanded(child: FilledButton(onPressed: () => Navigator.pop(context, 'use'), child: const Text('Use'))),
            ]),
          ),
        ),
      ),
    ));
    if (!mounted || a == null) return;
    if (a == 'use') {
      await newContract(context, template: t);
    } else {
      await _edit(t, copy: a == 'copy');
    }
    _load();
  }

  Future<void> _edit(Map<String, dynamic>? t, {bool copy = false}) async {
    final name = TextEditingController(text: t == null ? '' : '${t['name']}${copy ? ' (ours)' : ''}');
    final desc = TextEditingController(text: (t?['description'] ?? '') as String);
    final body = TextEditingController(text: (t?['body'] ?? '') as String);
    String category = (t?['category'] ?? 'other') as String;
    bool eSign = (t?['e_signable'] ?? true) as bool;
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => StatefulBuilder(
        builder: (context, set) => Scaffold(
          appBar: AppBar(title: Text(t == null || copy ? 'New template' : 'Edit template'), actions: [
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: desc, decoration: const InputDecoration(labelText: 'When to use it')),
            DropdownButtonFormField<String>(
              value: category,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [for (final c in Legal.categories.entries) DropdownMenuItem(value: c.key, child: Text(c.value))],
              onChanged: (v) => set(() => category = v ?? 'other'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Can be signed electronically'),
              subtitle: const Text('Turn off for powers of attorney, wills, trusts and negotiable instruments'),
              value: eSign,
              onChanged: (v) => set(() => eSign = v),
            ),
            const SizedBox(height: 8),
            const Text('Use {{like_this}} for blanks. {{company_name}}, {{company_reg_no}} and {{company_address}} fill in automatically.',
                style: TextStyle(fontSize: 12)),
            TextField(
              controller: body,
              maxLines: null,
              minLines: 16,
              decoration: const InputDecoration(labelText: 'Text', alignLabelWithHint: true, border: OutlineInputBorder()),
            ),
          ]),
        ),
      ),
    ));
    if (saved != true || name.text.trim().isEmpty || body.text.trim().isEmpty) return;
    final data = {
      'name': name.text.trim(),
      'description': desc.text.trim().isEmpty ? null : desc.text.trim(),
      'category': category,
      'e_signable': eSign,
      'body': body.text,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      if (t != null && !copy) {
        await _s.db.from('legal_templates').update({...data, 'version': ((t['version'] ?? 1) as int) + 1}).eq('id', t['id']);
      } else {
        await _s.db.from('legal_templates').insert({
          ...data,
          'tenant_id': _s.tenantId,
          'code': '${t?['code'] ?? 'custom'}_${DateTime.now().millisecondsSinceEpoch}',
          'variables': t?['variables'] ?? [],
          'jurisdiction': t?['jurisdiction'] ?? _s.countryCode,
        });
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Template saved')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Legal.errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      floatingActionButton: _s.can('law.manage')
          ? FloatingActionButton(heroTag: null, tooltip: 'New template', onPressed: () async {
              await _edit(null);
              _load();
            }, child: const Icon(Icons.add))
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: _rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final t = _rows[i];
                  return ListTile(
                    leading: Icon(t['tenant_id'] == null ? Icons.description_outlined : Icons.edit_document),
                    title: Text(t['name'] as String),
                    subtitle: Text((t['description'] ?? Legal.categories[t['category']] ?? '') as String,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => _open(t),
                  );
                },
              ),
            ),
    );
  }
}
