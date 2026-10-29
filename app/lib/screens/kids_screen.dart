import 'package:flutter/material.dart';

import '../services/kids.dart';
import '../services/printing_service.dart';
import '../services/session.dart';
import 'child_screen.dart';
import 'kids_setup_screen.dart';

/// Kids care for staff: today's room board, children, medicine & incidents, setup and billing.
class KidsScreen extends StatelessWidget {
  const KidsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSession.instance;
    final tabs = <(String, Widget)>[
      ('Today', const _TodayTab()),
      ('Children', const _ChildrenTab()),
      ('Records', const _RecordsTab()),
      if (s.can('kids.manage') || s.can('kids.billing')) ('Setup', const KidsSetupTab()),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Column(children: [
        TabBar(tabs: [for (final t in tabs) Tab(text: t.$1)]),
        Expanded(child: TabBarView(children: [for (final t in tabs) t.$2])),
      ]),
    );
  }
}

// ───────────────────────── Today ─────────────────────────

class _TodayTab extends StatefulWidget {
  const _TodayTab();
  @override
  State<_TodayTab> createState() => _TodayTabState();
}

class _TodayTabState extends State<_TodayTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _kids = [];
  List<Map<String, dynamic>> _rooms = [];
  List<Map<String, dynamic>> _ratio = [];
  Map<String, Map<String, dynamic>> _att = {};
  Map<String, dynamic>? _myDuty;
  String? _room; // filter
  bool _loading = true;
  AppSession get _s => AppSession.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _today => Kids.isoDate(DateTime.now());

  Future<void> _load() async {
    try {
      final r = await Future.wait<dynamic>([
        _s.db
            .from('children')
            .select('id, full_name, preferred_name, dob, room_id, photo_path, allergies, medical_conditions, days')
            .eq('tenant_id', _s.tenantId!)
            .eq('status', 'enrolled')
            .order('full_name'),
        _s.db.from('kids_rooms').select().eq('tenant_id', _s.tenantId!).eq('active', true).order('min_age_months'),
        _s.db.from('kids_attendance').select().eq('tenant_id', _s.tenantId!).eq('day', _today),
        _s.db.rpc('kids_ratio', params: {'p_tenant': _s.tenantId}),
        _s.db
            .from('kids_staff_duty')
            .select('id, room_id, start_at')
            .eq('tenant_id', _s.tenantId!)
            .eq('user_id', _s.db.auth.currentUser!.id)
            .isFilter('end_at', null),
      ]);
      _kids = List<Map<String, dynamic>>.from(r[0] as List);
      _rooms = List<Map<String, dynamic>>.from(r[1] as List);
      _att = {for (final a in (r[2] as List)) (a as Map)['child_id'] as String: Map<String, dynamic>.from(a)};
      _ratio = List<Map<String, dynamic>>.from(r[3] as List);
      final duty = r[4] as List;
      _myDuty = duty.isEmpty ? null : Map<String, dynamic>.from(duty.first as Map);
    } catch (e) {
      _snack(Kids.errorText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  String _status(Map<String, dynamic> c) {
    final a = _att[c['id']];
    if (a == null) return 'not_in';
    if (a['check_out_at'] != null) return 'out';
    if (a['check_in_at'] != null) return 'in';
    return (a['status'] ?? 'absent') as String;
  }

  Future<void> _duty() async {
    if (_myDuty != null) {
      final end = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('End your duty?'),
          content: Text('You are counted in ${_roomName(_myDuty!['room_id'])} since ${Kids.fmtTime(_myDuty!['start_at'])}.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Move room')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('End duty')),
          ],
        ),
      );
      if (end == false) return;
      if (end == true) {
        try {
          await _s.db.rpc('kids_end_duty', params: {'p_tenant': _s.tenantId});
        } catch (e) {
          _snack(Kids.errorText(e));
        }
        return _load();
      }
    }
    if (!mounted) return;
    final room = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Which room are you looking after?')),
          for (final r in _rooms) ListTile(title: Text(r['name'] as String), onTap: () => Navigator.pop(context, r['id'] as String)),
        ]),
      ),
    );
    if (room == null) return;
    try {
      await _s.db.rpc('kids_start_duty', params: {'p_room': room});
    } catch (e) {
      _snack(Kids.errorText(e));
    }
    _load();
  }

  String _roomName(dynamic id) => (_rooms.where((r) => r['id'] == id).firstOrNull?['name'] ?? '—') as String;

  Future<void> _rollCall() async {
    final here = _kids.where((c) => _status(c) == 'in').toList();
    final checked = <String>{};
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StatefulBuilder(
        builder: (context, set) => Scaffold(
          appBar: AppBar(title: Text('Roll call — ${checked.length}/${here.length}'), actions: [
            IconButton(
              tooltip: 'Print register',
              icon: const Icon(Icons.print_outlined),
              onPressed: () => PrintingService.printKidsRegister(
                  day: DateTime.now(), children: _kids, attendance: _att, roomName: _roomName),
            ),
          ]),
          body: ListView(children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Tick each child as you count them at the assembly point. Children on this list are checked in right now.'),
            ),
            for (final c in here)
              CheckboxListTile(
                value: checked.contains(c['id']),
                onChanged: (v) => set(() => v == true ? checked.add(c['id'] as String) : checked.remove(c['id'])),
                secondary: KidsPhoto(path: c['photo_path'] as String?, size: 40),
                title: Text(c['full_name'] as String),
                subtitle: Text(_roomName(c['room_id'])),
              ),
          ]),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                checked.length == here.length ? '✔ Everyone accounted for' : '${here.length - checked.length} not yet counted',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: checked.length == here.length ? Colors.green.shade700 : Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    final cs = Theme.of(context).colorScheme;
    final list = _kids.where((c) => _room == null || c['room_id'] == _room).toList();
    final hereN = _kids.where((c) => _status(c) == 'in').length;
    final weekday = DateTime.now().weekday;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        // Ratio board
        if (_ratio.isNotEmpty)
          SizedBox(
            height: 92,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.all(8), children: [
              for (final r in _ratio)
                Card(
                  color: r['ok'] == true ? null : cs.errorContainer,
                  child: InkWell(
                    onTap: () => setState(() => _room = _room == r['room_id'] ? null : r['room_id'] as String),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Row(children: [
                          Text(r['room_name'] as String, style: const TextStyle(fontWeight: FontWeight.bold)),
                          if (_room == r['room_id']) const Icon(Icons.filter_alt, size: 16),
                        ]),
                        Text('${r['children_present']} children · ${r['carers_on_duty']} carer(s)'),
                        Text(
                          r['ok'] == true ? 'Ratio OK (1:${r['ratio_children']})' : 'Need ${r['carers_needed']} carer(s) — 1:${r['ratio_children']}',
                          style: TextStyle(fontSize: 12, color: r['ok'] == true ? Colors.green.shade700 : cs.error, fontWeight: FontWeight.w600),
                        ),
                      ]),
                    ),
                  ),
                ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _duty,
                icon: Icon(_myDuty == null ? Icons.play_arrow : Icons.badge_outlined),
                label: Text(_myDuty == null ? 'Start my duty' : 'On duty: ${_roomName(_myDuty!['room_id'])}', overflow: TextOverflow.ellipsis),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(onPressed: _rollCall, icon: const Icon(Icons.fact_check_outlined), label: Text('Here now: $hereN')),
          ]),
        ),
        const SizedBox(height: 4),
        if (_rooms.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Add your rooms and enrol children in the Setup and Children tabs to get started.', textAlign: TextAlign.center),
          ),
        for (final c in list)
          _childTile(c, cs, expectedToday: (c['days'] as List? ?? const []).contains(weekday)),
      ]),
    );
  }

  Widget _childTile(Map<String, dynamic> c, ColorScheme cs, {required bool expectedToday}) {
    final st = _status(c);
    final a = _att[c['id']];
    final (label, color) = switch (st) {
      'in' => ('In since ${Kids.fmtTime(a!['check_in_at'])}', Colors.green.shade700),
      'out' => ('Picked up ${Kids.fmtTime(a!['check_out_at'])} by ${a['picked_up_by']}', cs.outline),
      'sick' => ('Off sick', Colors.orange.shade800),
      'holiday' => ('On holiday', cs.outline),
      'absent' => ('Absent', Colors.orange.shade800),
      _ => (expectedToday ? 'Not in yet' : 'Not due today', cs.outline),
    };
    final allergy = (c['allergies'] ?? '').toString().trim();
    return ListTile(
      leading: KidsPhoto(path: c['photo_path'] as String?),
      title: Row(children: [
        Flexible(child: Text((c['preferred_name'] ?? c['full_name']) as String, overflow: TextOverflow.ellipsis)),
        if (allergy.isNotEmpty) ...[
          const SizedBox(width: 6),
          Tooltip(message: 'Allergy: $allergy', child: Icon(Icons.warning_amber_rounded, color: cs.error, size: 18)),
        ],
      ]),
      subtitle: Text('${_roomName(c['room_id'])} · $label', style: TextStyle(color: color)),
      trailing: _s.can('kids.checkin')
          ? (st == 'in'
              ? OutlinedButton(onPressed: () => _checkOut(c), child: const Text('Out'))
              : st == 'out'
                  ? null
                  : FilledButton(onPressed: () => _checkIn(c), child: const Text('In')))
          : null,
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChildScreen(childId: c['id'] as String)));
        _load();
      },
    );
  }

  Future<void> _checkIn(Map<String, dynamic> c) async {
    final ok = await checkInDialog(context, c);
    if (ok == true) _load();
  }

  Future<void> _checkOut(Map<String, dynamic> c) async {
    final ok = await checkOutDialog(context, c);
    if (ok == true) _load();
  }
}

