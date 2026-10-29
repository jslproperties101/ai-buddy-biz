import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/crm.dart';
import '../services/session.dart';
import '../widgets/timeline.dart';
import 'deal_screen.dart';

/// Add (contact == null) or edit a customer. Returns the saved row.
Future<Map<String, dynamic>?> editContact(BuildContext context, Map<String, dynamic>? contact) async {
  final s = AppSession.instance;
  final c = contact ?? {};
  TextEditingController t(String k) => TextEditingController(text: (c[k] ?? '').toString());
  final name = t('name'), phone = t('phone'), email = t('email'), company = t('company');
  final tin = t('tin'), regNo = t('reg_no'), notes = t('notes'), source = t('source');
  final tags = TextEditingController(text: ((c['tags'] as List?) ?? []).join(', '));
  var lifecycle = (c['lifecycle'] ?? 'lead') as String;
  var consent = (c['marketing_consent'] ?? false) as bool;
  DateTime? birthday = c['birthday'] == null ? null : DateTime.parse(c['birthday'] as String);
  final canEdit = s.can('crm.contact.manage') || (contact == null && s.can('crm.contact.create'));

  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (context, set) => AlertDialog(
        title: Text(contact == null ? 'New customer' : 'Edit customer'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name *')),
            TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone / WhatsApp')),
            TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
            TextField(controller: company, decoration: const InputDecoration(labelText: 'Company')),
            TextField(controller: tin, decoration: const InputDecoration(labelText: 'Tax ID / TIN')),
            TextField(controller: regNo, decoration: const InputDecoration(labelText: 'Business reg. no.')),
            TextField(controller: tags, decoration: const InputDecoration(labelText: 'Tags (comma separated)', hintText: 'vip, wholesale')),
            TextField(controller: source, decoration: const InputDecoration(labelText: 'Source', hintText: 'walk-in, facebook, referral…')),
            DropdownButtonFormField<String>(
              value: lifecycle,
              decoration: const InputDecoration(labelText: 'Stage'),
              items: const [
                DropdownMenuItem(value: 'lead', child: Text('Lead')),
                DropdownMenuItem(value: 'prospect', child: Text('Prospect')),
                DropdownMenuItem(value: 'customer', child: Text('Customer')),
                DropdownMenuItem(value: 'inactive', child: Text('Inactive')),
              ],
              onChanged: (v) => set(() => lifecycle = v!),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cake_outlined),
              title: Text(birthday == null ? 'Birthday' : DateFormat('d MMMM').format(birthday!)),
              trailing: birthday == null ? null : IconButton(icon: const Icon(Icons.clear), onPressed: () => set(() => birthday = null)),
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: birthday ?? DateTime(1990, 1, 1),
                  firstDate: DateTime(1900),
                  lastDate: DateTime.now(),
                );
                if (d != null) set(() => birthday = d);
              },
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: consent,
              onChanged: (v) => set(() => consent = v ?? false),
              title: const Text('Agrees to receive offers'),
              subtitle: const Text('Needed for campaigns', style: TextStyle(fontSize: 12)),
            ),
            TextField(controller: notes, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          if (canEdit) FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    ),
  );
  if (ok != true) return null;
  if (name.text.trim().isEmpty) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name is required')));
    return null;
  }
  String? v(TextEditingController x) => x.text.trim().isEmpty ? null : x.text.trim();
  final data = {
    'tenant_id': s.tenantId,
    'name': name.text.trim(),
    'phone': v(phone),
    'email': v(email)?.toLowerCase(),
    'company': v(company),
    'tin': v(tin),
    'reg_no': v(regNo),
    'notes': v(notes),
    'source': v(source),
    'tags': tags.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
    'lifecycle': lifecycle,
    'marketing_consent': consent,
    if (consent && !(c['marketing_consent'] ?? false)) 'consent_source': 'staff (app)',
    'birthday': birthday == null ? null : DateFormat('yyyy-MM-dd').format(birthday!),
  };
  try {
    if (contact == null) {
      return await s.db.from('contacts').insert({...data, 'kind': 'customer'}).select().single();
    }
    return await s.db.from('contacts').update(data).eq('id', contact['id']).select().single();
  } on PostgrestException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    return null;
  }
}

