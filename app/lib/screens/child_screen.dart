import 'package:flutter/material.dart';

import '../services/kids.dart';
import '../services/session.dart';
import 'kids_screen.dart' show checkInDialog, checkOutDialog, giveMedicineDialog, showIncident;

/// One child for staff: today's log, family & pick-up, health (medicine, incidents), messages, profile.
class ChildScreen extends StatefulWidget {
  final String childId;
  const ChildScreen({super.key, required this.childId});
  @override
  State<ChildScreen> createState() => _ChildScreenState();
}

class _ChildScreenState extends State<ChildScreen> {
  Map<String, dynamic>? _c;
  Map<String, dynamic>? _att;
  List<Map<String, dynamic>> _logs = [];
  List<Map<String, dynamic>> _family = [];
  List<Map<String, dynamic>> _pickups = [];
  List<Map<String, dynamic>> _meds = [];
  List<Map<String, dynamic>> _incidents = [];
  DateTime _day = DateTime.now();
  bool _loading = true;
  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = Kids.isoDate(_day);
    final start = DateTime(_day.year, _day.month, _day.day);
    try {
      final r = await Future.wait([
        _s.db.from('children').select('*, kids_rooms(name), kids_fee_plans(name)').eq('id', widget.childId).single(),
        _s.db.from('kids_attendance').select().eq('child_id', widget.childId).eq('day', d).maybeSingle(),
        _s.db
            .from('kids_logs')
            .select()
            .eq('child_id', widget.childId)
            .gte('at', start.toUtc().toIso8601String())
            .lt('at', start.add(const Duration(days: 1)).toUtc().toIso8601String())
            .order('at', ascending: false),
        _s.db.from('child_guardians').select('*, guardians(*)').eq('child_id', widget.childId),
        _s.db.from('pickup_persons').select().eq('child_id', widget.childId).gte('valid_to', Kids.isoDate(DateTime.now())).order('valid_from'),
        _s.db.from('kids_med_authorisations').select().eq('child_id', widget.childId).order('created_at', ascending: false).limit(20),
        _s.db.from('kids_incidents').select().eq('child_id', widget.childId).order('occurred_at', ascending: false).limit(30),
      ]);
      _c = Map<String, dynamic>.from(r[0] as Map);
      _att = r[1] == null ? null : Map<String, dynamic>.from(r[1] as Map);
      _logs = List<Map<String, dynamic>>.from(r[2] as List);
      _family = List<Map<String, dynamic>>.from(r[3] as List);
      _pickups = List<Map<String, dynamic>>.from(r[4] as List);
      _meds = List<Map<String, dynamic>>.from(r[5] as List);
      _incidents = List<Map<String, dynamic>>.from(r[6] as List);
    } catch (e) {
      _snack(Kids.errorText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final c = _c;
    if (c == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Not found')));
    final cs = Theme.of(context).colorScheme;
    final allergy = (c['allergies'] ?? '').toString().trim();
    final medical = (c['medical_conditions'] ?? '').toString().trim();
    final inNow = _att?['check_in_at'] != null && _att?['check_out_at'] == null;
    final isToday = Kids.isoDate(_day) == Kids.isoDate(DateTime.now());
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text((c['preferred_name'] ?? c['full_name']) as String),
          actions: [
            if (_s.can('kids.manage'))
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChildEditScreen(child: c)));
                  _load();
                },
              ),
          ],
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(text: 'Day'),
            Tab(text: 'Family & pick-up'),
            Tab(text: 'Health'),
            Tab(text: 'Messages'),
            Tab(text: 'Profile'),
          ]),
        ),
        body: Column(children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(children: [
              KidsPhoto(path: c['photo_path'] as String?, size: 56),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c['full_name'] as String, style: Theme.of(context).textTheme.titleMedium),
                  Text('${c['child_no']} · ${Kids.age(c['dob'])} · ${(c['kids_rooms'] as Map?)?['name'] ?? 'no room'}'),
                  Text(
                    _att == null
                        ? 'Not in today'
                        : _att!['check_out_at'] != null
                            ? 'Picked up ${Kids.fmtTime(_att!['check_out_at'])} by ${_att!['picked_up_by']}'
                            : _att!['check_in_at'] != null
                                ? 'In since ${Kids.fmtTime(_att!['check_in_at'])}'
                                : '${_att!['status']}',
                    style: TextStyle(color: inNow ? Colors.green.shade700 : cs.outline),
                  ),
                ]),
              ),
              if (_s.can('kids.checkin') && isToday && _att?['check_out_at'] == null)
                inNow
                    ? OutlinedButton(
                        onPressed: () async {
                          if (await checkOutDialog(context, c) == true) _load();
                        },
                        child: const Text('Check out'))
                    : FilledButton(
                        onPressed: () async {
                          if (await checkInDialog(context, c) == true) _load();
                        },
                        child: const Text('Check in')),
            ]),
          ),
          if (allergy.isNotEmpty || medical.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(8)),
              child: Text([if (allergy.isNotEmpty) '⚠ Allergy: $allergy', if (medical.isNotEmpty) 'Medical: $medical'].join('\n'),
                  style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w600)),
            ),
          Expanded(
            child: TabBarView(children: [
              _dayTab(),
              _familyTab(),
              _healthTab(),
              KidsChat(childId: widget.childId, asParent: false),
              _profileTab(),
            ]),
          ),
        ]),
      ),
    );
  }

  // ───── Day ─────

  Widget _dayTab() {
    return Scaffold(
      floatingActionButton: _s.can('kids.log')
          ? FloatingActionButton.extended(
              heroTag: null,
              icon: const Icon(Icons.add),
              label: const Text('Log'),
              onPressed: () async {
                if (await addLogSheet(context, _c!) == true) _load();
              },
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () {
                  _day = _day.subtract(const Duration(days: 1));
                  _load();
                }),
            Text(Kids.day.format(_day), style: const TextStyle(fontWeight: FontWeight.w600)),
            IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: Kids.isoDate(_day) == Kids.isoDate(DateTime.now())
                    ? null
                    : () {
                        _day = _day.add(const Duration(days: 1));
                        _load();
                      }),
          ]),
          if (_att?['dropped_by'] != null || _att?['check_in_note'] != null)
            ListTile(
              dense: true,
              leading: const Icon(Icons.login),
              title: Text('Dropped off ${Kids.fmtTime(_att!['check_in_at'])}${_att!['dropped_by'] != null ? ' by ${_att!['dropped_by']}' : ''}'),
              subtitle: _att!['check_in_note'] != null ? Text('${_att!['check_in_note']}') : null,
            ),
          KidsTimeline(
            logs: _logs,
            showStaffOnly: true,
            onLongPress: (l) async {
              final del = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Delete this entry?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                  ],
                ),
              );
              if (del != true) return;
              try {
                final gone = await _s.db.from('kids_logs').delete().eq('id', l['id']).select('id');
                _snack((gone as List).isEmpty ? 'You can only delete your own entries' : 'Deleted');
              } catch (e) {
                _snack(Kids.errorText(e));
              }
              _load();
            },
          ),
        ]),
      ),
    );
  }

  // ───── Family & pick-up ─────

  Widget _familyTab() {
    final manage = _s.can('kids.manage');
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        ListTile(
          title: Text('Guardians', style: Theme.of(context).textTheme.titleMedium),
          trailing: manage ? TextButton.icon(onPressed: () => _editGuardian(), icon: const Icon(Icons.add), label: const Text('Add')) : null,
        ),
        for (final f in _family)
          ListTile(
            leading: Icon(f['can_pickup'] == true ? Icons.verified_user_outlined : Icons.block, color: f['can_pickup'] == true ? Colors.green.shade700 : Theme.of(context).colorScheme.error),
            title: Text('${f['guardians']['full_name']} (${f['relation']})'),
            subtitle: Text([
              if (f['guardians']['phone'] != null) f['guardians']['phone'],
              f['can_pickup'] == true ? 'can collect' : 'NOT allowed to collect',
              if (f['is_primary'] == true) 'primary',
              if (f['pays_fees'] == true) 'pays fees',
              if (f['emergency_contact'] == true) 'emergency contact',
              if (f['guardians']['user_id'] != null) 'uses the app',
            ].join(' · ')),
            onTap: manage ? () => _editGuardian(f) : null,
          ),
        const Divider(),
        ListTile(
          title: Text('Other people allowed to collect', style: Theme.of(context).textTheme.titleMedium),
          subtitle: const Text('Added by parents in the app, or by a manager. ID is checked at pick-up.'),
          trailing: manage ? TextButton.icon(onPressed: _addPickup, icon: const Icon(Icons.add), label: const Text('Add')) : null,
        ),
        if (_pickups.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('None.')),
        for (final p in _pickups)
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text('${p['full_name']}${p['relation'] != null ? ' (${p['relation']})' : ''}'),
            subtitle: Text('${p['valid_from']} → ${p['valid_to']} · ID ends ${p['id_last4'] ?? '—'}${p['phone'] != null ? ' · ${p['phone']}' : ''}'),
            trailing: manage
                ? IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await _s.db.from('pickup_persons').delete().eq('id', p['id']);
                      _load();
                    })
                : null,
          ),
      ]),
    );
  }

  Future<void> _editGuardian([Map<String, dynamic>? link]) async {
    final g = link?['guardians'] as Map?;
    final name = TextEditingController(text: (g?['full_name'] ?? '') as String);
    final phone = TextEditingController(text: (g?['phone'] ?? '') as String);
    final email = TextEditingController(text: (g?['email'] ?? '') as String);
    final id4 = TextEditingController(text: (g?['id_last4'] ?? '') as String);
    final relation = TextEditingController(text: (link?['relation'] ?? 'mother') as String);
    bool canPickup = (link?['can_pickup'] ?? true) as bool;
    bool primary = (link?['is_primary'] ?? _family.isEmpty) as bool;
    bool pays = (link?['pays_fees'] ?? _family.isEmpty) as bool;
    bool updates = (link?['receives_updates'] ?? true) as bool;
    bool emergency = (link?['emergency_contact'] ?? true) as bool;
    bool invite = g == null;
    final res = await showDialog<String>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(g == null ? 'Add guardian' : 'Edit guardian'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name (as on IC)')),
              TextField(controller: relation, decoration: const InputDecoration(labelText: 'Relation (mother, father, grandmother…)')),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
              TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email (for the parent app)')),
              TextField(controller: id4, maxLength: 4, decoration: const InputDecoration(labelText: 'Last 4 of IC/passport (pick-up check)')),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Allowed to collect'), value: canPickup, onChanged: (v) => set(() => canPickup = v)),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Primary contact'), value: primary, onChanged: (v) => set(() => primary = v)),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Pays the fees'), value: pays, onChanged: (v) => set(() => pays = v)),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Gets check-in/out messages'), value: updates, onChanged: (v) => set(() => updates = v)),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Emergency contact'), value: emergency, onChanged: (v) => set(() => emergency = v)),
              if (g == null || g['user_id'] == null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Invite to the parent app'),
                  subtitle: const Text('Sends an email; they sign up with the same address'),
                  value: invite,
                  onChanged: (v) => set(() => invite = v ?? false),
                ),
            ]),
          ),
          actions: [
            if (link != null) TextButton(onPressed: () => Navigator.pop(context, 'remove'), child: const Text('Remove')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (res == null) return;
    try {
      if (res == 'remove') {
        await _s.db.from('child_guardians').delete().eq('child_id', widget.childId).eq('guardian_id', g!['id']);
      } else {
        if (name.text.trim().length < 3) return _snack('Enter the full name');
        final data = {
          'full_name': name.text.trim(),
          'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
          'email': email.text.trim().isEmpty ? null : email.text.trim(),
          'id_last4': id4.text.trim().isEmpty ? null : id4.text.trim().toUpperCase(),
        };
        String gid;
        if (g == null) {
          // reuse an existing guardian with the same email (siblings)
          final existing = data['email'] == null
              ? null
              : await _s.db.from('guardians').select('id').eq('tenant_id', _s.tenantId!).eq('email', (data['email'] as String).toLowerCase()).maybeSingle();
          if (existing != null) {
            gid = existing['id'] as String;
          } else {
            gid = (await _s.db.from('guardians').insert({...data, 'tenant_id': _s.tenantId}).select('id').single())['id'] as String;
          }
        } else {
          gid = g['id'] as String;
          await _s.db.from('guardians').update(data).eq('id', gid);
        }
        await _s.db.from('child_guardians').upsert({
          'tenant_id': _s.tenantId,
          'child_id': widget.childId,
          'guardian_id': gid,
          'relation': relation.text.trim().isEmpty ? 'parent' : relation.text.trim(),
          'can_pickup': canPickup,
          'is_primary': primary,
          'pays_fees': pays,
          'receives_updates': updates,
          'emergency_contact': emergency,
        });
        if (invite && data['email'] != null) {
          await _s.db.rpc('invite_guardian', params: {'p_guardian': gid});
          _snack('Saved — app invitation sent to ${data['email']}');
        } else {
          _snack('Saved');
        }
      }
    } catch (e) {
      _snack(Kids.errorText(e));
    }
    _load();
  }

  Future<void> _addPickup() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final id4 = TextEditingController();
    final rel = TextEditingController();
    DateTime from = DateTime.now(), to = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Allow someone to collect'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Only add someone the parent has asked for in writing.', style: TextStyle(fontSize: 12)),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name')),
              TextField(controller: rel, decoration: const InputDecoration(labelText: 'Relation')),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
              TextField(controller: id4, maxLength: 4, decoration: const InputDecoration(labelText: 'Last 4 of IC/passport')),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${Kids.day.format(from)} → ${Kids.day.format(to)}'),
                trailing: const Icon(Icons.date_range),
                onTap: () async {
                  final r = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 60)),
                      initialDateRange: DateTimeRange(start: from, end: to));
                  if (r != null) set(() {
                    from = r.start;
                    to = r.end;
                  });
                },
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
    try {
      await _s.db.rpc('parent_add_pickup', params: {
        'p_child': widget.childId,
        'p_name': name.text,
        'p_phone': phone.text,
        'p_id_last4': id4.text.trim(),
        'p_relation': rel.text.trim().isEmpty ? null : rel.text.trim(),
        'p_from': Kids.isoDate(from),
        'p_to': Kids.isoDate(to),
      });
      _snack('Added');
    } catch (e) {
      _snack(Kids.errorText(e));
    }
    _load();
  }

  // ───── Health ─────

  Widget _healthTab() {
    final today = Kids.isoDate(DateTime.now());
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: _s.can('kids.incident')
          ? FloatingActionButton.extended(
              heroTag: null,
              icon: const Icon(Icons.report_outlined),
              label: const Text('Incident'),
              onPressed: _reportIncident,
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
          ListTile(
            title: Text('Medicine', style: Theme.of(context).textTheme.titleMedium),
            subtitle: const Text('Only give medicine a parent has authorised.'),
            trailing: _s.can('kids.manage')
                ? TextButton.icon(onPressed: _paperAuthorisation, icon: const Icon(Icons.add), label: const Text('Paper form'))
                : null,
          ),
          if (_meds.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('No medicine authorised.')),
          for (final m in _meds)
            Builder(builder: (_) {
              final active = m['status'] == 'active' && today.compareTo(m['start_date'] as String) >= 0 && today.compareTo(m['end_date'] as String) <= 0;
              return ListTile(
                leading: Icon(Icons.medication_outlined, color: active ? cs.primary : cs.outline),
                title: Text('${m['medicine']} — ${m['dose']}'),
                subtitle: Text('${m['times']}\n${m['start_date']} → ${m['end_date']} · ${m['authorised_via'] == 'paper' ? 'paper form' : 'authorised in app'}'
                    '${m['status'] == 'stopped' ? ' · stopped' : ''}'),
                isThreeLine: true,
                trailing: active && _s.can('kids.log')
                    ? FilledButton.tonal(
                        onPressed: () async {
                          if (await giveMedicineDialog(context, m) == true) _load();
                        },
                        child: const Text('Give'))
                    : null,
              );
            }),
          const Divider(),
          ListTile(title: Text('Incidents', style: Theme.of(context).textTheme.titleMedium)),
          if (_incidents.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('None.')),
          for (final i in _incidents)
            ListTile(
              leading: Icon(Icons.report_outlined, color: i['severity'] == 'high' ? cs.error : null),
              title: Text(Kids.incidentKinds[i['kind']] ?? '${i['kind']}'),
              subtitle: Text('${Kids.day.format(DateTime.parse(i['occurred_at'] as String).toLocal())} · ${i['description']}',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => showIncident(context, {...i, 'children': {'full_name': _c!['full_name']}}, onChanged: _load),
            ),
        ]),
      ),
    );
  }

  Future<void> _paperAuthorisation() async {
    final payers = _family.where((f) => true).toList();
    if (payers.isEmpty) return _snack('Add a guardian first');
    final med = TextEditingController();
    final dose = TextEditingController();
    final times = TextEditingController();
    final reason = TextEditingController();
    String gid = payers.first['guardians']['id'] as String;
    DateTime from = DateTime.now(), to = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Record a signed medicine form'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: gid,
                decoration: const InputDecoration(labelText: 'Signed by'),
                items: [for (final f in payers) DropdownMenuItem(value: f['guardians']['id'] as String, child: Text(f['guardians']['full_name'] as String))],
                onChanged: (v) => set(() => gid = v ?? gid),
              ),
              TextField(controller: med, decoration: const InputDecoration(labelText: 'Medicine (name & strength)')),
              TextField(controller: dose, decoration: const InputDecoration(labelText: 'Dose (e.g. 5 ml)')),
              TextField(controller: times, decoration: const InputDecoration(labelText: 'When (e.g. 12:00, or if temp ≥ 38°C)')),
              TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason')),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${Kids.day.format(from)} → ${Kids.day.format(to)}'),
                trailing: const Icon(Icons.date_range),
                onTap: () async {
                  final r = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime.now().subtract(const Duration(days: 1)),
                      lastDate: DateTime.now().add(const Duration(days: 90)),
                      initialDateRange: DateTimeRange(start: from, end: to));
                  if (r != null) set(() {
                    from = r.start;
                    to = r.end;
                  });
                },
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await _s.db.rpc('authorise_medicine', params: {
        'p_child': widget.childId,
        'p_medicine': med.text,
        'p_dose': dose.text,
        'p_times': times.text,
        'p_reason': reason.text.trim().isEmpty ? null : reason.text.trim(),
        'p_start': Kids.isoDate(from),
        'p_end': Kids.isoDate(to),
        'p_paper_guardian': gid,
      });
      _snack('Saved — keep the signed form on file');
    } catch (e) {
      _snack(Kids.errorText(e));
    }
    _load();
  }

  Future<void> _reportIncident() async {
    String kind = 'injury', severity = 'low';
    final desc = TextEditingController();
    final loc = TextEditingController();
    final aid = TextEditingController();
    final action = TextEditingController();
    final wit = TextEditingController();
    TimeOfDay at = TimeOfDay.now();
    bool notify = true;
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => StatefulBuilder(
        builder: (context, set) => Scaffold(
          appBar: AppBar(title: const Text('Report an incident'), actions: [
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            DropdownButtonFormField<String>(
              value: kind,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [for (final e in Kids.incidentKinds.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => set(() => kind = v ?? 'other'),
            ),
            if (kind == 'safeguarding')
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('This stays private to managers and is not sent to parents. Record only what you saw and heard, in the child\'s words.',
                    style: TextStyle(fontSize: 12)),
              ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'low', label: Text('Minor')),
                ButtonSegment(value: 'medium', label: Text('Moderate')),
                ButtonSegment(value: 'high', label: Text('Serious')),
              ],
              selected: {severity},
              onSelectionChanged: (v) => set(() => severity = v.first),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Time: ${at.format(context)} today'),
              trailing: const Icon(Icons.schedule),
              onTap: () async {
                final t = await showTimePicker(context: context, initialTime: at);
                if (t != null) set(() => at = t);
              },
            ),
            TextField(controller: loc, decoration: const InputDecoration(labelText: 'Where')),
            TextField(controller: desc, maxLines: 4, decoration: const InputDecoration(labelText: 'What happened (facts only)')),
            TextField(controller: aid, maxLines: 2, decoration: const InputDecoration(labelText: 'First aid given')),
            TextField(controller: action, maxLines: 2, decoration: const InputDecoration(labelText: 'Other action taken')),
            TextField(controller: wit, decoration: const InputDecoration(labelText: 'Witnesses')),
            if (kind != 'safeguarding')
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tell the parents now'),
                subtitle: const Text('They get a message and must acknowledge in the app'),
                value: notify,
                onChanged: (v) => set(() => notify = v),
              ),
          ]),
        ),
      ),
    ));
    if (ok != true) return;
    final now = DateTime.now();
    var when = DateTime(now.year, now.month, now.day, at.hour, at.minute);
    if (when.isAfter(now)) when = now;
    try {
      await _s.db.rpc('report_incident', params: {
        'p_child': widget.childId,
        'p_occurred': when.toUtc().toIso8601String(),
        'p_kind': kind,
        'p_severity': severity,
        'p_description': desc.text,
        'p_location': loc.text.trim().isEmpty ? null : loc.text.trim(),
        'p_first_aid': aid.text.trim().isEmpty ? null : aid.text.trim(),
        'p_action': action.text.trim().isEmpty ? null : action.text.trim(),
        'p_witnesses': wit.text.trim().isEmpty ? null : wit.text.trim(),
        'p_notify': notify,
      });
      _snack('Incident recorded');
    } catch (e) {
      _snack(Kids.errorText(e));
    }
    _load();
  }

  // ───── Profile ─────

  Widget _profileTab() {
    final c = _c!;
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final row = <(String, String?)>[
      ('Date of birth', '${c['dob']} (${Kids.age(c['dob'])})'),
      ('Status', '${c['status']}'),
      ('Started', c['start_date'] as String?),
      ('Days', [for (final d in (c['days'] as List? ?? const [])) days[(d as int) - 1]].join(', ')),
      ('Fee plan', (c['kids_fee_plans'] as Map?)?['name'] as String?),
      ('Dietary', c['dietary'] as String?),
      ('Photo consent', c['photo_consent'] == true ? 'Yes' : 'No — no photos in daily logs'),
      ('Notes', c['notes'] as String?),
    ];
    return ListView(padding: const EdgeInsets.all(8), children: [
      for (final r in row)
        if (r.$2 != null && r.$2!.isNotEmpty) ListTile(dense: true, title: Text(r.$1), subtitle: Text(r.$2!)),
      if (_s.can('kids.manage'))
        FutureBuilder(
          future: _s.db.from('child_private').select().eq('child_id', widget.childId).maybeSingle(),
          builder: (_, snap) {
            final p = snap.data;
            if (p == null) return const SizedBox();
            return Column(children: [
              for (final f in const [('id_no', 'MyKid / birth cert.'), ('address', 'Address'), ('doctor_name', 'Doctor'), ('doctor_phone', 'Doctor\'s phone'), ('immunisation_note', 'Immunisation')])
                if (p[f.$1] != null) ListTile(dense: true, title: Text(f.$2), subtitle: Text('${p[f.$1]}')),
            ]);
          },
        ),
    ]);
  }
}