/// Check-in: who dropped off, optional temperature and note.
Future<bool?> checkInDialog(BuildContext context, Map<String, dynamic> child) async {
  final s = AppSession.instance;
  final guardians = await s.db
      .from('child_guardians')
      .select('relation, guardians(full_name)')
      .eq('child_id', child['id']);
  if (!context.mounted) return null;
  final by = TextEditingController();
  final temp = TextEditingController();
  final note = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (context, set) => AlertDialog(
        title: Text('Check in ${child['preferred_name'] ?? child['full_name']}'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if ((child['allergies'] ?? '').toString().trim().isNotEmpty)
              Text('⚠ Allergy: ${child['allergies']}', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            Wrap(spacing: 6, children: [
              for (final g in guardians)
                ActionChip(
                  label: Text(((g['guardians'] as Map?)?['full_name'] ?? '') as String),
                  onPressed: () => set(() => by.text = ((g['guardians'] as Map?)?['full_name'] ?? '') as String),
                ),
            ]),
            TextField(controller: by, decoration: const InputDecoration(labelText: 'Dropped off by')),
            TextField(
              controller: temp,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Temperature °C (optional)'),
            ),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Note from parent (optional)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Check in')),
        ],
      ),
    ),
  );
  if (ok != true) return false;
  try {
    await s.db.rpc('kids_check_in', params: {
      'p_child': child['id'],
      'p_dropped_by': by.text.trim().isEmpty ? null : by.text.trim(),
      'p_temperature': double.tryParse(temp.text.replaceAll(',', '.')),
      'p_note': note.text.trim().isEmpty ? null : note.text.trim(),
    });
    final t = double.tryParse(temp.text.replaceAll(',', '.'));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t != null && t >= 37.5
              ? 'Checked in — temperature $t°C is raised. Follow your sickness policy.'
              : 'Checked in')));
    }
    return true;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Kids.errorText(e))));
    return false;
  }
}

