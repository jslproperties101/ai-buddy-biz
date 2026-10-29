import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/crm.dart';
import '../services/session.dart';
import '../widgets/timeline.dart';
import 'po_screen.dart';

const supplierCategories = {
  'vendor': 'Goods supplier',
  'carrier_sea': 'Shipping line',
  'carrier_air': 'Airline',
  'trucking': 'Trucking',
  'forwarder': 'Freight forwarder',
  'customs_broker': 'Customs broker',
  'warehouse': 'Warehouse',
  'agent': 'Overseas agent',
  'insurer': 'Insurer',
  'other': 'Other',
};

class SuppliersScreen extends StatefulWidget {
  const SuppliersScreen({super.key});
  @override
  State<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends State<SuppliersScreen> {
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _pos = [];
  String? _cat;
  String _q = '';
  bool _loading = true;
  AppSession get _s => AppSession.instance;
  NumberFormat get _money => NumberFormat.compactCurrency(symbol: '${_s.currency} ');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var q = _s.db.from('supplier_scorecard').select().eq('tenant_id', _s.tenantId!);
      if (_cat != null) q = q.eq('category', _cat!);
      final t = _q.replaceAll(RegExp(r'[,()%]'), ' ').trim();
      if (t.isNotEmpty) q = q.ilike('name', '%$t%');
      _rows = List<Map<String, dynamic>>.from(await q.order('name'));
      _pos = List<Map<String, dynamic>>.from(await _s.db
          .from('po_list')
          .select()
          .eq('tenant_id', _s.tenantId!)
          .inFilter('status', ['draft', 'sent', 'partial'])
          .order('created_at', ascending: false));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load: $e')));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(String id) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SupplierScreen(supplierId: id)));
    _load();
  }

  Future<void> _openPo([String? id]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PoScreen(poId: id)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Suppliers & purchasing'),
          bottom: TabBar(tabs: [const Tab(text: 'Suppliers'), Tab(text: 'Open POs (${_pos.length})')]),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(children: [_suppliers(), _poList()]),
        floatingActionButton: Builder(
          builder: (context) => FloatingActionButton.extended(
            heroTag: null,
            onPressed: () async {
              if (DefaultTabController.of(context).index == 1) {
                _openPo();
              } else {
                final r = await editSupplier(context, null);
                if (r != null) _open(r['id'] as String);
              }
            },
            icon: const Icon(Icons.add),
            label: const Text('New'),
          ),
        ),
      ),
    );
  }

  Widget _suppliers() {
    final err = Theme.of(context).colorScheme.error;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: TextField(
            decoration: const InputDecoration(hintText: 'Search suppliers', prefixIcon: Icon(Icons.search), border: OutlineInputBorder(), isDense: true),
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
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(label: const Text('All'), selected: _cat == null, onSelected: (_) {
                _cat = null;
                _load();
              }),
            ),
            for (final c in supplierCategories.entries)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(label: Text(c.value), selected: _cat == c.key, onSelected: (_) {
                  _cat = c.key;
                  _load();
                }),
              ),
          ]),
        ),
        if (_rows.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No suppliers yet'))),
        for (final r in _rows)
          ListTile(
            title: Row(children: [
              Flexible(child: Text(r['name'] as String, overflow: TextOverflow.ellipsis)),
              if (r['rating'] != null) ...[const SizedBox(width: 6), Text('★' * (r['rating'] as int), style: const TextStyle(color: Colors.amber))],
            ]),
            subtitle: Text([
              supplierCategories[r['category']],
              if (r['po_on_time_pct'] != null) 'POs on time ${r['po_on_time_pct']}%',
              if (r['transit_on_time_pct'] != null) 'transit on time ${r['transit_on_time_pct']}%',
              if ((r['open_pos'] as int) > 0) '${r['open_pos']} open PO',
            ].whereType<String>().join(' · ')),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(_money.format((r['spend_12m'] as num) + (r['freight_spend_12m'] as num))),
              if ((r['docs_expired'] as int) > 0)
                Text('${r['docs_expired']} doc expired', style: TextStyle(fontSize: 11, color: err))
              else if ((r['docs_expiring'] as int) > 0)
                Text('${r['docs_expiring']} doc expiring', style: const TextStyle(fontSize: 11, color: Colors.orange)),
            ]),
            onTap: () => _open(r['id'] as String),
          ),
        const SizedBox(height: 80),
      ]),
    );
  }

  Widget _poList() {
    final fmt = NumberFormat.currency(symbol: '${_s.currency} ');
    final err = Theme.of(context).colorScheme.error;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(children: [
        if (_pos.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No open purchase orders'))),
        for (final p in _pos)
          ListTile(
            title: Text('${p['number']} · ${p['supplier_name']}'),
            subtitle: Text([
              statusText(p['status'] as String),
              if (p['expected_at'] != null) 'expected ${p['expected_at']}',
              if ((p['received_ratio'] as num) > 0) '${((p['received_ratio'] as num) * 100).toStringAsFixed(0)}% received',
            ].join(' · ')),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(fmt.format(p['total'])),
              if (p['late'] == true) Text('LATE', style: TextStyle(fontSize: 11, color: err)),
            ]),
            onTap: () => _openPo(p['id'] as String),
          ),
        const SizedBox(height: 80),
      ]),
    );
  }
}