/// Quick log sheet: one entry for this child (and optionally other children checked in now).
Future<bool?> addLogSheet(BuildContext context, Map<String, dynamic> child) async {
  final s = Session.instance;
  String kind = 'meal';
  final note = TextEditingController();
  final item = TextEditingController();
  final ml = TextEditingController();
  String amount = 'all';
  String nappy = 'wet';
  String mood = 'happy';
  TimeOfDay? napStart, napEnd;
  String? photo;
  bool visible = true;
  bool uploading = false;
  final others = <String>{};
  final today = Kids.isoDate(DateTime.now());
  final present = await s.db
      .from('kids_attendance')
      .select('child_id, children(full_name, preferred_name, photo_consent)')
      .eq('tenant_id', s.tenantId!)
      .eq('day', today)
      .not('check_in_at', 'is', null)
      .isFilter('check_out_at', null)
      .neq('child_id', child['id']);
  if (!context.mounted) return null;

  final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
    builder: (_) => StatefulBuilder(
      builder: (context, set) => Scaffold(
        appBar: AppBar(title: Text('Log for ${child['preferred_name'] ?? child['full_name']}'), actions: [
          TextButton(onPressed: uploading ? null : () => Navigator.pop(context, true), child: const Text('Save')),
        ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final k in Kids.logKinds.entries)
              if (k.key != 'medication')
                ChoiceChip(
                  avatar: Icon(k.value.$2, size: 18),
                  label: Text(k.value.$1),
                  selected: kind == k.key,
                  onSelected: (_) => set(() => kind = k.key),
                ),
          ]),
          const SizedBox(height: 12),
          if (kind == 'meal') ...[
            TextField(controller: item, decoration: const InputDecoration(labelText: 'What (e.g. Nasi lemak, apple)')),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'all', label: Text('All')),
                ButtonSegment(value: 'most', label: Text('Most')),
                ButtonSegment(value: 'some', label: Text('Some')),
                ButtonSegment(value: 'none', label: Text('None')),
              ],
              selected: {amount},
              onSelectionChanged: (v) => set(() => amount = v.first),
            ),
          ],
          if (kind == 'drink') ...[
            TextField(controller: item, decoration: const InputDecoration(labelText: 'What (milk, water…)')),
            TextField(controller: ml, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount (ml)')),
          ],
          if (kind == 'nap')
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final t = await showTimePicker(context: context, initialTime: napStart ?? TimeOfDay.now());
                    if (t != null) set(() => napStart = t);
                  },
                  child: Text(napStart == null ? 'Fell asleep' : 'From ${napStart!.format(context)}'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final t = await showTimePicker(context: context, initialTime: napEnd ?? TimeOfDay.now());
                    if (t != null) set(() => napEnd = t);
                  },
                  child: Text(napEnd == null ? 'Woke up' : 'To ${napEnd!.format(context)}'),
                ),
              ),
            ]),
          if (kind == 'nappy' || kind == 'toilet')
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'wet', label: Text('Wet')),
                ButtonSegment(value: 'dirty', label: Text('Dirty')),
                ButtonSegment(value: 'dry', label: Text('Dry')),
              ],
              selected: {nappy},
              onSelectionChanged: (v) => set(() => nappy = v.first),
            ),
          if (kind == 'mood')
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'happy', label: Text('😊')),
                ButtonSegment(value: 'okay', label: Text('🙂')),
                ButtonSegment(value: 'sad', label: Text('😢')),
                ButtonSegment(value: 'unwell', label: Text('🤒')),
              ],
              selected: {mood},
              onSelectionChanged: (v) => set(() => mood = v.first),
            ),
          if (kind == 'health')
            TextField(controller: ml, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Temperature °C')),
          if (kind == 'photo') ...[
            if (child['photo_consent'] != true)
              Text('No photo consent for this child.', style: TextStyle(color: Theme.of(context).colorScheme.error))
            else if (photo != null)
              KidsPhotoLarge(path: photo!)
            else
              OutlinedButton.icon(
                onPressed: uploading
                    ? null
                    : () async {
                        set(() => uploading = true);
                        try {
                          final p = await Kids.pickAndUpload(context, tenantId: s.tenantId!, childId: child['id'] as String);
                          set(() => photo = p);
                        } catch (e) {
                          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Kids.errorText(e))));
                        }
                        set(() => uploading = false);
                      },
                icon: const Icon(Icons.photo_camera),
                label: Text(uploading ? 'Uploading…' : 'Add photo'),
              ),
          ],
          const SizedBox(height: 8),
          TextField(controller: note, maxLines: 3, decoration: const InputDecoration(labelText: 'Note for parents')),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Parents can see this'),
            value: visible,
            onChanged: (v) => set(() => visible = v),
          ),
          if (present.isNotEmpty && kind != 'photo' && kind != 'health') ...[
            const Divider(),
            const Text('Also log for (checked in now):'),
            Wrap(spacing: 6, children: [
              for (final p in present)
                FilterChip(
                  label: Text((((p['children'] as Map?)?['preferred_name'] ?? (p['children'] as Map?)?['full_name']) ?? '') as String),
                  selected: others.contains(p['child_id']),
                  onSelected: (v) => set(() => v ? others.add(p['child_id'] as String) : others.remove(p['child_id'])),
                ),
            ]),
          ],
        ]),
      ),
    ),
  ));
  if (ok != true) return false;
  String fmt(TimeOfDay? t) => t == null ? '' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final Map<String, dynamic> detail = Map<String, dynamic>.from(switch (kind) {
    'meal' => {'item': item.text.trim(), 'amount': amount},
    'drink' => {'item': item.text.trim().isEmpty ? null : item.text.trim(), 'ml': int.tryParse(ml.text)},
    'nap' => {'start': napStart == null ? null : fmt(napStart), 'end': napEnd == null ? null : fmt(napEnd)},
    'nappy' || 'toilet' => {'type': nappy},
    'mood' => {'mood': mood},
    'health' => {'temperature': double.tryParse(ml.text.replaceAll(',', '.'))},
    _ => <String, dynamic>{},
  });
  detail.removeWhere((k, v) => v == null || v == '');
  if (kind == 'photo' && photo == null) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No photo added')));
    return false;
  }
  try {
    await s.db.from('kids_logs').insert([
      for (final id in [child['id'] as String, ...others])
        {
          'tenant_id': s.tenantId,
          'child_id': id,
          'kind': kind,
          'detail': detail,
          'note': note.text.trim().isEmpty ? null : note.text.trim(),
          if (photo != null) 'photo_path': photo,
          'visible_to_parents': visible,
        }
    ]);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Logged${others.isNotEmpty ? ' for ${others.length + 1} children' : ''}')));
    }
    return true;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Kids.errorText(e))));
    return false;
  }
}

