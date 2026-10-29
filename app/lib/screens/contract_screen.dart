import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/crm.dart';
import '../services/legal.dart';
import '../services/printing_service.dart';
import '../services/session.dart';
import '../widgets/contact_picker.dart';
import 'legal_ai_screen.dart';
import 'legal_screen.dart' show statusColor;

/// One contract: details, wording, signers, e-signing, key dates, AI review and the audit trail.
class ContractScreen extends StatefulWidget {
  final String contractId;
  const ContractScreen({super.key, required this.contractId});
  @override
  State<ContractScreen> createState() => _ContractScreenState();
}

class _ContractScreenState extends State<ContractScreen> {
  Map<String, dynamic>? _c;
  Map<String, dynamic>? _template;
  List<Map<String, dynamic>> _signers = [];
  List<Map<String, dynamic>> _events = [];
  List<Map<String, dynamic>> _dates = [];
  Map<String, dynamic>? _lastReview;
  bool _loading = true;
  bool _busy = false;
  AppSession get _s => AppSession.instance;

  String get _status => (_c?['status'] ?? 'draft') as String;
  bool get _editable => Legal.editable(_status) && _s.can('law.manage');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await _s.db.from('contracts').select('*, contacts(id, name, company, email, phone)').eq('id', widget.contractId).single();
      final results = await Future.wait([
        _s.db.from('contract_signers').select().eq('contract_id', widget.contractId).order('sign_order').order('name'),
        _s.db.from('contract_events').select().eq('contract_id', widget.contractId).order('at', ascending: false).limit(100),
        _s.db.from('legal_obligations').select().eq('contract_id', widget.contractId).order('due_date'),
        _s.db
            .from('ai_legal_results')
            .select()
            .eq('contract_id', widget.contractId)
            .eq('kind', 'review')
            .order('created_at', ascending: false)
            .limit(1),
      ]);
      _c = c;
      _signers = List<Map<String, dynamic>>.from(results[0]);
      _events = List<Map<String, dynamic>>.from(results[1]);
      _dates = List<Map<String, dynamic>>.from(results[2]);
      _lastReview = results[3].isEmpty ? null : results[3].first;
      if (c['template_id'] != null && _template?['id'] != c['template_id']) {
        _template = await _s.db.from('legal_templates').select().eq('id', c['template_id']).maybeSingle();
      }
    } catch (e) {
      _snack(Legal.errorText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<bool> _run(Future<void> Function() f, [String? ok]) async {
    setState(() => _busy = true);
    var success = true;
    try {
      await f();
      if (ok != null) _snack(ok);
    } catch (e) {
      success = false;
      _snack(Legal.errorText(e));
    }
    await _load();
    if (mounted) setState(() => _busy = false);
    return success;
  }

  Future<String?> _askText(String title, {String label = 'Reason', String initial = '', bool required = true, int lines = 1}) async {
    final t = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(controller: t, autofocus: true, maxLines: lines, decoration: InputDecoration(labelText: label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('OK')),
        ],
      ),
    );
    if (ok != true) return null;
    if (required && t.text.trim().isEmpty) return null;
    return t.text.trim();
  }

  // ───── Details ─────

  Future<void> _editDetails() async {
    final c = _c!;
    final title = TextEditingController(text: c['title'] as String);
    final value = TextEditingController(text: c['value']?.toString() ?? '');
    final notice = TextEditingController(text: c['notice_days']?.toString() ?? '');
    final law = TextEditingController(text: (c['governing_law'] ?? 'Malaysia') as String);
    final notes = TextEditingController(text: (c['notes'] ?? '') as String);
    String category = c['category'] as String;
    DateTime? start = DateTime.tryParse('${c['start_date']}');
    DateTime? end = DateTime.tryParse('${c['end_date']}');
    bool autoRenew = (c['auto_renew'] ?? false) as bool;
    Map<String, dynamic>? contact = c['contacts'] as Map<String, dynamic>?;

    Future<DateTime?> pick(DateTime? d) => showDatePicker(
        context: context,
        initialDate: d ?? DateTime.now(),
        firstDate: DateTime(2000),
        lastDate: DateTime.now().add(const Duration(days: 365 * 30)));

    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => StatefulBuilder(
        builder: (context, set) => Scaffold(
          appBar: AppBar(title: const Text('Contract details'), actions: [
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            TextField(
                controller: title,
                enabled: Legal.editable(_status),
                decoration: const InputDecoration(labelText: 'Title')),
            DropdownButtonFormField<String>(
              value: category,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [for (final e in Legal.categories.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => set(() => category = v ?? 'other'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_outline),
              title: Text(contact?['name'] as String? ?? 'Link a customer / other party'),
              subtitle: contact?['company'] != null ? Text(contact!['company'] as String) : null,
              trailing: contact == null
                  ? const Icon(Icons.chevron_right)
                  : IconButton(icon: const Icon(Icons.close), onPressed: () => set(() => contact = null)),
              onTap: () async {
                final p = await ContactPicker.show(context, title: 'Other party');
                if (p != null) set(() => contact = p);
              },
            ),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: value,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: 'Value (${c['currency'] ?? _s.currency})'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: notice,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Notice to end (days)'),
                ),
              ),
            ]),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(start == null ? 'Start date' : 'Starts ${Legal.dateFmt.format(start!)}'),
              trailing: const Icon(Icons.event),
              onTap: () async {
                final d = await pick(start);
                if (d != null) set(() => start = d);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(end == null ? 'End / expiry date (optional)' : 'Ends ${Legal.dateFmt.format(end!)}'),
              trailing: end == null
                  ? const Icon(Icons.event)
                  : IconButton(icon: const Icon(Icons.close), onPressed: () => set(() => end = null)),
              onTap: () async {
                final d = await pick(end ?? start);
                if (d != null) set(() => end = d);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Renews automatically'),
              value: autoRenew,
              onChanged: (v) => set(() => autoRenew = v),
            ),
            TextField(controller: law, decoration: const InputDecoration(labelText: 'Governing law')),
            TextField(controller: notes, maxLines: 3, decoration: const InputDecoration(labelText: 'Internal notes')),
            const SizedBox(height: 12),
            const Text('An end date and notice period add reminders to the Calendar automatically.', style: TextStyle(fontSize: 12)),
          ]),
        ),
      ),
    ));
    if (ok != true) return;
    if (start != null && end != null && end!.isBefore(start!)) {
      _snack('The end date is before the start date');
      return;
    }
    await _run(
        () async => _s.db.from('contracts').update({
              if (Legal.editable(_status)) 'title': title.text.trim().isEmpty ? c['title'] : title.text.trim(),
              'category': category,
              'contact_id': contact?['id'],
              'value': double.tryParse(value.text.replaceAll(',', '')),
              'notice_days': int.tryParse(notice.text),
              'start_date': start == null ? null : Legal.isoDate(start!),
              'end_date': end == null ? null : Legal.isoDate(end!),
              'auto_renew': autoRenew,
              'governing_law': law.text.trim().isEmpty ? 'Malaysia' : law.text.trim(),
              'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
            }).eq('id', widget.contractId),
        'Saved');
  }

  // ───── Wording ─────

  /// Fill the template's blanks (or the blanks left in the text) from a form.
  Future<void> _fillBlanks() async {
    final c = _c!;
    final fromTemplate = _template != null;
    final source = fromTemplate ? _template!['body'] as String : c['body'] as String;
    final keys = Legal.blanks(source);
    if (keys.isEmpty) {
      _snack('No blanks to fill');
      return;
    }
    final meta = {
      for (final v in (_template?['variables'] as List? ?? const [])) (v as Map)['key'] as String: Map<String, dynamic>.from(v)
    };
    final saved = Map<String, dynamic>.from((c['variables'] ?? {}) as Map);
    final company = await Legal.companyValues();
    final contact = c['contacts'] as Map?;
    String guess(String k) {
      if (saved[k] != null && '${saved[k]}'.isNotEmpty) return '${saved[k]}';
      if (company[k] != null && company[k]!.isNotEmpty) return company[k]!;
      if (contact != null) {
        if (k == 'counterparty_name' || k == 'customer_name' || k == 'client_name') {
          return (contact['company'] ?? contact['name'] ?? '') as String;
        }
      }
      return (meta[k]?['default'] ?? '').toString();
    }

    final ctrls = {for (final k in keys) k: TextEditingController(text: guess(k))};
    String label(String k) => (meta[k]?['label'] ?? k.replaceAll('_', ' ')).toString();
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Fill in the details'), actions: [
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Apply')),
        ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (fromTemplate)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Applying rebuilds the text from the template. Changes you typed straight into the text will be replaced.',
                  style: TextStyle(fontSize: 12)),
            ),
          for (final k in keys)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: meta[k]?['type'] == 'date'
                  ? _DateField(controller: ctrls[k]!, label: label(k))
                  : TextField(
                      controller: ctrls[k],
                      maxLines: meta[k]?['type'] == 'longtext' ? 3 : 1,
                      keyboardType: meta[k]?['type'] == 'number' || meta[k]?['type'] == 'money'
                          ? const TextInputType.numberWithOptions(decimal: true)
                          : null,
                      decoration: InputDecoration(labelText: label(k)),
                    ),
            ),
        ]),
      ),
    ));
    if (ok != true) return;
    final values = {for (final e in ctrls.entries) e.key: e.value.text.trim()};
    final body = Legal.fill(source, values);
    await _run(
        () async => _s.db.from('contracts').update({
              'body': body,
              'variables': {...saved, ...values}
            }).eq('id', widget.contractId),
        Legal.blanks(body).isEmpty ? 'All blanks filled' : '${Legal.blanks(body).length} blank(s) still empty');
  }

  Future<void> _editText() async {
    final t = TextEditingController(text: _c!['body'] as String);
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Edit text'), actions: [
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ]),
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: t,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'serif', fontSize: 15),
            decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Type or paste the contract text'),
          ),
        ),
      ),
    ));
    if (ok != true) return;
    await _run(() async => _s.db.from('contracts').update({'body': t.text}).eq('id', widget.contractId), 'Text saved');
  }

  // ───── Signers ─────

  Future<void> _editSigner([Map<String, dynamic>? sg]) async {
    final contact = _c!['contacts'] as Map?;
    final fresh = sg == null;
    final name = TextEditingController(text: (sg?['name'] ?? '') as String);
    final email = TextEditingController(text: (sg?['email'] ?? '') as String);
    final phone = TextEditingController(text: (sg?['phone'] ?? '') as String);
    final order = TextEditingController(text: '${sg?['sign_order'] ?? (_signers.isEmpty ? 1 : _signers.length + 1)}');
    String role = (sg?['role'] ?? (_signers.any((x) => x['role'] == 'company') ? 'counterparty' : 'company')) as String;
    bool code = (sg?['require_code'] ?? false) as bool;
    final res = await showDialog<String>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(fresh ? 'Add signer' : 'Edit signer'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (fresh && contact != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.person_add_alt),
                    label: Text('Use ${contact['name']}'),
                    onPressed: () => set(() {
                      name.text = contact['name'] as String;
                      email.text = (contact['email'] ?? '') as String;
                      phone.text = (contact['phone'] ?? '') as String;
                      role = 'counterparty';
                    }),
                  ),
                ),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name')),
              TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone (WhatsApp)')),
              DropdownButtonFormField<String>(
                value: role,
                decoration: const InputDecoration(labelText: 'Signs as'),
                items: const [
                  DropdownMenuItem(value: 'company', child: Text('Us (our company)')),
                  DropdownMenuItem(value: 'counterparty', child: Text('Other party')),
                  DropdownMenuItem(value: 'witness', child: Text('Witness')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (v) => set(() => role = v ?? 'counterparty'),
              ),
              TextField(
                controller: order,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Signing order', helperText: 'Same number = can sign at the same time'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Confirm with a 6-digit code'),
                subtitle: const Text('Sent by email or WhatsApp before signing'),
                value: code,
                onChanged: (v) => set(() => code = v),
              ),
            ]),
          ),
          actions: [
            if (!fresh) TextButton(onPressed: () => Navigator.pop(context, 'delete'), child: const Text('Remove')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (res == null) return;
    if (res == 'delete') {
      await _run(() async => _s.db.from('contract_signers').delete().eq('id', sg!['id']), 'Signer removed');
      return;
    }
    if (name.text.trim().length < 2) {
      _snack('Enter the signer\'s full name');
      return;
    }
    final e = email.text.trim().toLowerCase();
    if (e.isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e)) {
      _snack('That email doesn\'t look right');
      return;
    }
    if (code && e.isEmpty && phone.text.trim().isEmpty) {
      _snack('A code needs an email or phone to send to');
      return;
    }
    final data = {
      'name': name.text.trim(),
      'email': e.isEmpty ? null : e,
      'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
      'role': role,
      'sign_order': int.tryParse(order.text) ?? 1,
      'require_code': code,
    };
    await _run(() async {
      if (fresh) {
        await _s.db.from('contract_signers').insert({...data, 'tenant_id': _s.tenantId, 'contract_id': widget.contractId});
      } else {
        await _s.db.from('contract_signers').update(data).eq('id', sg!['id']);
      }
    }, 'Signer saved');
  }

  String _shareText(Map<String, dynamic> sg) =>
      'Hi ${(sg['name'] as String).split(' ').first}, ${_s.tenantName} has sent you "${_c!['title']}" (${_c!['number']}) to sign: '
      '${Legal.signLink(sg['token'] as String)}';

  Future<void> _shareSigner(Map<String, dynamic> sg) async {
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(sg['name'] as String), subtitle: const Text('Only share this link with this person — it lets them sign.')),
          ListTile(leading: const Icon(Icons.copy), title: const Text('Copy signing link'), onTap: () => Navigator.pop(context, 'copy')),
          if (sg['phone'] != null)
            ListTile(leading: const Icon(Icons.chat_outlined), title: const Text('Send on WhatsApp'), onTap: () => Navigator.pop(context, 'wa')),
          if (sg['email'] != null)
            ListTile(leading: const Icon(Icons.email_outlined), title: const Text('Send by email'), onTap: () => Navigator.pop(context, 'email')),
        ]),
      ),
    );
    switch (a) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: Legal.signLink(sg['token'] as String)));
        _snack('Link copied');
      case 'wa':
        await openWhatsApp(sg['phone'] as String, text: _shareText(sg));
      case 'email':
        await launchUrl(Uri(scheme: 'mailto', path: sg['email'] as String, queryParameters: {
          'subject': 'Please sign: ${_c!['title']}',
          'body': _shareText(sg),
        }));
    }
  }

  // ───── Actions ─────

  Future<void> _send() async {
    if (Legal.signBase().isEmpty) {
      _snack('The signing page address (SIGN_URL) isn\'t set up in this app build — see README, Batch G');
      return;
    }
    final blanks = Legal.blanks(_c!['body'] as String);
    if (blanks.isNotEmpty) {
      _snack('Fill in ${blanks.length} blank(s) first: ${blanks.take(3).join(', ')}${blanks.length > 3 ? '…' : ''}');
      return;
    }
    if (_signers.isEmpty) {
      _snack('Add at least one signer');
      return;
    }
    var notify = _signers.any((x) => x['email'] != null || x['phone'] != null);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Send for signature?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('The wording is locked and fingerprinted. To change it later you\'ll need to cancel signing, '
                'which makes the old links stop working.'),
            const SizedBox(height: 8),
            Text('Signers: ${_signers.map((x) => x['name']).join(', ')}'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Send links by email / WhatsApp'),
              subtitle: const Text('Uses your CRM messaging setup. You can also share links yourself.'),
              value: notify,
              onChanged: (v) => set(() => notify = v),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Send')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _run(
        () async => _s.db.rpc('send_for_signature',
            params: {'p_contract': widget.contractId, 'p_sign_base_url': Legal.signBase(), 'p_notify': notify}),
        notify ? 'Sent — links queued for each signer' : 'Ready — share each signer\'s link below');
  }

  Future<void> _more(String a) async {
    switch (a) {
      case 'review':
        await _run(() async => _s.db.from('contracts').update({'status': 'in_review'}).eq('id', widget.contractId), 'Marked in review');
      case 'draft':
        await _run(() async => _s.db.from('contracts').update({'status': 'draft'}).eq('id', widget.contractId), 'Back to draft');
      case 'version':
        final note = await _askText('Save a version', label: 'Note (optional)', required: false);
        if (note == null) return;
        await _run(() async => _s.db.rpc('save_contract_version', params: {'p_contract': widget.contractId, 'p_note': note.isEmpty ? null : note}),
            'Version saved');
      case 'cancel':
        final r = await _askText('Cancel signing', label: 'Why? (shown in the audit trail)');
        if (r == null) return;
        await _run(() async => _s.db.rpc('cancel_signing', params: {'p_contract': widget.contractId, 'p_reason': r}),
            'Signing cancelled — old links no longer work');
      case 'terminate':
        final r = await _askText('End this contract', label: 'Reason (e.g. notice given on …)');
        if (r == null || !mounted) return;
        final d = await showDatePicker(
            context: context,
            helpText: 'Ends on',
            initialDate: DateTime.now(),
            firstDate: DateTime.now().subtract(const Duration(days: 365)),
            lastDate: DateTime.now().add(const Duration(days: 365 * 2)));
        if (d == null) return;
        await _run(
            () async => _s.db.rpc('terminate_contract', params: {'p_contract': widget.contractId, 'p_reason': r, 'p_on': Legal.isoDate(d)}),
            'Contract ended');
      case 'expired':
        await _run(() async => _s.db.from('contracts').update({'status': 'expired'}).eq('id', widget.contractId), 'Marked expired');
      case 'delete':
        final sure = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete this draft?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
            ],
          ),
        );
        if (sure != true) return;
        try {
          await _s.db.from('contracts').delete().eq('id', widget.contractId);
          if (mounted) Navigator.pop(context);
        } catch (e) {
          _snack(Legal.errorText(e));
        }
      case 'versions':
        await _showVersions();
      case 'pdf':
        await _pdf();
    }
  }

  Future<void> _pdf() async {
    try {
      await PrintingService.printContract(
        contract: _c!,
        signers: _signers,
        events: _events.reversed.toList(),
        verifyUrl: _c!['content_hash'] != null && Legal.signBase().isNotEmpty ? Legal.verifyLink(_c!['content_hash'] as String) : null,
      );
    } catch (e) {
      _snack(Legal.errorText(e));
    }
  }

  Future<void> _showVersions() async {
    final rows = await _s.db
        .from('contract_versions')
        .select('version, title, body, note, created_at')
        .eq('contract_id', widget.contractId)
        .order('version', ascending: false);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Saved versions')),
        body: rows.isEmpty
            ? const Center(child: Text('No saved versions yet'))
            : ListView(children: [
                for (final v in rows)
                  ExpansionTile(
                    title: Text('Version ${v['version']}${v['note'] != null ? ' — ${v['note']}' : ''}'),
                    subtitle: Text(Legal.fmtDate(v['created_at'])),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(v['body'] as String, style: const TextStyle(fontFamily: 'serif')),
                      ),
                    ],
                  ),
              ]),
      ),
    ));
  }

  Future<void> _ai(String kind) async {
    if ((_c!['body'] as String).trim().length < 50) {
      _snack('Add the contract text first');
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await Legal.ai(kind, contractId: widget.contractId);
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AiReviewScreen(result: r, contractId: widget.contractId, canEdit: _s.can('law.manage'), datesOnly: kind == 'extract_dates')));
    } catch (e) {
      _snack(Legal.errorText(e));
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _addDate() async {
    final title = TextEditingController();
    String kind = 'deadline';
    DateTime? due;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Add a key date'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'What (e.g. 2nd instalment due)')),
            DropdownButtonFormField<String>(
              value: kind,
              items: [for (final e in Legal.obligationKinds.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => set(() => kind = v ?? 'deadline'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(due == null ? 'Pick date' : Legal.dateFmt.format(due!)),
              trailing: const Icon(Icons.event),
              onTap: () async {
                final d = await showDatePicker(
                    context: context,
                    initialDate: DateTime.now(),
                    firstDate: DateTime.now().subtract(const Duration(days: 365)),
                    lastDate: DateTime.now().add(const Duration(days: 365 * 10)));
                if (d != null) set(() => due = d);
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
    if (ok != true || due == null || title.text.trim().isEmpty) return;
    await _run(
        () async => _s.db.from('legal_obligations').insert({
              'tenant_id': _s.tenantId,
              'contract_id': widget.contractId,
              'title': title.text.trim(),
              'kind': kind,
              'due_date': Legal.isoDate(due!),
            }),
        'Added to the calendar');
  }

  // ───── UI ─────

  @override
  Widget build(BuildContext context) {
    if (_loading) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final c = _c;
    if (c == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Contract not found')));
    final body = c['body'] as String;
    final blanks = Legal.blanks(body);
    final signing = _status == 'out_for_signature' || _status == 'partially_signed';
    final cs = Theme.of(context).colorScheme;

    final menu = <(String, String)>[
      if (_status == 'draft' && _s.can('law.manage')) ('review', 'Mark in review'),
      if (_status == 'in_review' && _s.can('law.manage')) ('draft', 'Back to draft'),
      if (_editable) ('version', 'Save a version'),
      ('versions', 'Saved versions'),
      if (signing && _s.can('law.send')) ('cancel', 'Cancel signing'),
      if (_status == 'signed' && _s.can('law.manage')) ('terminate', 'End / terminate'),
      if (_status == 'signed' && _s.can('law.manage')) ('expired', 'Mark expired'),
      if (_status == 'draft' && _s.can('law.manage')) ('delete', 'Delete draft'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text((c['number'] ?? 'Contract') as String),
        actions: [
          IconButton(tooltip: 'PDF', icon: const Icon(Icons.picture_as_pdf_outlined), onPressed: _busy ? null : _pdf),
          PopupMenuButton<String>(
            onSelected: _more,
            itemBuilder: (_) => [for (final m in menu) PopupMenuItem(value: m.$1, child: Text(m.$2))],
          ),
        ],
        bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator()) : null,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 100), children: [
          Row(children: [
            Expanded(child: Text(c['title'] as String, style: Theme.of(context).textTheme.titleLarge)),
            Chip(
              label: Text(Legal.statusLabels[_status] ?? _status),
              labelStyle: TextStyle(color: statusColor(context, _status), fontWeight: FontWeight.w600),
            ),
          ]),
          if (c['e_signable'] == false)
            Card(
              color: cs.tertiaryContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('This kind of document can\'t be signed electronically in Malaysia (Electronic Commerce Act 2006). '
                    'Print it and sign by hand.'),
              ),
            ),
          // Details
          Card(
            child: ListTile(
              title: Text([
                Legal.categories[c['category']] ?? c['category'],
                if ((c['contacts'] as Map?)?['name'] != null) 'with ${(c['contacts'] as Map)['name']}',
              ].join(' · ')),
              subtitle: Text([
                if (c['value'] != null) '${c['currency'] ?? ''} ${(c['value'] as num).toStringAsFixed(2)}',
                if (c['start_date'] != null) 'from ${Legal.fmtDate(c['start_date'])}',
                if (c['end_date'] != null) 'to ${Legal.fmtDate(c['end_date'])}',
                if (c['auto_renew'] == true) 'auto-renews',
                if (c['notice_days'] != null) '${c['notice_days']} days\' notice',
                'law of ${c['governing_law']}',
              ].join(' · ')),
              trailing: _s.can('law.manage') ? const Icon(Icons.edit_outlined) : null,
              onTap: _s.can('law.manage') ? _editDetails : null,
            ),
          ),
          // Wording
          const SizedBox(height: 8),
          Row(children: [
            Text('Document', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            if (_editable && (blanks.isNotEmpty || _template != null))
              TextButton.icon(onPressed: _fillBlanks, icon: const Icon(Icons.edit_note), label: const Text('Fill in')),
            if (_editable) TextButton.icon(onPressed: _editText, icon: const Icon(Icons.edit_outlined), label: const Text('Edit')),
          ]),
          if (blanks.isNotEmpty)
            Text('${blanks.length} blank(s) to fill: ${blanks.join(', ')}', style: TextStyle(color: cs.error, fontSize: 12)),
          Container(
            constraints: const BoxConstraints(maxHeight: 320),
            decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant), borderRadius: BorderRadius.circular(8)),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(body.isEmpty ? 'No text yet — tap Edit to type or paste it.' : body,
                  style: const TextStyle(fontFamily: 'serif', fontSize: 14)),
            ),
          ),
          if (c['content_hash'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText('Fingerprint (SHA-256): ${c['content_hash']}', style: TextStyle(fontSize: 11, color: cs.outline)),
            ),
          // AI
          if (_s.can('law.ai')) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: _busy ? null : () => _ai('review'),
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('AI review')),
              OutlinedButton.icon(
                  onPressed: _busy ? null : () => _ai('extract_dates'),
                  icon: const Icon(Icons.event_note_outlined),
                  label: const Text('Find key dates')),
              if (_lastReview != null)
                TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => AiReviewScreen(
                          result: Map<String, dynamic>.from(_lastReview!['result'] as Map),
                          contractId: widget.contractId,
                          canEdit: _s.can('law.manage')))),
                  child: Text('Last review (${Legal.fmtDate(_lastReview!['created_at'])})'),
                ),
            ]),
          ],
          // Signers
          const SizedBox(height: 16),
          Row(children: [
            Text('Signers', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            if (_editable) TextButton.icon(onPressed: () => _editSigner(), icon: const Icon(Icons.person_add_alt), label: const Text('Add')),
          ]),
          if (_signers.isEmpty) const Text('No signers yet. Add yourself (for the company) and the other party.'),
          for (final sg in _signers)
            Card(
              child: ListTile(
                leading: CircleAvatar(child: Text('${sg['sign_order']}')),
                title: Text(sg['name'] as String),
                subtitle: Text([
                  {'company': 'Us', 'counterparty': 'Other party', 'witness': 'Witness'}[sg['role']] ?? 'Other',
                  _signerStatus(sg),
                  if (sg['require_code'] == true) 'code',
                  if (sg['decline_reason'] != null) '“${sg['decline_reason']}”',
                ].join(' · ')),
                trailing: sg['status'] == 'signed'
                    ? const Icon(Icons.verified, color: Colors.green)
                    : (signing && sg['token'] != null && _s.can('law.send'))
                        ? IconButton(tooltip: 'Share link', icon: const Icon(Icons.share_outlined), onPressed: () => _shareSigner(sg))
                        : null,
                onTap: _editable ? () => _editSigner(sg) : null,
              ),
            ),
          if (Legal.editable(_status) && _s.can('law.send') && c['e_signable'] != false) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _send,
              icon: const Icon(Icons.draw_outlined),
              label: const Text('Send for e-signature'),
            ),
          ],
          // Key dates
          const SizedBox(height: 16),
          Row(children: [
            Text('Key dates', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            if (_s.can('law.manage')) TextButton.icon(onPressed: _addDate, icon: const Icon(Icons.add), label: const Text('Add')),
          ]),
          if (_dates.isEmpty) const Text('None yet. Set an end date and notice period, or use “Find key dates”.'),
          for (final d in _dates)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(d['status'] == 'open' ? Icons.event_outlined : Icons.event_available, color: d['status'] == 'open' ? null : cs.outline),
              title: Text(d['title'] as String,
                  style: d['status'] == 'open' ? null : TextStyle(decoration: TextDecoration.lineThrough, color: cs.outline)),
              subtitle: Text('${Legal.fmtDate(d['due_date'])} · ${Legal.obligationKinds[d['kind']] ?? d['kind']}'
                  '${d['source'] == 'ai' ? ' · from AI' : d['source'] == 'system' ? ' · automatic' : ''}'),
              trailing: d['status'] == 'open' && (_s.can('law.manage') || _s.can('law.compliance'))
                  ? IconButton(
                      tooltip: 'Done',
                      icon: const Icon(Icons.check),
                      onPressed: () => _run(
                          () async => _s.db
                              .from('legal_obligations')
                              .update({'status': 'done', 'done_at': DateTime.now().toUtc().toIso8601String()}).eq('id', d['id']),
                          'Done ✓'))
                  : null,
            ),
          // Audit trail
          const SizedBox(height: 16),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Activity (${_events.length})', style: Theme.of(context).textTheme.titleMedium),
            children: [
              for (final e in _events)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${_eventLabel(e['event'] as String)}${e['detail'] != null ? ' — ${e['detail']}' : ''}'),
                  subtitle: Text('${Legal.fmtDate(e['at'])} ${_time(e['at'])}${e['ip'] != null ? ' · IP ${e['ip']}' : ''}'),
                ),
            ],
          ),
        ]),
      ),
    );
  }

  static String _time(dynamic v) {
    final d = DateTime.tryParse('$v')?.toLocal();
    return d == null ? '' : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  static String _signerStatus(Map<String, dynamic> sg) {
    switch (sg['status']) {
      case 'signed':
        return 'signed ${Legal.fmtDate(sg['signed_at'])}';
      case 'viewed':
        return 'opened the link';
      case 'declined':
        return 'declined';
      default:
        return sg['token'] == null ? 'not sent' : 'waiting';
    }
  }

  static String _eventLabel(String e) => const {
        'created': 'Created',
        'saved_version': 'Version saved',
        'sent': 'Sent for signature',
        'viewed': 'Opened by',
        'code_sent': 'Code sent to',
        'signed': 'Signed by',
        'declined': 'Declined by',
        'completed': 'Fully signed',
        'cancelled': 'Signing cancelled',
        'terminated': 'Terminated',
        'expired': 'Expired',
        'ai_review': 'AI review',
        'ai_extract_dates': 'AI found dates',
      }[e] ??
      e;
}

class _DateField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  const _DateField({required this.controller, required this.label});

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        readOnly: true,
        decoration: InputDecoration(labelText: label, suffixIcon: const Icon(Icons.event)),
        onTap: () async {
          final d = await showDatePicker(
              context: context,
              initialDate: DateTime.now(),
              firstDate: DateTime(2000),
              lastDate: DateTime.now().add(const Duration(days: 365 * 30)));
          if (d != null) controller.text = Legal.dateFmt.format(d);
        },
      );
}