String statusText(String s) => '${s[0].toUpperCase()}${s.substring(1)}';

/// Add or edit a supplier. Returns the saved row.
Future<Map<String, dynamic>?> editSupplier(BuildContext context, Map<String, dynamic>? sup) async {
  final s = AppSession.instance;
  TextEditingController t(String k) => TextEditingController(text: sup?[k]?.toString() ?? '');
  final f = {
    for (final k in const ['name', 'contact_name', 'phone', 'email', 'website', 'tin', 'currency', 'payment_terms_days', 'lead_time_days', 'iata_prefix', 'scac', 'notes'])
      k: t(k)
  };
  final tags = TextEditingController(text: ((sup?['tags'] as List?) ?? []).join(', '));
  var cat = (sup?['category'] ?? 'vendor') as String;
  int? rating = sup?['rating'] as int?;
  var active = (sup?['active'] ?? true) as bool;
  const labels = {
    'name': 'Company name *',
    'contact_name': 'Main contact',
    'phone': 'Phone',
    'email': 'Email',
    'website': 'Website',
    'tin': 'Tax ID',
    'currency': 'Currency (e.g. USD)',
    'payment_terms_days': 'Payment terms (days)',
    'lead_time_days': 'Lead time (days)',
    'iata_prefix': 'Airline AWB prefix (3 digits)',
    'scac': 'Carrier code (SCAC)',
    'notes': 'Notes',
  };
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (context, set) => AlertDialog(
        title: Text(sup == null ? 'New supplier' : 'Edit supplier'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: cat,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [for (final c in supplierCategories.entries) DropdownMenuItem(value: c.key, child: Text(c.value))],
              onChanged: (v) => set(() => cat = v!),
            ),
            for (final k in f.keys)
              if ((k != 'iata_prefix' || cat == 'carrier_air') && (k != 'scac' || cat == 'carrier_sea'))
                TextField(
                  controller: f[k],
                  maxLines: k == 'notes' ? 3 : 1,
                  keyboardType: k.endsWith('_days') || k == 'iata_prefix' ? TextInputType.number : null,
                  decoration: InputDecoration(labelText: labels[k]),
                ),
            TextField(controller: tags, decoration: const InputDecoration(labelText: 'Tags (comma separated)')),
            const SizedBox(height: 8),
            Row(children: [
              const Text('Rating'),
              for (var i = 1; i <= 5; i++)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => set(() => rating = rating == i ? null : i),
                  icon: Icon((rating ?? 0) >= i ? Icons.star : Icons.star_border, color: Colors.amber),
                ),
            ]),
            if (sup != null) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Active'), value: active, onChanged: (v) => set(() => active = v)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    ),
  );
  if (ok != true) return null;
  if (f['name']!.text.trim().isEmpty) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name is required')));
    return null;
  }
  String? v(String k) => f[k]!.text.trim().isEmpty ? null : f[k]!.text.trim();
  final data = {
    'tenant_id': s.tenantId,
    'name': f['name']!.text.trim(),
    'category': cat,
    'contact_name': v('contact_name'),
    'phone': v('phone'),
    'email': v('email')?.toLowerCase(),
    'website': v('website'),
    'tin': v('tin'),
    'currency': v('currency')?.toUpperCase(),
    'payment_terms_days': int.tryParse(f['payment_terms_days']!.text),
    'lead_time_days': int.tryParse(f['lead_time_days']!.text),
    'iata_prefix': cat == 'carrier_air' ? v('iata_prefix') : null,
    'scac': cat == 'carrier_sea' ? v('scac')?.toUpperCase() : null,
    'notes': v('notes'),
    'rating': rating,
    'active': active,
    'tags': tags.text.split(',').map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList(),
  };
  try {
    if (sup == null) return await s.db.from('suppliers').insert(data).select().single();
    return await s.db.from('suppliers').update(data).eq('id', sup['id']).select().single();
  } on PostgrestException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    return null;
  }
}