/// Check-out: only to a guardian allowed to collect, a person authorised for today (ID check), a PIN, or a manager override.
Future<bool?> checkOutDialog(BuildContext context, Map<String, dynamic> child) async {
  final s = AppSession.instance;
  final today = Kids.isoDate(DateTime.now());
  final r = await Future.wait<dynamic>([
    s.db.from('child_guardians').select('relation, can_pickup, guardians(id, full_name, phone, id_last4)').eq('child_id', child['id']),
    s.db.from('pickup_persons').select().eq('child_id', child['id']).lte('valid_from', today).gte('valid_to', today),
  ]);
  if (!context.mounted) return null;
  final allowed = [for (final g in r[0] as List) if ((g as Map)['can_pickup'] == true) Map<String, dynamic>.from(g)];
  final notAllowed = [for (final g in r[0] as List) if ((g as Map)['can_pickup'] != true) Map<String, dynamic>.from(g)];
  final persons = List<Map<String, dynamic>>.from(r[1] as List);
  String? choice; // g:<id> / p:<id> / pin / override
  final idLast4 = TextEditingController();
  final pin = TextEditingController();
  final overrideName = TextEditingController();
  final overrideReason = TextEditingController();
  final name = (child['preferred_name'] ?? child['full_name']) as String;

  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (context, set) {
        final cs = Theme.of(context).colorScheme;
        final needsId = choice?.startsWith('p:') == true;
        return AlertDialog(
          title: Text('Who is collecting $name?'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final g in allowed)
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'g:${g['guardians']['id']}',
                  groupValue: choice,
                  onChanged: (v) => set(() => choice = v),
                  title: Text(g['guardians']['full_name'] as String),
                  subtitle: Text('${g['relation']}${g['guardians']['id_last4'] != null ? ' · ID ends ${g['guardians']['id_last4']}' : ''}'),
                ),
              for (final p in persons)
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'p:${p['id']}',
                  groupValue: choice,
                  onChanged: (v) => set(() => choice = v),
                  title: Text(p['full_name'] as String),
                  subtitle: Text('Authorised for today${p['relation'] != null ? ' · ${p['relation']}' : ''} — check IC/passport'),
                ),
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                value: 'pin',
                groupValue: choice,
                onChanged: (v) => set(() => choice = v),
                title: const Text('Parent gives their 6-digit PIN'),
              ),
              if (s.can('kids.manage'))
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'override',
                  groupValue: choice,
                  onChanged: (v) => set(() => choice = v),
                  title: Text('Someone else (manager override)', style: TextStyle(color: cs.error)),
                ),
              if (notAllowed.isNotEmpty)
                Text('Not allowed to collect: ${notAllowed.map((g) => g['guardians']['full_name']).join(', ')}',
                    style: TextStyle(fontSize: 12, color: cs.error)),
              if (choice?.startsWith('g:') == true || needsId)
                TextField(
                  controller: idLast4,
                  maxLength: 4,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                      labelText: needsId ? 'Last 4 of their IC/passport (required)' : 'Last 4 of IC (if you don\'t know them)'),
                ),
              if (choice == 'pin')
                TextField(
                  controller: pin,
                  maxLength: 6,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'PIN'),
                ),
              if (choice == 'override') ...[
                TextField(controller: overrideName, decoration: const InputDecoration(labelText: 'Full name and IC of the person')),
                TextField(controller: overrideReason, decoration: const InputDecoration(labelText: 'Why (e.g. mum phoned at 5.10pm)')),
                Text('All guardians will be alerted immediately.', style: TextStyle(fontSize: 12, color: cs.error)),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: choice == null ? null : () => Navigator.pop(context, true), child: const Text('Release child')),
          ],
        );
      },
    ),
  );
  if (ok != true || choice == null) return false;
  final c = choice!;
  try {
    final res = await s.db.rpc('kids_check_out', params: {
      'p_child': child['id'],
      if (c.startsWith('g:')) 'p_guardian': c.substring(2),
      if (c.startsWith('p:')) 'p_person': c.substring(2),
      if (c == 'pin') 'p_pin': pin.text.trim(),
      if (c == 'override') 'p_override_name': overrideName.text.trim(),
      if (c == 'override') 'p_override_reason': overrideReason.text.trim(),
      if (idLast4.text.trim().isNotEmpty) 'p_id_last4': idLast4.text.trim(),
    }) as Map;
    if (res['ok'] != true) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${res['error']}')));
      return false;
    }
    final a = res['attendance'] as Map;
    final late = (a['late_minutes'] ?? 0) as int;
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$name collected by ${a['picked_up_by']}${late > 0 ? ' — $late min late' : ''}')));
    }
    return true;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Kids.errorText(e))));
    return false;
  }
}

