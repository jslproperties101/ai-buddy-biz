import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

/// Bottom sheet to search customers or add a new one. Returns the chosen contact row.
class ContactPicker extends StatefulWidget {
  final String title;
  const ContactPicker({super.key, this.title = 'Search customers'});

  static Future<Map<String, dynamic>?> show(BuildContext context, {String title = 'Search customers'}) =>
      showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        builder: (_) => ContactPicker(title: title),
      );

  @override
  State<ContactPicker> createState() => _ContactPickerState();
}

class _ContactPickerState extends State<ContactPicker> {
  List<Map<String, dynamic>> _rows = [];
  String _q = '';
  bool _offline = false;
  Session get _s => Session.instance;
  bool get _canAdd => _s.can('crm.contact.create') || _s.can('crm.contact.manage');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var q = _s.db.from('contacts').select().eq('tenant_id', _s.tenantId!).inFilter('kind', ['customer', 'both']);
      final term = _q.replaceAll(RegExp(r'[,()%]'), ' ').trim();
      if (term.isNotEmpty) {
        final digits = term.replaceAll(RegExp(r'[^0-9]'), '');
        q = q.or([
          'name.ilike.%$term%',
          'company.ilike.%$term%',
          'email.ilike.%$term%',
          if (digits.length >= 3) 'phone.ilike.%${digits.substring(digits.length - (digits.length > 7 ? 7 : digits.length))}%',
        ].join(','));
      }
      final rows = await q.order('last_purchase_at', ascending: false, nullsFirst: false).limit(50);
      if (mounted) setState(() {
        _rows = List<Map<String, dynamic>>.from(rows);
        _offline = false;
      });
    } catch (_) {
      if (mounted) setState(() => _offline = true);
    }
  }

  Future<void> _new() async {
    final name = TextEditingController(text: RegExp(r'\d').hasMatch(_q) ? '' : _q);
    final phone = TextEditingController(text: RegExp(r'\d').hasMatch(_q) ? _q : '');
    final email = TextEditingController();
    final company = TextEditingController();
    final tin = TextEditingController();
    var consent = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('New customer'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name *')),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone / WhatsApp')),
              TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
              TextField(controller: company, decoration: const InputDecoration(labelText: 'Company (optional)')),
              TextField(controller: tin, decoration: const InputDecoration(labelText: 'Tax ID / TIN (for e-invoices)')),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: consent,
                onChanged: (v) => set(() => consent = v ?? false),
                title: const Text('Customer agrees to receive offers', style: TextStyle(fontSize: 14)),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (name.text.trim().isEmpty) {
      _snack('Name is required');
      return;
    }
    String? v(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    try {
      final row = await _s.db
          .from('contacts')
          .insert({
            'tenant_id': _s.tenantId,
            'kind': 'customer',
            'name': name.text.trim(),
            'phone': v(phone),
            'email': v(email)?.toLowerCase(),
            'company': v(company),
            'tin': v(tin),
            'source': 'walk-in',
            'marketing_consent': consent,
            if (consent) 'consent_source': 'in store',
          })
          .select()
          .single();
      if (mounted) Navigator.pop(context, row);
    } on PostgrestException catch (e) {
      _snack(e.message);
    } catch (_) {
      _snack('Adding a customer needs a connection');
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    autofocus: true,
                    decoration: InputDecoration(hintText: widget.title, prefixIcon: const Icon(Icons.search)),
                    onChanged: (v) {
                      _q = v.trim();
                      _load();
                    },
                  ),
                ),
                if (_canAdd) IconButton.filled(onPressed: _new, icon: const Icon(Icons.person_add_alt), tooltip: 'New customer'),
              ]),
            ),
            if (_offline) const ListTile(leading: Icon(Icons.cloud_off), title: Text('Offline — customer search needs a connection')),
            Expanded(
              child: ListView(children: [
                for (final c in _rows)
                  ListTile(
                    leading: CircleAvatar(child: Text((c['name'] as String).isEmpty ? '?' : (c['name'] as String)[0].toUpperCase())),
                    title: Text(c['company'] as String? ?? c['name'] as String),
                    subtitle: Text([
                      if (c['company'] != null) c['name'],
                      c['phone'],
                      if (((c['loyalty_points'] ?? 0) as num) > 0) '${(c['loyalty_points'] as num).toInt()} pts',
                    ].whereType<Object>().join(' · ')),
                    onTap: () => Navigator.pop(context, c),
                  ),
                if (_rows.isEmpty && !_offline)
                  ListTile(title: Text(_canAdd ? 'No match — tap + to add a customer' : 'No match')),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