class ContactScreen extends StatefulWidget {
  final String contactId;
  const ContactScreen({super.key, required this.contactId});
  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  Map<String, dynamic>? _c;
  List<Map<String, dynamic>> _deals = [];
  List<Map<String, dynamic>> _sales = [];
  List<Map<String, dynamic>> _invoices = [];
  List<Map<String, dynamic>> _points = [];
  bool _loading = true;
  final _timeline = GlobalKey<TimelineState>();

  AppSession get _s => AppSession.instance;
  NumberFormat get _money => NumberFormat.currency(symbol: '${_s.currency} ');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = widget.contactId;
      _c = await _s.db.from('contacts').select().eq('id', id).single();
      if (_s.can('crm.deal.view')) {
        _deals = List<Map<String, dynamic>>.from(
            await _s.db.from('deal_board').select().eq('contact_id', id).order('created_at', ascending: false));
      }
      if (_s.can('pos.report.view') || _s.can('pos.sale.create')) {
        _sales = List<Map<String, dynamic>>.from(await _s.db
            .from('sales')
            .select('id, receipt_no, total, status, sold_at')
            .eq('customer_id', id)
            .order('sold_at', ascending: false)
            .limit(20));
      }
      if (_s.can('fin.invoice.view')) {
        _invoices = List<Map<String, dynamic>>.from(await _s.db
            .from('invoice_list')
            .select('id, number, status, total, balance, overdue')
            .eq('contact_id', id)
            .order('created_at', ascending: false)
            .limit(20));
      }
      _points = List<Map<String, dynamic>>.from(
          await _s.db.from('loyalty_ledger').select().eq('contact_id', id).order('at', ascending: false).limit(20));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load: $e')));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit() async {
    final r = await editContact(context, _c);
    if (r != null) _load();
  }

  Future<void> _adjustPoints() async {
    final pts = TextEditingController();
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Adjust points'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: pts,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            decoration: const InputDecoration(labelText: 'Points (+ to add, − to remove)'),
          ),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'Reason *')),
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
        'p_points': double.tryParse(pts.text) ?? 0,
        'p_note': note.text.trim(),
      });
      _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _sendWhatsAppViaBusiness() async {
    final body = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Send from business WhatsApp'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: body, maxLines: 4, decoration: const InputDecoration(labelText: 'Message')),
          const SizedBox(height: 8),
          const Text(
            'Free text only reaches customers who messaged you in the last 24 hours. '
            'Otherwise use "Open WhatsApp" or a campaign with an approved template.',
            style: TextStyle(fontSize: 12),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || body.text.trim().isEmpty) return;
    try {
      await _s.db.rpc('send_message', params: {'p_contact': widget.contactId, 'p_channel': 'whatsapp', 'p_body': body.text.trim()});
      _timeline.currentState?.reload();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Queued to send')));
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(c?['name'] as String? ?? ''),
        actions: [
          if (c != null && _s.can('crm.contact.manage')) IconButton(onPressed: _edit, icon: const Icon(Icons.edit_outlined)),
        ],
      ),
      body: _loading || c == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                if (c['company'] != null) Text(c['company'] as String, style: t.titleMedium),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  Chip(label: Text(c['lifecycle'] as String)),
                  if (c['marketing_consent'] == true) const Chip(avatar: Icon(Icons.check, size: 16), label: Text('Offers OK')),
                  for (final tag in ((c['tags'] as List?) ?? [])) Chip(label: Text('#$tag')),
                ]),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  if (c['phone'] != null) ...[
                    FilledButton.tonalIcon(onPressed: () => callPhone(c['phone'] as String), icon: const Icon(Icons.call), label: const Text('Call')),
                    FilledButton.tonalIcon(
                      onPressed: () => openWhatsApp(c['phone'] as String, text: 'Hi ${(c['name'] as String).split(' ').first}, '),
                      icon: const Icon(Icons.chat),
                      label: const Text('Open WhatsApp'),
                    ),
                  ],
                  if (c['email'] != null)
                    FilledButton.tonalIcon(onPressed: () => sendEmail(c['email'] as String), icon: const Icon(Icons.email), label: const Text('Email')),
                  if (c['phone'] != null && (_s.can('crm.deal.manage') || _s.can('crm.contact.manage')))
                    OutlinedButton.icon(
                      onPressed: _sendWhatsAppViaBusiness,
                      icon: const Icon(Icons.send_outlined),
                      label: const Text('Send from business'),
                    ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  _stat('Spent', _money.format(c['total_spent'])),
                  _stat('Visits', '${c['visits']}'),
                  _stat('Points', '${((c['loyalty_points'] ?? 0) as num).toInt()}',
                      onTap: _s.can('crm.loyalty.adjust') ? _adjustPoints : null),
                ]),
                if (c['last_purchase_at'] != null)
                  Text('Last purchase ${DateFormat('d MMM yyyy').format(DateTime.parse(c['last_purchase_at'] as String).toLocal())}',
                      style: t.bodySmall),
                const SizedBox(height: 8),
                ...[
                  if (c['phone'] != null) ('Phone', c['phone']),
                  if (c['email'] != null) ('Email', c['email']),
                  if (c['tin'] != null) ('TIN', c['tin']),
                  if (c['birthday'] != null) ('Birthday', DateFormat('d MMMM').format(DateTime.parse(c['birthday'] as String))),
                  if (c['source'] != null) ('Source', c['source']),
                  if (c['notes'] != null) ('Notes', c['notes']),
                ].map((e) => ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(e.$1), subtitle: Text('${e.$2}'))),
                const Divider(),
                if (_s.can('crm.deal.view')) ...[
                  Row(children: [
                    Text('Leads & deals', style: t.titleMedium),
                    const Spacer(),
                    if (_s.can('crm.deal.manage'))
                      TextButton.icon(
                        onPressed: () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => DealScreen(contactId: widget.contactId, contactName: c['name'] as String)));
                          _load();
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('New lead'),
                      ),
                  ]),
                  for (final d in _deals)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(d['title'] as String),
                      subtitle: Text('${d['stage_name']} · score ${d['score']}'),
                      trailing: Text(_money.format(d['value'])),
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => DealScreen(dealId: d['id'] as String)));
                        _load();
                      },
                    ),
                  if (_deals.isEmpty) const Text('None'),
                  const Divider(),
                ],
                Timeline(key: _timeline, contactId: widget.contactId),
                if (_sales.isNotEmpty) ...[
                  const Divider(),
                  Text('Purchases', style: t.titleMedium),
                  for (final sale in _sales)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(sale['receipt_no'] as String,
                          style: TextStyle(decoration: sale['status'] != 'completed' ? TextDecoration.lineThrough : null)),
                      subtitle: Text(DateFormat('d MMM yyyy').format(DateTime.parse(sale['sold_at'] as String).toLocal())),
                      trailing: Text(_money.format(sale['total'])),
                    ),
                ],
                if (_invoices.isNotEmpty) ...[
                  const Divider(),
                  Text('Invoices', style: t.titleMedium),
                  for (final i in _invoices)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(i['number'] as String? ?? 'Draft'),
                      subtitle: Text(i['overdue'] == true ? 'OVERDUE' : i['status'] as String),
                      trailing: Text(_money.format(i['total'])),
                    ),
                ],
                if (_points.isNotEmpty) ...[
                  const Divider(),
                  Text('Points history', style: t.titleMedium),
                  for (final p in _points)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${p['reason']}${p['note'] != null ? ' — ${p['note']}' : ''}'),
                      subtitle: Text(DateFormat('d MMM yyyy').format(DateTime.parse(p['at'] as String).toLocal())),
                      trailing: Text('${(p['points'] as num) > 0 ? '+' : ''}${(p['points'] as num).toInt()}'),
                    ),
                ],
                const SizedBox(height: 40),
              ]),
            ),
    );
  }

  Widget _stat(String label, String value, {VoidCallback? onTap}) => Expanded(
        child: Card(
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                  if (onTap != null) const Icon(Icons.edit, size: 12),
                ]),
                FittedBox(child: Text(value, style: Theme.of(context).textTheme.titleMedium)),
              ]),
            ),
          ),
        ),
      );
}
