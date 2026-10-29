import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/kids.dart';
import '../services/session.dart';

/// Parent app: my children today, daily updates & photos, messages, medicine, incidents, pick-up, absences, fees.
class ParentScreen extends StatefulWidget {
  const ParentScreen({super.key});
  @override
  State<ParentScreen> createState() => _ParentScreenState();
}

class _ParentScreenState extends State<ParentScreen> {
  List<Map<String, dynamic>> _kids = [];
  bool _loading = true;
  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _kids = List<Map<String, dynamic>>.from(await _s.db.rpc('my_children') as List);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Kids.errorText(e))));
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        if (_kids.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No children linked to your login yet. Ask the centre to add you as a guardian with this email.',
                textAlign: TextAlign.center),
          ),
        for (final k in _kids)
          Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ParentChildScreen(child: k)));
                _load();
              },
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  KidsPhoto(path: k['photo_path'] as String?, size: 64),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text((k['preferred_name'] ?? k['full_name']) as String, style: Theme.of(context).textTheme.titleMedium),
                      Text('${k['business']}${k['room'] != null ? ' · ${k['room']}' : ''}', style: const TextStyle(fontSize: 12)),
                      const SizedBox(height: 4),
                      Text(_statusText(k), style: TextStyle(fontWeight: FontWeight.w600, color: _statusColor(context, k))),
                    ]),
                  ),
                  if ((k['unread'] as int? ?? 0) > 0) Badge(label: Text('${k['unread']}'), child: const Icon(Icons.chat_bubble_outline)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  static String _statusText(Map<String, dynamic> k) => switch (k['today_status']) {
        'in' => 'At the centre since ${Kids.fmtTime(k['check_in_at'])}',
        'picked_up' => 'Collected at ${Kids.fmtTime(k['check_out_at'])} by ${k['picked_up_by']}',
        'sick' => 'Marked off sick today',
        'holiday' => 'On holiday today',
        'absent' => 'Marked absent today',
        _ => 'Not checked in today',
      };

  static Color _statusColor(BuildContext context, Map<String, dynamic> k) =>
      k['today_status'] == 'in' ? Colors.green.shade700 : Theme.of(context).colorScheme.outline;
}

class ParentChildScreen extends StatefulWidget {
  final Map<String, dynamic> child;
  const ParentChildScreen({super.key, required this.child});
  @override
  State<ParentChildScreen> createState() => _ParentChildScreenState();
}

class _ParentChildScreenState extends State<ParentChildScreen> {
  DateTime _day = DateTime.now();
  List<Map<String, dynamic>> _logs = [];
  List<Map<String, dynamic>> _meds = [];
  List<Map<String, dynamic>> _given = [];
  List<Map<String, dynamic>> _incidents = [];
  List<Map<String, dynamic>> _family = [];
  List<Map<String, dynamic>> _pickups = [];
  List<Map<String, dynamic>> _invoices = [];
  Map<String, dynamic>? _att;
  bool _consent = false;
  bool _loading = true;
  Session get _s => Session.instance;
  String get _id => widget.child['child_id'] as String;
  String get _name => (widget.child['preferred_name'] ?? widget.child['full_name']) as String;

  @override
  void initState() {
    super.initState();
    _consent = widget.child['photo_consent'] == true;
    _load();
  }

