import 'package:flutter/material.dart';

import '../services/legal.dart';
import '../services/session.dart';

/// Registered company details used on contracts and documents.
class CompanyDetailsScreen extends StatefulWidget {
  const CompanyDetailsScreen({super.key});
  @override
  State<CompanyDetailsScreen> createState() => _CompanyDetailsScreenState();
}

class _CompanyDetailsScreenState extends State<CompanyDetailsScreen> {
  final _f = {
    'legal_name': TextEditingController(),
    'company_reg_no': TextEditingController(),
    'address': TextEditingController(),
    'phone': TextEditingController(),
    'email': TextEditingController(),
  };
  bool _loading = true;
  bool _saving = false;
  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await _s.db.from('tenants').select('name, ${_f.keys.join(', ')}').eq('id', _s.tenantId!).single();
      for (final e in _f.entries) {
        e.value.text = (t[e.key] ?? '').toString();
      }
      if (_f['legal_name']!.text.isEmpty) _f['legal_name']!.text = (t['name'] ?? '') as String;
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Legal.errorText(e))));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _s.db.from('tenants').update({
        for (final e in _f.entries) e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim(),
      }).eq('id', _s.tenantId!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Legal.errorText(e))));
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Company details'), actions: [
        TextButton(onPressed: _saving || _loading ? null : _save, child: const Text('Save')),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              const Text('These fill in {{company_name}}, {{company_reg_no}} and {{company_address}} on contracts.'),
              const SizedBox(height: 8),
              TextField(controller: _f['legal_name'], decoration: const InputDecoration(labelText: 'Registered name (as on SSM)')),
              TextField(
                  controller: _f['company_reg_no'],
                  decoration: const InputDecoration(labelText: 'Registration no.', hintText: 'e.g. 202301012345 (1234567-A)')),
              TextField(controller: _f['address'], maxLines: 3, decoration: const InputDecoration(labelText: 'Registered address')),
              TextField(controller: _f['phone'], keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
              TextField(controller: _f['email'], keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
            ]),
    );
  }
}
