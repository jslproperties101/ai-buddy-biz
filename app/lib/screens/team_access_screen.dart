import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

/// Who can sign in to this business, with which role; invite by email.
class TeamAccessScreen extends StatefulWidget {
  const TeamAccessScreen({super.key});
  @override
  State<TeamAccessScreen> createState() => _TeamAccessScreenState();
}

class _TeamAccessScreenState extends State<TeamAccessScreen> {
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _invites = [];
  List<Map<String, dynamic>> _roles = [];
  bool _loading = true;
  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        _s.db.rpc('team_members', params: {'p_tenant': _s.tenantId}),
        _s.db.from('invites').select('id, email, created_at, roles(name)').eq('tenant_id', _s.tenantId!).isFilter('accepted_at', null).order('created_at'),
        _s.db.from('roles').select('id, name, tenant_id').or('tenant_id.is.null,tenant_id.eq.${_s.tenantId}').order('name'),
      ]);
      _members = List<Map<String, dynamic>>.from(r[0] as List);
      _invites = List<Map<String, dynamic>>.from(r[1] as List);
      _roles = List<Map<String, dynamic>>.from(r[2] as List);
    } catch (e) {
      _snack(_err(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  String _err(Object e) => e is PostgrestException ? e.message : e.toString();

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  static const _roleHelp = {
    'Owner': 'Everything, including billing and owners',
    'Admin': 'Everything except owners',
    'Manager': 'Runs the outlet: sales, stock, staff, approvals',
    'Cashier': 'Sells at the counter',
    'Accountant': 'Invoices, payments, reports, tax',
    'HR': 'Staff records and payroll',
    'Warehouse': 'Stock and receiving',
    'Driver': 'Deliveries',
    'Carer': 'Kids care: check-in/out, daily logs, medicine, incidents',
    'Parent': 'Parent app only (their own children)',
    'Legal': 'Contracts and compliance',
    'Sales': 'Customers, deals, contracts',
    'Viewer': 'Read-only',
  };

  Future<String?> _pickRole(String? current) => showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (_) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
            child: ListView(shrinkWrap: true, children: [
              for (final r in _roles)
                ListTile(
                  title: Text(r['name'] as String),
                  subtitle: Text(_roleHelp[r['name']] ?? (r['tenant_id'] != null ? 'Custom role' : '')),
                  trailing: r['id'] == current ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(context, r['id'] as String),
                ),
            ]),
          ),
        ),
      );

  Future<void> _invite() async {
    final email = TextEditingController();
    String? role = _roles.where((r) => r['name'] == 'Cashier').firstOrNull?['id'] as String?;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Invite someone'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Their email')),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Role: ${_roles.where((r) => r['id'] == role).firstOrNull?['name'] ?? 'choose'}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final r = await _pickRole(role);
                if (r != null) set(() => role = r);
              },
            ),
            const Text('They sign up in the app with this email, confirm it, and get access automatically.', style: TextStyle(fontSize: 12)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Invite')),
          ],
        ),
      ),
    );
    if (ok != true || role == null) return;
    try {
      await _s.db.rpc('invite_user', params: {'p_tenant': _s.tenantId, 'p_email': email.text, 'p_role': role});
      _snack('Invited ${email.text.trim().toLowerCase()}');
    } catch (e) {
      _snack(_err(e));
    }
    _load();
  }

  Future<void> _edit(Map<String, dynamic> m) async {
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('${m['email'] ?? ''}'), subtitle: Text('${m['role_name']}${m['active'] == true ? '' : ' · no access'}')),
          ListTile(leading: const Icon(Icons.badge_outlined), title: const Text('Change role'), onTap: () => Navigator.pop(context, 'role')),
          ListTile(
            leading: Icon(m['active'] == true ? Icons.block : Icons.check_circle_outline),
            title: Text(m['active'] == true ? 'Remove access' : 'Give access again'),
            onTap: () => Navigator.pop(context, 'active'),
          ),
        ]),
      ),
    );
    if (a == null) return;
    String role = m['role_id'] as String;
    bool active = m['active'] as bool;
    if (a == 'role') {
      final r = await _pickRole(role);
      if (r == null) return;
      role = r;
    } else {
      active = !active;
    }
    try {
      await _s.db.rpc('set_member', params: {'p_membership': m['membership_id'], 'p_role': role, 'p_active': active});
      _snack('Saved');
    } catch (e) {
      _snack(_err(e));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final me = _s.db.auth.currentUser?.id;
    return Scaffold(
      appBar: AppBar(title: const Text('Team & access')),
      floatingActionButton: FloatingActionButton.extended(heroTag: null, onPressed: _invite, icon: const Icon(Icons.person_add_alt), label: const Text('Invite')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
                if (_invites.isNotEmpty) ...[
                  const ListTile(title: Text('Waiting to sign up')),
                  for (final i in _invites)
                    ListTile(
                      leading: const Icon(Icons.mail_outline),
                      title: Text(i['email'] as String),
                      subtitle: Text('${(i['roles'] as Map?)?['name'] ?? ''}'),
                      trailing: IconButton(
                        tooltip: 'Cancel invitation',
                        icon: const Icon(Icons.close),
                        onPressed: () async {
                          await _s.db.from('invites').delete().eq('id', i['id']);
                          _load();
                        },
                      ),
                    ),
                  const Divider(),
                ],
                const ListTile(title: Text('People with access')),
                for (final m in _members)
                  ListTile(
                    leading: Icon(m['active'] == true ? Icons.person_outline : Icons.person_off_outlined),
                    title: Text('${m['email'] ?? 'unknown'}${m['user_id'] == me ? ' (you)' : ''}'),
                    subtitle: Text('${m['role_name']}${m['active'] == true ? '' : ' · no access'}'),
                    onTap: m['user_id'] == me ? null : () => _edit(m),
                  ),
              ]),
            ),
    );
  }
}
