import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

class SetupScreen extends StatefulWidget {
  final VoidCallback onDone;
  const SetupScreen({super.key, required this.onDone});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _name = TextEditingController();
  String _template = 'retail';
  bool _busy = false;
  String? _error;

  static const _templates = {
    'retail': ('Retail shop', Icons.shopping_bag_outlined),
    'cafe': ('Café / restaurant', Icons.local_cafe_outlined),
    'services': ('Services / salon', Icons.content_cut),
    'logistics': ('Shipping & cargo', Icons.local_shipping_outlined),
    'kids_care': ('Kids care centre', Icons.child_care),
  };

  Future<void> _create() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter your business name');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Session.instance.db.rpc('create_tenant', params: {'p_name': _name.text.trim(), 'p_template': _template});
      widget.onDone();
    } on PostgrestException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'No connection. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up your business'),
        actions: [IconButton(onPressed: Session.instance.signOut, icon: const Icon(Icons.logout))],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Business name', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 20),
        Text('What kind of business?', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final e in _templates.entries)
          Card(
            child: ListTile(
              leading: Icon(e.value.$2),
              title: Text(e.value.$1),
              trailing: _template == e.key ? const Icon(Icons.check_circle) : const Icon(Icons.circle_outlined),
              selected: _template == e.key,
              onTap: () => setState(() => _template = e.key),
            ),
          ),
        const SizedBox(height: 8),
        Text('You can turn modules on or off later.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_busy ? 'Creating…' : 'Create business'),
          ),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!)),
      ]),
    );
  }
}