class SupplierScreen extends StatefulWidget {
  final String supplierId;
  const SupplierScreen({super.key, required this.supplierId});
  @override
  State<SupplierScreen> createState() => _SupplierScreenState();
}

class _SupplierScreenState extends State<SupplierScreen> {
  Map<String, dynamic>? _sup;
  Map<String, dynamic>? _score;
  List<Map<String, dynamic>> _contacts = [];
  List<Map<String, dynamic>> _docs = [];
  List<Map<String, dynamic>> _pos = [];
  bool _loading = true;
  AppSession get _s => AppSession.instance;
  NumberFormat get _money => NumberFormat.currency(symbol: '${_s.currency} ');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = widget.supplierId;
      _sup = await _s.db.from('suppliers').select().eq('id', id).single();
      _score = await _s.db.from('supplier_scorecard').select().eq('id', id).single();
      _contacts = List<Map<String, dynamic>>.from(await _s.db.from('supplier_contacts').select().eq('supplier_id', id).order('name'));
      _docs = List<Map<String, dynamic>>.from(await _s.db.from('supplier_documents').select().eq('supplier_id', id).order('expires_on'));
      _pos = List<Map<String, dynamic>>.from(await _s.db.from('po_list').select().eq('supplier_id', id).order('created_at', ascending: false).limit(30));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load: $e')));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addContact() async {
    final name = TextEditingController(), role = TextEditingController(), phone = TextEditingController(), email = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add contact person'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name *')),
          TextField(controller: role, decoration: const InputDecoration(labelText: 'Role (e.g. Sales, Ops, Accounts)')),
          TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
          TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    await _s.db.from('supplier_contacts').insert({
      'tenant_id': _s.tenantId,
      'supplier_id': widget.supplierId,
      'name': name.text.trim(),
      'role': role.text.trim().isEmpty ? null : role.text.trim(),
      'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
      'email': email.text.trim().isEmpty ? null : email.text.trim(),
    });
    _load();
  }

  Future<void> _addDoc() async {
    var kind = 'licence';
    final title = TextEditingController(), no = TextEditingController();
    DateTime? expires;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Add document'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: kind,
              decoration: const InputDecoration(labelText: 'Kind'),
              items: [for (final k in const ['licence', 'insurance', 'contract', 'certificate', 'tax', 'bank', 'other']) DropdownMenuItem(value: k, child: Text(statusText(k)))],
              onChanged: (v) => set(() => kind = v!),
            ),
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Title *')),
            TextField(controller: no, decoration: const InputDecoration(labelText: 'Document no.')),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Expires'),
              subtitle: Text(expires == null ? 'No expiry' : DateFormat('d MMM yyyy').format(expires!)),
              onTap: () async {
                final d = await showDatePicker(context: context, initialDate: DateTime.now().add(const Duration(days: 365)), firstDate: DateTime.now().subtract(const Duration(days: 3650)), lastDate: DateTime.now().add(const Duration(days: 3650)));
                if (d != null) set(() => expires = d);
              },
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || title.text.trim().isEmpty) return;
    await _s.db.from('supplier_documents').insert({
      'tenant_id': _s.tenantId,
      'supplier_id': widget.supplierId,
      'kind': kind,
      'title': title.text.trim(),
      'doc_no': no.text.trim().isEmpty ? null : no.text.trim(),
      'expires_on': expires == null ? null : DateFormat('yyyy-MM-dd').format(expires!),
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final sp = _sup;
    final sc = _score;
    final t = Theme.of(context).textTheme;
    final err = Theme.of(context).colorScheme.error;
    return Scaffold(
      appBar: AppBar(
        title: Text(sp?['name'] as String? ?? ''),
        actions: [
          if (sp != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                if (await editSupplier(context, sp) != null) _load();
              },
            ),
        ],
      ),
      body: _loading || sp == null || sc == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                Wrap(spacing: 6, children: [
                  Chip(label: Text(supplierCategories[sp['category']] ?? '')),
                  if (sp['rating'] != null) Chip(label: Text('★' * (sp['rating'] as int))),
                  if (sp['active'] != true) const Chip(label: Text('Inactive')),
                  for (final tag in (sp['tags'] as List? ?? [])) Chip(label: Text('#$tag')),
                ]),
                Wrap(spacing: 8, children: [
                  if (sp['phone'] != null) ...[
                    FilledButton.tonalIcon(onPressed: () => callPhone(sp['phone'] as String), icon: const Icon(Icons.call), label: const Text('Call')),
                    FilledButton.tonalIcon(onPressed: () => openWhatsApp(sp['phone'] as String), icon: const Icon(Icons.chat), label: const Text('WhatsApp')),
                  ],
                  if (sp['email'] != null)
                    FilledButton.tonalIcon(onPressed: () => sendEmail(sp['email'] as String), icon: const Icon(Icons.email), label: const Text('Email')),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  _stat('POs on time', sc['po_on_time_pct'] == null ? '—' : '${sc['po_on_time_pct']}%'),
                  _stat('Transit on time', sc['transit_on_time_pct'] == null ? '—' : '${sc['transit_on_time_pct']}%'),
                  _stat('Spend 12m', NumberFormat.compactCurrency(symbol: '${_s.currency} ').format((sc['spend_12m'] as num) + (sc['freight_spend_12m'] as num))),
                ]),
                ...[
                  ('Contact', sp['contact_name']),
                  ('Email', sp['email']),
                  ('Website', sp['website']),
                  ('Tax ID', sp['tin']),
                  ('Currency', sp['currency']),
                  ('Payment terms', sp['payment_terms_days'] == null ? null : '${sp['payment_terms_days']} days'),
                  ('Lead time', sp['lead_time_days'] == null ? null : '${sp['lead_time_days']} days'),
                  ('AWB prefix', sp['iata_prefix']),
                  ('SCAC', sp['scac']),
                  ('Notes', sp['notes']),
                ].where((e) => e.$2 != null).map((e) => ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(e.$1), subtitle: Text('${e.$2}'))),
                const Divider(),
                Row(children: [Text('People', style: t.titleMedium), const Spacer(), IconButton(onPressed: _addContact, icon: const Icon(Icons.person_add_alt))]),
                for (final c in _contacts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(c['name'] as String),
                    subtitle: Text([c['role'], c['phone'], c['email']].whereType<String>().join(' · ')),
                    trailing: c['phone'] == null ? null : IconButton(icon: const Icon(Icons.chat_outlined), onPressed: () => openWhatsApp(c['phone'] as String)),
                  ),
                const Divider(),
                Row(children: [Text('Documents', style: t.titleMedium), const Spacer(), IconButton(onPressed: _addDoc, icon: const Icon(Icons.note_add_outlined))]),
                for (final d in _docs)
                  Builder(builder: (_) {
                    final exp = d['expires_on'] == null ? null : DateTime.parse(d['expires_on'] as String);
                    final expired = exp != null && exp.isBefore(DateTime.now());
                    final soon = exp != null && !expired && exp.isBefore(DateTime.now().add(const Duration(days: 30)));
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(expired ? Icons.error_outline : Icons.description_outlined, color: expired ? err : (soon ? Colors.orange : null)),
                      title: Text(d['title'] as String),
                      subtitle: Text([statusText(d['kind'] as String), if (d['doc_no'] != null) d['doc_no'], if (exp != null) '${expired ? 'expired' : 'expires'} ${DateFormat('d MMM yyyy').format(exp)}'].join(' · ')),
                      onLongPress: () async {
                        await _s.db.from('supplier_documents').delete().eq('id', d['id']);
                        _load();
                      },
                    );
                  }),
                const Divider(),
                Row(children: [
                  Text('Purchase orders', style: t.titleMedium),
                  const Spacer(),
                  if (sp['category'] == 'vendor')
                    IconButton(
                      onPressed: () async {
                        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PoScreen(supplierId: widget.supplierId)));
                        _load();
                      },
                      icon: const Icon(Icons.add_shopping_cart),
                    ),
                ]),
                for (final p in _pos)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${p['number']} · ${statusText(p['status'] as String)}'),
                    subtitle: Text(p['expected_at'] == null ? '' : 'expected ${p['expected_at']}'),
                    trailing: Text(_money.format(p['total'])),
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PoScreen(poId: p['id'] as String)));
                      _load();
                    },
                  ),
                const Divider(),
                Timeline(supplierId: widget.supplierId),
                const SizedBox(height: 40),
              ]),
            ),
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              FittedBox(child: Text(value, style: Theme.of(context).textTheme.titleMedium)),
            ]),
          ),
        ),
      );
}