// ───────────────────────── Children ─────────────────────────

class _ChildrenTab extends StatefulWidget {
  const _ChildrenTab();
  @override
  State<_ChildrenTab> createState() => _ChildrenTabState();
}

class _ChildrenTabState extends State<_ChildrenTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _rows = [];
  String _status = 'enrolled';
  String _q = '';
  bool _loading = true;
  AppSession get _s => AppSession.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var q = _s.db
          .from('children')
          .select('id, child_no, full_name, preferred_name, dob, status, photo_path, allergies, kids_rooms(name)')
          .eq('tenant_id', _s.tenantId!)
          .eq('status', _status);
      final t = _q.replaceAll(RegExp(r'[,()%]'), ' ').trim();
      if (t.isNotEmpty) q = q.or('full_name.ilike.%$t%,preferred_name.ilike.%$t%,child_no.ilike.%$t%');
      _rows = List<Map<String, dynamic>>.from(await q.order('full_name'));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Kids.errorText(e))));
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      floatingActionButton: _s.can('kids.manage')
          ? FloatingActionButton.extended(
              heroTag: null,
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Enrol'),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChildEditScreen()));
                _load();
              },
            )
          : null,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name or number', isDense: true),
            onChanged: (v) {
              _q = v;
              _load();
            },
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            for (final f in const [('enrolled', 'Enrolled'), ('waitlist', 'Waitlist'), ('enquiry', 'Enquiries'), ('withdrawn', 'Left')])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(f.$2),
                  selected: _status == f.$1,
                  onSelected: (_) {
                    setState(() => _status = f.$1);
                    _load();
                  },
                ),
              ),
          ]),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: _rows.length,
                    itemBuilder: (_, i) {
                      final c = _rows[i];
                      return ListTile(
                        leading: KidsPhoto(path: c['photo_path'] as String?),
                        title: Text(c['full_name'] as String),
                        subtitle: Text([
                          c['child_no'] ?? '',
                          Kids.age(c['dob']),
                          (c['kids_rooms'] as Map?)?['name'] ?? 'no room',
                          if ((c['allergies'] ?? '').toString().trim().isNotEmpty) '⚠ ${c['allergies']}',
                        ].join(' · ')),
                        onTap: () async {
                          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChildScreen(childId: c['id'] as String)));
                          _load();
                        },
                      );
                    },
                  ),
                ),
        ),
      ]),
    );
  }
}