/// Enrol or edit a child (managers).
class ChildEditScreen extends StatefulWidget {
  final Map<String, dynamic>? child;
  const ChildEditScreen({super.key, this.child});
  @override
  State<ChildEditScreen> createState() => _ChildEditScreenState();
}

class _ChildEditScreenState extends State<ChildEditScreen> {
  late final Map<String, TextEditingController> _t;
  final _p = <String, TextEditingController>{
    for (final k in const ['id_no', 'address', 'doctor_name', 'doctor_phone', 'immunisation_note']) k: TextEditingController(),
  };
  DateTime? _dob, _start;
  String? _room, _plan, _gender;
  String _status = 'enrolled';
  Set<int> _days = {1, 2, 3, 4, 5};
  bool _consent = false;
  String? _photo;
  List<Map<String, dynamic>> _rooms = [], _plans = [];
  bool _saving = false;
  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    final c = widget.child;
    _t = {
      for (final k in const ['full_name', 'preferred_name', 'allergies', 'dietary', 'medical_conditions', 'notes'])
        k: TextEditingController(text: (c?[k] ?? '') as String),
    };
    _dob = DateTime.tryParse('${c?['dob']}');
    _start = DateTime.tryParse('${c?['start_date']}') ?? (c == null ? DateTime.now() : null);
    _room = c?['room_id'] as String?;
    _plan = c?['fee_plan_id'] as String?;
    _gender = c?['gender'] as String?;
    _status = (c?['status'] ?? 'enrolled') as String;
    _days = {for (final d in (c?['days'] as List? ?? const [1, 2, 3, 4, 5])) d as int};
    _consent = (c?['photo_consent'] ?? false) as bool;
    _photo = c?['photo_path'] as String?;
    _loadLists();
  }

  Future<void> _loadLists() async {
    try {
      _rooms = List<Map<String, dynamic>>.from(await _s.db.from('kids_rooms').select().eq('tenant_id', _s.tenantId!).eq('active', true).order('min_age_months'));
      _plans = List<Map<String, dynamic>>.from(await _s.db.from('kids_fee_plans').select().eq('tenant_id', _s.tenantId!).eq('active', true).order('name'));
      if (widget.child != null) {
        final p = await _s.db.from('child_private').select().eq('child_id', widget.child!['id']).maybeSingle();
        if (p != null) {
          for (final e in _p.entries) {
            e.value.text = (p[e.key] ?? '') as String;
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    if (_t['full_name']!.text.trim().length < 3 || _dob == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter the full name and date of birth')));
      return;
    }
    setState(() => _saving = true);
    String? v(String k) => _t[k]!.text.trim().isEmpty ? null : _t[k]!.text.trim();
    final data = {
      'full_name': _t['full_name']!.text.trim(),
      'preferred_name': v('preferred_name'),
      'dob': Kids.isoDate(_dob!),
      'gender': _gender,
      'room_id': _room,
      'fee_plan_id': _plan,
      'status': _status,
      'start_date': _start == null ? null : Kids.isoDate(_start!),
      'days': (_days.toList()..sort()),
      'allergies': v('allergies'),
      'dietary': v('dietary'),
      'medical_conditions': v('medical_conditions'),
      'photo_consent': _consent,
      'photo_path': _photo,
      'notes': v('notes'),
    };
    try {
      String id;
      if (widget.child == null) {
        id = (await _s.db.from('children').insert({...data, 'tenant_id': _s.tenantId, 'outlet_id': _s.outlet?.id}).select('id').single())['id'] as String;
      } else {
        id = widget.child!['id'] as String;
        await _s.db.from('children').update(data).eq('id', id);
      }
      await _s.db.from('child_private').upsert({
        'child_id': id,
        'tenant_id': _s.tenantId,
        for (final e in _p.entries) e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim(),
      });
      if (!mounted) return;
      if (widget.child == null) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChildScreen(childId: id)));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enrolled — now add the guardians under Family & pick-up')));
      } else {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Kids.errorText(e))));
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final suggested = _dob == null
        ? null
        : _rooms.where((r) {
            final m = (DateTime.now().difference(_dob!).inDays / 30.44).floor();
            return m >= (r['min_age_months'] as int) && m < (r['max_age_months'] as int);
          }).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(widget.child == null ? 'Enrol a child' : 'Edit child'), actions: [
        TextButton(onPressed: _saving ? null : _save, child: const Text('Save')),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Center(
          child: InkWell(
            onTap: widget.child == null
                ? null
                : () async {
                    try {
                      final p = await Kids.pickAndUpload(context, tenantId: _s.tenantId!, childId: widget.child!['id'] as String);
                      if (p != null) setState(() => _photo = p);
                    } catch (e) {
                      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Kids.errorText(e))));
                    }
                  },
            child: Column(children: [
              KidsPhoto(path: _photo, size: 80),
              Text(widget.child == null ? 'Add a photo after saving' : 'Change photo', style: const TextStyle(fontSize: 12)),
            ]),
          ),
        ),
        TextField(controller: _t['full_name'], decoration: const InputDecoration(labelText: 'Full name (as on MyKid / birth certificate)')),
        TextField(controller: _t['preferred_name'], decoration: const InputDecoration(labelText: 'Called (short name)')),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_dob == null ? 'Date of birth' : 'Born ${Kids.day.format(_dob!)} (${Kids.age(Kids.isoDate(_dob!))})'),
          trailing: const Icon(Icons.cake_outlined),
          onTap: () async {
            final d = await showDatePicker(
                context: context, initialDate: _dob ?? DateTime.now().subtract(const Duration(days: 700)), firstDate: DateTime(DateTime.now().year - 14), lastDate: DateTime.now());
            if (d != null) setState(() => _dob = d);
          },
        ),
        DropdownButtonFormField<String?>(
          value: _gender,
          decoration: const InputDecoration(labelText: 'Gender'),
          items: const [
            DropdownMenuItem(value: null, child: Text('—')),
            DropdownMenuItem(value: 'female', child: Text('Girl')),
            DropdownMenuItem(value: 'male', child: Text('Boy')),
          ],
          onChanged: (v) => setState(() => _gender = v),
        ),
        DropdownButtonFormField<String?>(
          value: _rooms.any((r) => r['id'] == _room) ? _room : null,
          decoration: InputDecoration(labelText: 'Room', helperText: suggested != null && suggested['id'] != _room ? 'Suggested by age: ${suggested['name']}' : null),
          items: [
            const DropdownMenuItem(value: null, child: Text('—')),
            for (final r in _rooms) DropdownMenuItem(value: r['id'] as String, child: Text(r['name'] as String)),
          ],
          onChanged: (v) => setState(() => _room = v),
        ),
        DropdownButtonFormField<String>(
          value: _status,
          decoration: const InputDecoration(labelText: 'Status'),
          items: const [
            DropdownMenuItem(value: 'enquiry', child: Text('Enquiry')),
            DropdownMenuItem(value: 'waitlist', child: Text('Waitlist')),
            DropdownMenuItem(value: 'enrolled', child: Text('Enrolled')),
            DropdownMenuItem(value: 'withdrawn', child: Text('Left')),
          ],
          onChanged: (v) => setState(() => _status = v ?? 'enrolled'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_start == null ? 'Start date' : 'Starts ${Kids.day.format(_start!)}'),
          trailing: const Icon(Icons.event),
          onTap: () async {
            final d = await showDatePicker(
                context: context, initialDate: _start ?? DateTime.now(), firstDate: DateTime(2015), lastDate: DateTime.now().add(const Duration(days: 365)));
            if (d != null) setState(() => _start = d);
          },
        ),
        const Text('Days attending'),
        Wrap(spacing: 4, children: [
          for (var i = 1; i <= 7; i++)
            FilterChip(
              label: Text(dayNames[i - 1]),
              selected: _days.contains(i),
              onSelected: (v) => setState(() => v ? _days.add(i) : _days.remove(i)),
            ),
        ]),
        DropdownButtonFormField<String?>(
          value: _plans.any((p) => p['id'] == _plan) ? _plan : null,
          decoration: const InputDecoration(labelText: 'Fee plan'),
          items: [
            const DropdownMenuItem(value: null, child: Text('— not billed —')),
            for (final p in _plans) DropdownMenuItem(value: p['id'] as String, child: Text('${p['name']} (${_s.currency} ${(p['monthly_fee'] as num).toStringAsFixed(2)})')),
          ],
          onChanged: (v) => setState(() => _plan = v),
        ),
        const SizedBox(height: 12),
        Text('Health (shown to every carer)', style: Theme.of(context).textTheme.titleSmall),
        TextField(controller: _t['allergies'], decoration: const InputDecoration(labelText: 'Allergies (e.g. peanuts — EpiPen in bag)')),
        TextField(controller: _t['dietary'], decoration: const InputDecoration(labelText: 'Diet (halal, vegetarian, no dairy…)')),
        TextField(controller: _t['medical_conditions'], decoration: const InputDecoration(labelText: 'Medical conditions (asthma, G6PD…)')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Photo consent'),
          subtitle: const Text('Parent agreed (signed form or in the app) to photos in daily updates'),
          value: _consent,
          onChanged: (v) => setState(() => _consent = v),
        ),
        const SizedBox(height: 12),
        Text('Private (managers & the child\'s guardians only)', style: Theme.of(context).textTheme.titleSmall),
        TextField(controller: _p['id_no'], decoration: const InputDecoration(labelText: 'MyKid / birth certificate no.')),
        TextField(controller: _p['address'], maxLines: 2, decoration: const InputDecoration(labelText: 'Home address')),
        TextField(controller: _p['doctor_name'], decoration: const InputDecoration(labelText: 'Family doctor / clinic')),
        TextField(controller: _p['doctor_phone'], keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Doctor\'s phone')),
        TextField(controller: _p['immunisation_note'], decoration: const InputDecoration(labelText: 'Immunisation (as per buku rekod)')),
        TextField(controller: _t['notes'], maxLines: 3, decoration: const InputDecoration(labelText: 'Notes')),
        const SizedBox(height: 40),
      ]),
    );
  }
}