  Future<void> _load() async {
    final start = DateTime(_day.year, _day.month, _day.day);
    try {
      // only this parent's own fee invoices (by the contact behind their guardian records)
      final mine = await _s.db.from('guardians').select('contact_id').eq('user_id', _s.db.auth.currentUser!.id);
      final contacts = [for (final g in mine) if (g['contact_id'] != null) g['contact_id'] as String];
      final r = await Future.wait([
        _s.db
            .from('kids_logs')
            .select()
            .eq('child_id', _id)
            .gte('at', start.toUtc().toIso8601String())
            .lt('at', start.add(const Duration(days: 1)).toUtc().toIso8601String())
            .order('at', ascending: false),
        _s.db.from('kids_attendance').select().eq('child_id', _id).eq('day', Kids.isoDate(_day)).maybeSingle(),
        _s.db.from('kids_med_authorisations').select().eq('child_id', _id).order('created_at', ascending: false).limit(20),
        _s.db.from('kids_med_given').select().eq('child_id', _id).order('given_at', ascending: false).limit(30),
        _s.db.from('kids_incidents').select().eq('child_id', _id).order('occurred_at', ascending: false).limit(30),
        _s.db.from('child_guardians').select('relation, can_pickup, guardians(id, full_name, user_id)').eq('child_id', _id),
        _s.db.from('pickup_persons').select().eq('child_id', _id).gte('valid_to', Kids.isoDate(DateTime.now())),
        _s.db
            .from('invoices')
            .select('id, number, status, issue_date, due_date, total, amount_paid, notes')
            .inFilter('contact_id', contacts.isEmpty ? ['00000000-0000-0000-0000-000000000000'] : contacts)
            .neq('status', 'draft')
            .order('issue_date', ascending: false)
            .limit(24),
      ]);
      _logs = List<Map<String, dynamic>>.from(r[0] as List);
      _att = r[1] == null ? null : Map<String, dynamic>.from(r[1] as Map);
      _meds = List<Map<String, dynamic>>.from(r[2] as List);
      _given = List<Map<String, dynamic>>.from(r[3] as List);
      _incidents = List<Map<String, dynamic>>.from(r[4] as List);
      _family = List<Map<String, dynamic>>.from(r[5] as List);
      _pickups = List<Map<String, dynamic>>.from(r[6] as List);
      _invoices = List<Map<String, dynamic>>.from(r[7] as List);
    } catch (e) {
      _snack(Kids.errorText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _rpc(String fn, Map<String, dynamic> params, String ok) async {
    try {
      await _s.db.rpc(fn, params: params);
      _snack(ok);
    } catch (e) {
      _snack(Kids.errorText(e));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final openIncidents = _incidents.where((i) => i['guardian_ack_at'] == null).length;
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_name),
          bottom: TabBar(isScrollable: true, tabs: [
            const Tab(text: 'Today'),
            const Tab(text: 'Messages'),
            Tab(child: Badge(isLabelVisible: openIncidents > 0, label: Text('$openIncidents'), child: const Text('Health'))),
            const Tab(text: 'Pick-up & absence'),
            const Tab(text: 'Fees'),
          ]),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(children: [
                _today(),
                KidsChat(childId: _id, asParent: true),
                _health(),
                _pickup(),
                _fees(),
              ]),
      ),
    );
  }

  Widget _today() {
    final isToday = Kids.isoDate(_day) == Kids.isoDate(DateTime.now());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () {
                _day = _day.subtract(const Duration(days: 1));
                _load();
              }),
          Text(isToday ? 'Today' : Kids.day.format(_day), style: const TextStyle(fontWeight: FontWeight.w600)),
          IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: isToday
                  ? null
                  : () {
                      _day = _day.add(const Duration(days: 1));
                      _load();
                    }),
        ]),
        if (_att != null)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            child: ListTile(
              leading: const Icon(Icons.how_to_reg_outlined),
              title: Text(_att!['check_in_at'] != null
                  ? 'Arrived ${Kids.fmtTime(_att!['check_in_at'])}${_att!['dropped_by'] != null ? ' with ${_att!['dropped_by']}' : ''}'
                  : 'Marked ${_att!['status']}'),
              subtitle: _att!['check_out_at'] != null
                  ? Text('Collected ${Kids.fmtTime(_att!['check_out_at'])} by ${_att!['picked_up_by']}'
                      '${(_att!['late_minutes'] ?? 0) > 0 ? ' (${_att!['late_minutes']} min after closing)' : ''}')
                  : null,
            ),
          ),
        KidsTimeline(logs: _logs),
      ]),
    );
  }

  Widget _health() {
    final cs = Theme.of(context).colorScheme;
    final today = Kids.isoDate(DateTime.now());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        ListTile(
          title: Text('Medicine', style: Theme.of(context).textTheme.titleMedium),
          subtitle: const Text('Staff only give medicine you authorise here. Send the medicine in its original box with your child\'s name.'),
          trailing: TextButton.icon(onPressed: _authorise, icon: const Icon(Icons.add), label: const Text('Authorise')),
        ),
        for (final m in _meds)
          ListTile(
            leading: const Icon(Icons.medication_outlined),
            title: Text('${m['medicine']} — ${m['dose']}'),
            subtitle: Text('${m['times']} · ${m['start_date']} → ${m['end_date']}'
                '${m['status'] == 'stopped' ? ' · stopped' : ''}\n'
                'Given: ${_given.where((g) => g['authorisation_id'] == m['id']).map((g) => '${Kids.day.format(DateTime.parse(g['given_at'] as String).toLocal())} ${Kids.fmtTime(g['given_at'])}').take(4).join(', ').ifEmpty('not yet')}'),
            isThreeLine: true,
            trailing: m['status'] == 'active' && (m['end_date'] as String).compareTo(today) >= 0
                ? TextButton(
                    onPressed: () async {
                      try {
                        await _s.db.rpc('stop_medicine', params: {'p_auth': m['id']});
                        _snack('Stopped — staff will not give more doses');
                      } catch (e) {
                        _snack(Kids.errorText(e));
                      }
                      _load();
                    },
                    child: const Text('Stop'))
                : null,
          ),
        const Divider(),
        ListTile(title: Text('Incident reports', style: Theme.of(context).textTheme.titleMedium)),
        if (_incidents.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('None.')),
        for (final i in _incidents)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: i['guardian_ack_at'] == null ? cs.tertiaryContainer : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${Kids.incidentKinds[i['kind']] ?? i['kind']} · ${Kids.day.format(DateTime.parse(i['occurred_at'] as String).toLocal())} ${Kids.fmtTime(i['occurred_at'])}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('${i['description']}'),
                if (i['first_aid'] != null) Text('First aid: ${i['first_aid']}'),
                if (i['action_taken'] != null) Text('Action: ${i['action_taken']}'),
                if (i['location'] != null) Text('Where: ${i['location']}'),
                const SizedBox(height: 6),
                if (i['guardian_ack_at'] != null)
                  Text('✔ You acknowledged this ${Kids.day.format(DateTime.parse(i['guardian_ack_at'] as String).toLocal())}', style: TextStyle(color: cs.outline))
                else
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () async {
                        final note = TextEditingController();
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('Acknowledge report'),
                            content: TextField(controller: note, decoration: const InputDecoration(labelText: 'Comment (optional)')),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('I have read this')),
                            ],
                          ),
                        );
                        if (ok == true) await _rpc('ack_incident', {'p_incident': i['id'], 'p_note': note.text.trim().isEmpty ? null : note.text.trim()}, 'Thank you');
                      },
                      child: const Text('Acknowledge'),
                    ),
                  ),
              ]),
            ),
          ),
        const Divider(),
        SwitchListTile(
          title: const Text('Photos of my child in daily updates'),
          subtitle: const Text('Photos are private: only you, other guardians and the centre staff can see them.'),
          value: _consent,
          onChanged: (v) async {
            try {
              await _s.db.rpc('set_photo_consent', params: {'p_child': _id, 'p_consent': v});
              setState(() => _consent = v);
            } catch (e) {
              _snack(Kids.errorText(e));
            }
          },
        ),
      ]),
    );
  }

  Future<void> _authorise() async {
    final med = TextEditingController();
    final dose = TextEditingController();
    final times = TextEditingController();
    final reason = TextEditingController();
    final hours = TextEditingController(text: '4');
    final maxN = TextEditingController(text: '3');
    DateTime from = DateTime.now(), to = DateTime.now();
    bool agree = false;
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => StatefulBuilder(
        builder: (context, set) => Scaffold(
          appBar: AppBar(title: const Text('Authorise medicine')),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            TextField(controller: med, decoration: const InputDecoration(labelText: 'Medicine name and strength (e.g. Paracetamol 120 mg/5 ml)')),
            TextField(controller: dose, decoration: const InputDecoration(labelText: 'Dose (e.g. 5 ml)')),
            TextField(controller: times, decoration: const InputDecoration(labelText: 'When (e.g. 12:00 after lunch, or if temp ≥ 38°C)')),
            TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason')),
            Row(children: [
              Expanded(child: TextField(controller: hours, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Min. hours between doses'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: maxN, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Max doses a day'))),
            ]),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${Kids.day.format(from)} → ${Kids.day.format(to)}'),
              trailing: const Icon(Icons.date_range),
              onTap: () async {
                final r = await showDateRangePicker(
                    context: context, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 90)), initialDateRange: DateTimeRange(start: from, end: to));
                if (r != null) set(() {
                    from = r.start;
                    to = r.end;
                  });
              },
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: agree,
              onChanged: (v) => set(() => agree = v ?? false),
              title: const Text('I am the child\'s parent/guardian and I authorise the centre to give this medicine as described.'),
            ),
            FilledButton(onPressed: agree ? () => Navigator.pop(context, true) : null, child: const Text('Authorise')),
          ]),
        ),
      ),
    ));
    if (ok != true) return;
    await _rpc('authorise_medicine', {
      'p_child': _id,
      'p_medicine': med.text,
      'p_dose': dose.text,
      'p_times': times.text,
      'p_reason': reason.text.trim().isEmpty ? null : reason.text.trim(),
      'p_start': Kids.isoDate(from),
      'p_end': Kids.isoDate(to),
      'p_min_hours': double.tryParse(hours.text) ?? 4,
      'p_max_per_day': int.tryParse(maxN.text) ?? 3,
    }, 'Authorised — the centre can see it now');
  }

  Widget _pickup() {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        ListTile(title: Text('Who can collect $_name', style: Theme.of(context).textTheme.titleMedium)),
        for (final f in _family)
          ListTile(
            dense: true,
            leading: Icon(f['can_pickup'] == true ? Icons.check_circle_outline : Icons.block),
            title: Text('${f['guardians']['full_name']} (${f['relation']})'),
            subtitle: Text(f['can_pickup'] == true ? 'Allowed' : 'Not allowed — ask the centre to change this'),
          ),
        for (final p in _pickups)
          ListTile(
            dense: true,
            leading: const Icon(Icons.person_add_alt),
            title: Text('${p['full_name']}${p['relation'] != null ? ' (${p['relation']})' : ''}'),
            subtitle: Text('${p['valid_from']} → ${p['valid_to']} · ID ends ${p['id_last4']}'),
            trailing: IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await _s.db.from('pickup_persons').delete().eq('id', p['id']);
                _load();
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(onPressed: _addPickup, icon: const Icon(Icons.person_add_alt), label: const Text('Someone else is collecting')),
            OutlinedButton.icon(onPressed: _setPin, icon: const Icon(Icons.pin_outlined), label: const Text('Set my pick-up PIN')),
            OutlinedButton.icon(onPressed: _absence, icon: const Icon(Icons.event_busy_outlined), label: const Text('Report absence')),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('The centre will only release your child to the people listed. Someone else must show their IC — '
              'staff check the last 4 characters you enter here.', style: TextStyle(fontSize: 12)),
        ),
      ]),
    );
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
          title: const Text('Someone else is collecting'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name (as on IC)')),
              TextField(controller: rel, decoration: const InputDecoration(labelText: 'Relation (grandmother, driver…)')),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
              TextField(controller: id4, maxLength: 4, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Last 4 of their IC/passport')),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(Kids.isoDate(from) == Kids.isoDate(to) ? Kids.day.format(from) : '${Kids.day.format(from)} → ${Kids.day.format(to)}'),
                trailing: const Icon(Icons.date_range),
                onTap: () async {
                  final r = await showDateRangePicker(
                      context: context, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 30)), initialDateRange: DateTimeRange(start: from, end: to));
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
    await _rpc('parent_add_pickup', {
      'p_child': _id,
      'p_name': name.text,
      'p_phone': phone.text,
      'p_id_last4': id4.text.trim(),
      'p_relation': rel.text.trim().isEmpty ? null : rel.text.trim(),
      'p_from': Kids.isoDate(from),
      'p_to': Kids.isoDate(to),
    }, 'Added — the centre will check their IC');
  }

  Future<void> _setPin() async {
    final a = TextEditingController();
    final b = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Pick-up PIN'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Give this 6-digit PIN at the counter when you collect. Never share it with anyone.', style: TextStyle(fontSize: 13)),
          TextField(controller: a, obscureText: true, maxLength: 6, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'New PIN')),
          TextField(controller: b, obscureText: true, maxLength: 6, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Repeat PIN')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    if (a.text != b.text) return _snack('The PINs don\'t match');
    await _rpc('set_pickup_pin', {'p_tenant': widget.child['tenant_id'], 'p_pin': a.text}, 'PIN saved');
  }

  Future<void> _absence() async {
    String reason = 'sick';
    final note = TextEditingController();
    DateTime from = DateTime.now(), to = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text('$_name won\'t be in'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'sick', label: Text('Sick')),
                ButtonSegment(value: 'holiday', label: Text('Holiday')),
                ButtonSegment(value: 'family', label: Text('Family')),
                ButtonSegment(value: 'other', label: Text('Other')),
              ],
              selected: {reason},
              onSelectionChanged: (v) => set(() => reason = v.first),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(Kids.isoDate(from) == Kids.isoDate(to) ? Kids.day.format(from) : '${Kids.day.format(from)} → ${Kids.day.format(to)}'),
              trailing: const Icon(Icons.date_range),
              onTap: () async {
                final r = await showDateRangePicker(
                    context: context, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 60)), initialDateRange: DateTimeRange(start: from, end: to));
                if (r != null) set(() {
                    from = r.start;
                    to = r.end;
                  });
              },
            ),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (e.g. fever, doctor\'s visit)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Send')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _rpc('report_absence', {
      'p_child': _id,
      'p_from': Kids.isoDate(from),
      'p_to': Kids.isoDate(to),
      'p_reason': reason,
      'p_note': note.text.trim().isEmpty ? null : note.text.trim(),
    }, 'The centre has been told');
  }

  Widget _fees() {
    final nf = NumberFormat('#,##0.00');
    final owed = _invoices.where((i) => i['status'] == 'issued' || i['status'] == 'partial').fold<double>(
        0, (a, i) => a + (i['total'] as num).toDouble() - (i['amount_paid'] as num).toDouble());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Card(
          margin: const EdgeInsets.all(12),
          child: ListTile(
            title: const Text('Balance due'),
            trailing: Text('${_s.currency} ${nf.format(owed)}', style: Theme.of(context).textTheme.titleLarge),
          ),
        ),
        if (_invoices.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No invoices yet.')),
        for (final i in _invoices)
          ExpansionTile(
            title: Text('${i['number']} · ${i['notes'] ?? ''}'),
            subtitle: Text('${_s.currency} ${nf.format(i['total'])} · ${i['status'] == 'paid' ? 'paid' : 'due ${i['due_date'] ?? ''}'}'
                '${i['status'] == 'partial' ? ' · ${nf.format(i['amount_paid'])} paid' : ''}'),
            children: [
              FutureBuilder(
                future: _s.db.from('invoice_lines').select('description, qty, unit_price, discount, line_total').eq('invoice_id', i['id']).order('sort_order'),
                builder: (_, snap) => Column(children: [
                  for (final l in (snap.data ?? const []))
                    ListTile(
                      dense: true,
                      title: Text('${l['description']}'),
                      trailing: Text(nf.format(l['line_total'])),
                    ),
                ]),
              ),
            ],
          ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Pay the centre as usual (bank transfer / DuitNow) and quote the invoice number.', style: TextStyle(fontSize: 12)),
        ),
      ]),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
