import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

/// Add or edit a customer. Returns the contact id when saved.
class ContactFormScreen extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final String? presetName;
  final String? presetPhone;
  const ContactFormScreen({super.key, this.existing, this.presetName, this.presetPhone});
  @override
  State<ContactFormScreen> createState() => _ContactFormScreenState();
}

class _ContactFormScreenState extends State<ContactFormScreen> {
  final _name = TextEditingController();
  final _company = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _tags = TextEditingController();
  final _tin = TextEditingController();
  final _reg = TextEditingController();
  final _notes = TextEditingController();
  String _lifecycle = 'customer';
  String? _source = 'walk_in';
  DateTime? _birthday;
  bool _wa = false;
  bool _em = false;
  bool _saving = false;

  Session get _s => Session.instance;
  bool get _isNew => widget.existing == null;

  static const _sources = {
    'walk_in': 'Walk-in',
    'referral': 'Referral',
    'whatsapp': 'WhatsApp',
    'web_form': 'Website form',
    'facebook': 'Facebook / Instagram',
    'event': 'Event',
    'cold_call': 'Cold call',
    'import': 'Imported',
    'other': 'Other',
  };

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = e['name'] as String;
      _company.text = (e['company'] ?? '') as String;
      _phone.text = (e['phone'] ?? '') as String;
      _email.text = (e['email'] ?? '') as String;
      _tags.text = ((e['tags'] as List?) ?? []).join(', ');
      _tin.text = (e['tin'] ?? '') as String;
      _reg.text = (e['reg_no'] ?? '') as String;
      _notes.text = (e['notes'] ?? '') as String;
      _lifecycle = e['lifecycle'] as String;
      _source = e['source'] as String?;
      _birthday = e['birthday'] == null ? null : DateTime.parse(e['birthday'] as String);
      _wa = e['whatsapp_opt_in'] as bool;
      _em = e['email_opt_in'] as bool;
    } else {
      _name.text = widget.presetName ?? '';
      _phone.text = widget.presetPhone ?? '';
    }
  }

  String? _nz(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _snack('Name is required');
      return;
    }
    setState(() => _saving = true);
    final data = {
      'tenant_id': _s.tenantId,
      'name': _name.text.trim(),
      'company': _nz(_company),
      'phone': _nz(_phone),
      'email': _nz(_email),
      'tags': _tags.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
      'tin': _nz(_tin),
      'reg_no': _nz(_reg),
      'notes': _nz(_notes),
      'lifecycle': _lifecycle,
      'source': _source,
      'birthday': _birthday == null ? null : DateFormat('yyyy-MM-dd').format(_birthday!),
      'whatsapp_opt_in': _wa,
      'email_opt_in': _em,
      if (_wa || _em) 'consent_source': 'Recorded in app by ${_s.roleName}',
    };
    try {
      final String id;
      if (_isNew) {
        final r = await _s.db.from('contacts').insert(data).select('id').single();
        id = r['id'] as String;
      } else {
        await _s.db.from('contacts').update(data).eq('id', widget.existing!['id'] as String);
        id = widget.existing!['id'] as String;
      }
      if (mounted) Navigator.of(context).pop(id);
    } on PostgrestException catch (e) {
      _snack(e.code == '23505' ? 'A customer with this phone number already exists.' : e.message);
    } catch (e) {
      _snack('Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    InputDecoration d(String l, {String? h}) => InputDecoration(labelText: l, helperText: h, border: const OutlineInputBorder());
    const gap = SizedBox(height: 12);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New customer' : 'Edit customer'),
        actions: [TextButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save'))],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _name, decoration: d('Name *'), textCapitalization: TextCapitalization.words),
        gap,
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: d('Phone', h: 'Local (012…) or international (+60…). Used for WhatsApp.'),
        ),
        gap,
        TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: d('Email')),
        gap,
        TextField(controller: _company, decoration: d('Company (optional)')),
        gap,
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _lifecycle,
              decoration: d('Stage'),
              items: const [
                DropdownMenuItem(value: 'lead', child: Text('Lead')),
                DropdownMenuItem(value: 'prospect', child: Text('Prospect')),
                DropdownMenuItem(value: 'customer', child: Text('Customer')),
                DropdownMenuItem(value: 'inactive', child: Text('Inactive')),
              ],
              onChanged: (v) => setState(() => _lifecycle = v!),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String?>(
              value: _sources.containsKey(_source) ? _source : null,
              isExpanded: true,
              decoration: d('Source'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('—')),
                for (final e in _sources.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _source = v),
            ),
          ),
        ]),
        gap,
        TextField(controller: _tags, decoration: d('Tags', h: 'Comma separated, e.g. vip, wholesale, halal')),
        gap,
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cake_outlined),
          title: Text(_birthday == null ? 'Birthday (optional)' : DateFormat('d MMMM').format(_birthday!)),
          onTap: () async {
            final b = await showDatePicker(
              context: context,
              initialDate: _birthday ?? DateTime(1990, 1, 1),
              firstDate: DateTime(1920),
              lastDate: DateTime.now(),
            );
            if (b != null) setState(() => _birthday = b);
          },
        ),
        const Divider(),
        Text('Marketing consent', style: Theme.of(context).textTheme.titleMedium),
        const Text('Only tick these if the customer agreed. Campaigns only go to people who opted in.',
            style: TextStyle(fontSize: 12)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('WhatsApp messages'),
          value: _wa,
          onChanged: (v) => setState(() => _wa = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Email messages'),
          value: _em,
          onChanged: (v) => setState(() => _em = v),
        ),
        const Divider(),
        TextField(controller: _tin, decoration: d('Tax ID (TIN)', h: 'For B2B invoices and e-invoicing')),
        gap,
        TextField(controller: _reg, decoration: d('Business registration no.')),
        gap,
        TextField(controller: _notes, maxLines: 3, decoration: d('Notes')),
        const SizedBox(height: 40),
      ]),
    );
  }
}