// ───────────────────────── Records ─────────────────────────

/// Medicine due today and recent incidents across the centre.
class _RecordsTab extends StatefulWidget {
  const _RecordsTab();
  @override
  State<_RecordsTab> createState() => _RecordsTabState();
}

class _RecordsTabState extends State<_RecordsTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _meds = [];
  List<Map<String, dynamic>> _given = [];
  List<Map<String, dynamic>> _incidents = [];
  bool _loading = true;
  AppSession get _s => AppSession.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final today = Kids.isoDate(DateTime.now());
    try {
      final r = await Future.wait<dynamic>([
        _s.db
            .from('kids_med_authorisations')
            .select('*, children(full_name, preferred_name)')
            .eq('tenant_id', _s.tenantId!)
            .eq('status', 'active')
            .lte('start_date', today)
            .gte('end_date', today),
        _s.db
            .from('kids_med_given')
            .select('authorisation_id, given_at')
            .eq('tenant_id', _s.tenantId!)
            .gte('given_at', DateTime.now().subtract(const Duration(hours: 24)).toUtc().toIso8601String()),
        _s.db
            .from('kids_incidents')
            .select('*, children(full_name)')
            .eq('tenant_id', _s.tenantId!)
            .order('occurred_at', ascending: false)
            .limit(50),
      ]);
      _meds = List<Map<String, dynamic>>.from(r[0] as List);
      _given = List<Map<String, dynamic>>.from(r[1] as List);
      _incidents = List<Map<String, dynamic>>.from(r[2] as List);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Kids.errorText(e))));
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    final cs = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Medicine authorised for today (${_meds.length})', style: Theme.of(context).textTheme.titleMedium),
        ),
        if (_meds.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('None.')),
        for (final m in _meds)
          ListTile(
            leading: const Icon(Icons.medication_outlined),
            title: Text('${(m['children'] as Map?)?['preferred_name'] ?? (m['children'] as Map?)?['full_name']} — ${m['medicine']}'),
            subtitle: Text('${m['dose']} · ${m['times']}'
                '${_lastGiven(m['id']) != null ? '\nLast given ${Kids.fmtTime(_lastGiven(m['id']))}' : '\nNot given in the last 24 h'}'),
            isThreeLine: true,
            trailing: _s.can('kids.log')
                ? FilledButton.tonal(
                    onPressed: () async {
                      if (await giveMedicineDialog(context, m) == true) _load();
                    },
                    child: const Text('Give'))
                : null,
          ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('Incidents', style: Theme.of(context).textTheme.titleMedium),
        ),
        if (_incidents.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('None reported.')),
        for (final i in _incidents)
          ListTile(
            leading: Icon(Icons.report_outlined,
                color: i['severity'] == 'high' ? cs.error : i['severity'] == 'medium' ? Colors.orange.shade800 : null),
            title: Text('${(i['children'] as Map?)?['full_name']} — ${Kids.incidentKinds[i['kind']] ?? i['kind']}'),
            subtitle: Text('${Kids.day.format(DateTime.parse(i['occurred_at'] as String).toLocal())} ${Kids.fmtTime(i['occurred_at'])} · '
                '${i['kind'] == 'safeguarding' ? 'private' : i['guardian_ack_at'] != null ? 'parent acknowledged' : i['parent_notified_at'] != null ? 'parent notified, not yet acknowledged' : 'parent not notified'}'
                '${i['status'] == 'closed' ? ' · closed' : ''}'),
            onTap: () => showIncident(context, i, onChanged: _load),
          ),
      ]),
    );
  }

  String? _lastGiven(dynamic authId) {
    final g = _given.where((x) => x['authorisation_id'] == authId).map((x) => x['given_at'] as String).toList()..sort();
    return g.isEmpty ? null : g.last;
  }
}

