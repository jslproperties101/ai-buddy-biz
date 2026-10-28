import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';
import 'contact_form_screen.dart';
import 'contact_screen.dart';

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});
  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  String _q = '';
  String _filter = 'all';

  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var q = _s.db
          .from('contacts')
          .select('id, name, company, phone, email, lifecycle, tags, score, last_contacted_at, whatsapp_opt_in')
          .eq('tenant_id', _s.tenantId!)
          .inFilter('kind', ['customer', 'both']);
      if (_q.isNotEmpty) q = q.or('name.ilike.%$_q%,company.ilike.%$_q%,phone.ilike.%$_q%,email.ilike.%$_q%');
      q = switch (_filter) {
        'lead' => q.inFilter('lifecycle', ['lead', 'prospect']),
        'customer' => q.eq('lifecycle', 'customer'),
        'vip' => q.contains('tags', ['vip']),
        'hot' => q.gte('score', 50),
        _ => q,
      };
      final rows = await q.order(_filter == 'hot' ? 'score' : 'name', ascending: _filter != 'hot').limit(300);
      setState(() => _rows = List<Map<String, dynamic>>.from(rows));
    } on PostgrestException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Offline. Customers need a connection.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final id = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ContactFormScreen()));
    if (id != null) {
      await _load();
      if (mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ContactScreen(contactId: id)));
      await _load();
    }
  }

  Color _stageColor(String lifecycle) {
    final c = Theme.of(context).colorScheme;
    return switch (lifecycle) {
      'lead' => c.tertiary,
      'prospect' => c.secondary,
      'customer' => c.primary,
      _ => c.outline,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search name, company, phone, email',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => _q = v.trim(),
            onSubmitted: (_) => _load(),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            for (final f in const [('all', 'All'), ('lead', 'Leads'), ('customer', 'Customers'), ('hot', 'Hot (score 50+)'), ('vip', 'VIP')])
              Padding(
                padding: const EdgeInsets.only(right: 8),
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
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _rows.isEmpty
                      ? ListView(children: const [SizedBox(height: 80), Center(child: Text('No customers here yet'))])
                      : ListView.builder(
                          itemCount: _rows.length,
                          itemBuilder: (_, i) {
                            final r = _rows[i];
                            final name = (r['company'] as String?) ?? (r['name'] as String);
                            final lifecycle = r['lifecycle'] as String;
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: _stageColor(lifecycle).withValues(alpha: 0.15),
                                child: Text(name.isEmpty ? '?' : name[0].toUpperCase(),
                                    style: TextStyle(color: _stageColor(lifecycle))),
                              ),
                              title: Text(name),
                              subtitle: Text([
                                lifecycle,
                                if (r['company'] != null) r['name'],
                                r['phone'],
                                ...((r['tags'] as List?) ?? []).take(2),
                              ].whereType<String>().join(' · ')),
                              trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                Text('${r['score']}', style: Theme.of(context).textTheme.titleMedium),
                                Text('score', style: Theme.of(context).textTheme.labelSmall),
                              ]),
                              onTap: () async {
                                await Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => ContactScreen(contactId: r['id'] as String)));
                                _load();
                              },
                            );
                          },
                        ),
                ),
        ),
      ]),
      floatingActionButton: (_s.can('crm.contact.manage') || _s.can('crm.contact.create'))
          ? FloatingActionButton(onPressed: _add, child: const Icon(Icons.person_add_alt))
          : null,
    );
  }
}
