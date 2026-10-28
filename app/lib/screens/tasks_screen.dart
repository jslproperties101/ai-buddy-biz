import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';
import 'contact_screen.dart';

/// Follow-ups assigned to me (overdue first), including tasks from web leads.
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});
  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _everyone = false;

  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      var q = _s.db
          .from('activities')
          .select('id, subject, due_at, assigned_to, contact_id, contacts(name, company, phone)')
          .eq('tenant_id', _s.tenantId!)
          .eq('kind', 'task')
          .isFilter('done_at', null);
      if (!_everyone) q = q.or('assigned_to.eq.${_s.db.auth.currentUser!.id},assigned_to.is.null');
      final rows = await q.order('due_at', ascending: true, nullsFirst: false).limit(200);
      _rows = List<Map<String, dynamic>>.from(rows);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _done(Map<String, dynamic> t) async {
    try {
      await _s.db.from('activities').update({'done_at': DateTime.now().toUtc().toIso8601String()}).eq('id', t['id'] as String);
      setState(() => _rows.remove(t));
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Follow-ups'),
        actions: [
          if (_s.can('crm.deal.manage'))
            FilterChip(
              label: const Text('Everyone'),
              selected: _everyone,
              onSelected: (v) {
                setState(() => _everyone = v);
                _load();
              },
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _rows.isEmpty
                  ? ListView(children: const [SizedBox(height: 80), Center(child: Text('All caught up 🎉'))])
                  : ListView.builder(
                      itemCount: _rows.length,
                      itemBuilder: (_, i) {
                        final t = _rows[i];
                        final due = t['due_at'] == null ? null : DateTime.parse(t['due_at'] as String).toLocal();
                        final overdue = due != null && due.isBefore(now);
                        final c = t['contacts'];
                        return ListTile(
                          leading: Checkbox(value: false, onChanged: _s.can('crm.contact.manage') ? (_) => _done(t) : null),
                          title: Text(t['subject'] as String),
                          subtitle: Text([
                            if (c != null) (c['company'] ?? c['name']),
                            if (due != null) (overdue ? 'OVERDUE ' : 'due ') + DateFormat('d MMM, HH:mm').format(due),
                          ].join(' · '),
                              style: overdue ? TextStyle(color: Theme.of(context).colorScheme.error) : null),
                          onTap: t['contact_id'] == null
                              ? null
                              : () async {
                                  await Navigator.of(context).push(
                                      MaterialPageRoute(builder: (_) => ContactScreen(contactId: t['contact_id'] as String)));
                                  _load();
                                },
                        );
                      },
                    ),
            ),
    );
  }
}