Future<bool?> giveMedicineDialog(BuildContext context, Map<String, dynamic> m) async {
  final s = AppSession.instance;
  final dose = TextEditingController(text: m['dose'] as String);
  final witness = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text('Give ${m['medicine']}'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Authorised: ${m['dose']} — ${m['times']}'),
        if (m['reason'] != null) Text('For: ${m['reason']}'),
        Text('At least ${m['min_hours_between']} h apart, max ${m['max_doses_per_day']} a day', style: const TextStyle(fontSize: 12)),
        TextField(controller: dose, decoration: const InputDecoration(labelText: 'Dose given')),
        TextField(controller: witness, decoration: const InputDecoration(labelText: 'Witness (second staff member)')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Record dose')),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    await s.db.rpc('give_medicine', params: {
      'p_auth': m['id'],
      'p_dose': dose.text.trim(),
      'p_witness': witness.text.trim().isEmpty ? null : witness.text.trim(),
    });
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Dose recorded — parents can see it')));
    return true;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Kids.errorText(e))));
    return false;
  }
}

/// Incident detail for staff (with PDF and close) — parents use their own view.
Future<void> showIncident(BuildContext context, Map<String, dynamic> i, {VoidCallback? onChanged}) async {
  final s = AppSession.instance;
  final childName = (i['children'] as Map?)?['full_name'] ?? '';
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (ctx) => Scaffold(
      appBar: AppBar(title: Text(Kids.incidentKinds[i['kind']] ?? 'Incident'), actions: [
        IconButton(
          tooltip: 'PDF',
          icon: const Icon(Icons.picture_as_pdf_outlined),
          onPressed: () => PrintingService.printIncident(incident: i, childName: childName as String),
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(childName as String, style: Theme.of(ctx).textTheme.titleLarge),
        Text('${Kids.day.format(DateTime.parse(i['occurred_at'] as String).toLocal())} ${Kids.fmtTime(i['occurred_at'])}'
            '${i['location'] != null ? ' · ${i['location']}' : ''} · severity ${i['severity']}'),
        if (i['kind'] == 'safeguarding')
          Card(
            color: Theme.of(ctx).colorScheme.errorContainer,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Private: not shown to parents. Under the Child Act 2001 (s.29), child care providers who believe a child has been '
                  'harmed must report it to the Social Welfare Department (JKM) without delay. Talian Kasih: 15999.'),
            ),
          ),
        const SizedBox(height: 12),
        for (final f in const [
          ('description', 'What happened'),
          ('first_aid', 'First aid'),
          ('action_taken', 'Action taken'),
          ('witnesses', 'Witnesses'),
          ('reported_by_name', 'Reported by'),
          ('guardian_ack_note', 'Parent\'s note'),
          ('closed_note', 'Closing note'),
        ])
          if (i[f.$1] != null) ...[
            Text(f.$2, style: Theme.of(ctx).textTheme.titleSmall),
            Padding(padding: const EdgeInsets.only(bottom: 10), child: Text('${i[f.$1]}')),
          ],
        if (i['kind'] != 'safeguarding')
          Text(i['guardian_ack_at'] != null
              ? '✔ Parent acknowledged ${Kids.day.format(DateTime.parse(i['guardian_ack_at'] as String).toLocal())}'
              : i['parent_notified_at'] != null
                  ? 'Parent notified ${Kids.fmtTime(i['parent_notified_at'])}, waiting for acknowledgement'
                  : 'Parent not notified yet'),
        const SizedBox(height: 16),
        if (s.can('kids.manage') && i['status'] == 'open')
          FilledButton.tonal(
            onPressed: () async {
              final note = TextEditingController();
              final ok = await showDialog<bool>(
                context: ctx,
                builder: (_) => AlertDialog(
                  title: const Text('Close incident'),
                  content: TextField(controller: note, decoration: const InputDecoration(labelText: 'Follow-up / outcome')),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Close')),
                  ],
                ),
              );
              if (ok != true) return;
              try {
                await s.db.from('kids_incidents').update({'status': 'closed', 'closed_note': note.text.trim()}).eq('id', i['id']);
                onChanged?.call();
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (e) {
                if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(Kids.errorText(e))));
              }
            },
            child: const Text('Close incident'),
          ),
      ]),
    ),
  ));
}
