import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';
import 'employee_screen.dart';
import 'my_work_screen.dart' show claimCategories;
import 'payroll_screen.dart';

/// HR for managers: people, today's attendance, approvals, payroll.
class TeamScreen extends StatelessWidget {
  const TeamScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSession.instance;
    final tabs = <(String, Widget)>[
      ('People', const _PeopleTab()),
      ('Today', const _TodayTab()),
      if (s.can('hr.leave.approve') || s.can('hr.claim.approve')) ('Approvals', const _ApprovalsTab()),
      if (s.can('hr.payroll.run') || s.can('hr.payroll.view')) ('Payroll', const PayrollListTab()),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Column(children: [
        TabBar(isScrollable: tabs.length > 3, tabs: [for (final t in tabs) Tab(text: t.$1)]),
        Expanded(child: TabBarView(children: [for (final t in tabs) t.$2])),
      ]),
    );
  }
}

class _PeopleTab extends StatefulWidget {
  const _PeopleTab();
  @override
  State<_PeopleTab> createState() => _PeopleTabState();
}

class _PeopleTabState extends State<_PeopleTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _rows = [];
  bool _showLeft = false;
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
      var q = _s.db.from('employees').select().eq('tenant_id', _s.tenantId!);
      if (!_showLeft) q = q.eq('status', 'active');
      final t = _q.replaceAll(RegExp(r'[,()%]'), ' ').trim();
      if (t.isNotEmpty) q = q.or('full_name.ilike.%$t%,employee_no.ilike.%$t%,job_title.ilike.%$t%,department.ilike.%$t%');
      _rows = List<Map<String, dynamic>>.from(await q.order('full_name'));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load: $e')));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open([String? id]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EmployeeScreen(employeeId: id)));
    _load();
  }

  Future<void> _holidays() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HolidaysScreen()));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(hintText: 'Search name, number, role', prefixIcon: Icon(Icons.search), border: OutlineInputBorder(), isDense: true),
                onChanged: (v) {
                  _q = v;
                  _load();
                },
              ),
            ),
            IconButton(tooltip: 'Public holidays', onPressed: _holidays, icon: const Icon(Icons.event_outlined)),
          ]),
        ),
        SwitchListTile(
          dense: true,
          title: const Text('Include people who left'),
          value: _showLeft,
          onChanged: (v) {
            _showLeft = v;
            _load();
          },
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(children: [
                    if (_rows.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No employees yet'))),
                    for (final e in _rows)
                      ListTile(
                        leading: CircleAvatar(child: Text((e['full_name'] as String)[0].toUpperCase())),
                        title: Text(e['full_name'] as String),
                        subtitle: Text([e['employee_no'], e['job_title'], e['department'], if (e['status'] != 'active') e['status']].whereType<String>().join(' · ')),
                        trailing: e['user_id'] == null ? const Tooltip(message: 'No app login linked', child: Icon(Icons.link_off, size: 18)) : null,
                        onTap: () => _open(e['id'] as String),
                      ),
                    const SizedBox(height: 80),
                  ]),
                ),
        ),
      ]),
      floatingActionButton: _s.can('hr.employee.manage')
          ? FloatingActionButton.extended(heroTag: null, onPressed: () => _open(), icon: const Icon(Icons.person_add_alt), label: const Text('Employee'))
          : null,
    );
  }
}

class _TodayTab extends StatefulWidget {
  const _TodayTab();
  @override
  State<_TodayTab> createState() => _TodayTabState();
}

class _TodayTabState extends State<_TodayTab> with AutomaticKeepAliveClientMixin {
  DateTime _day = DateTime.now();
  List<Map<String, dynamic>> _staff = [];
  List<Map<String, dynamic>> _att = [];
  List<Map<String, dynamic>> _onLeave = [];
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
    final d = DateFormat('yyyy-MM-dd').format(_day);
    try {
      _staff = List<Map<String, dynamic>>.from(await _s.db.from('employees').select('id, full_name, work_days, shift_start').eq('tenant_id', _s.tenantId!).eq('status', 'active').order('full_name'));
      _att = List<Map<String, dynamic>>.from(await _s.db.from('attendance').select().eq('tenant_id', _s.tenantId!).eq('work_date', d).order('clock_in'));
      _onLeave = List<Map<String, dynamic>>.from(await _s.db
          .from('leave_requests')
          .select('employee_id, leave_types(name)')
          .eq('tenant_id', _s.tenantId!)
          .eq('status', 'approved')
          .lte('start_date', d)
          .gte('end_date', d));
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _approveOt(Map<String, dynamic> a) async {
    final c = TextEditingController(text: '${a['ot_minutes']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve overtime'),
        content: TextField(controller: c, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Minutes to pay (max ${a['ot_minutes']})')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Approve')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _s.db.from('attendance').update({'ot_approved_minutes': int.tryParse(c.text) ?? 0, 'edited_by': _s.db.auth.currentUser!.id}).eq('id', a['id']);
      _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final fmt = DateFormat('HH:mm');
    final err = Theme.of(context).colorScheme.error;
    final dow = _day.weekday;
    final scheduled = _staff.where((e) => (e['work_days'] as List).contains(dow)).toList();
    final inIds = _att.map((a) => a['employee_id']).toSet();
    final leaveIds = {for (final l in _onLeave) l['employee_id']: l['leave_types']['name']};
    final absent = scheduled.where((e) => !inIds.contains(e['id']) && !leaveIds.containsKey(e['id'])).toList();
    final names = {for (final e in _staff) e['id']: e['full_name']};
    return _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(12), children: [
              Row(children: [
                IconButton(onPressed: () { _day = _day.subtract(const Duration(days: 1)); _load(); }, icon: const Icon(Icons.chevron_left)),
                Expanded(child: Text(DateFormat('EEEE d MMM yyyy').format(_day), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium)),
                IconButton(onPressed: () { _day = _day.add(const Duration(days: 1)); _load(); }, icon: const Icon(Icons.chevron_right)),
              ]),
              Text('${inIds.length} in · ${leaveIds.length} on leave · ${absent.length} not clocked in', textAlign: TextAlign.center),
              const Divider(),
              for (final a in _att)
                ListTile(
                  dense: true,
                  title: Text(names[a['employee_id']] as String? ?? '?'),
                  subtitle: Text([
                    '${fmt.format(DateTime.parse(a['clock_in'] as String).toLocal())} – ${a['clock_out'] == null ? 'still in' : fmt.format(DateTime.parse(a['clock_out'] as String).toLocal())}',
                    if ((a['late_minutes'] as int) > 0) '${a['late_minutes']} min late',
                    if (a['day_type'] != 'normal') (a['day_type'] as String).replaceAll('_', ' '),
                  ].join(' · '), style: TextStyle(color: (a['late_minutes'] as int) > 15 ? err : null)),
                  trailing: (a['ot_minutes'] as int) > 0 && _s.can('hr.attendance.manage')
                      ? TextButton(onPressed: () => _approveOt(a), child: Text('OT ${a['ot_minutes']}m${(a['ot_approved_minutes'] as int) > 0 ? ' ✓' : ''}'))
                      : null,
                ),
              if (leaveIds.isNotEmpty) ...[
                const Divider(),
                for (final e in leaveIds.entries) ListTile(dense: true, leading: const Icon(Icons.beach_access_outlined), title: Text(names[e.key] as String? ?? '?'), subtitle: Text(e.value as String)),
              ],
              if (absent.isNotEmpty) ...[
                const Divider(),
                for (final e in absent)
                  ListTile(dense: true, leading: Icon(Icons.person_off_outlined, color: err), title: Text(e['full_name'] as String), subtitle: Text('Shift starts ${(e['shift_start'] as String).substring(0, 5)}')),
              ],
            ]),
          );
  }
}

class _ApprovalsTab extends StatefulWidget {
  const _ApprovalsTab();
  @override
  State<_ApprovalsTab> createState() => _ApprovalsTabState();
}

class _ApprovalsTabState extends State<_ApprovalsTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _leave = [];
  List<Map<String, dynamic>> _claims = [];
  bool _loading = true;
  AppSession get _s => AppSession.instance;
  NumberFormat get _money => NumberFormat.currency(symbol: '${_s.currency} ');

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (_s.can('hr.leave.approve')) {
        _leave = List<Map<String, dynamic>>.from(await _s.db
            .from('leave_requests')
            .select('*, employees(full_name), leave_types(name)')
            .eq('tenant_id', _s.tenantId!)
            .eq('status', 'pending')
            .order('start_date'));
      }
      if (_s.can('hr.claim.approve')) {
        _claims = List<Map<String, dynamic>>.from(await _s.db
            .from('claims')
            .select('*, employees(full_name)')
            .eq('tenant_id', _s.tenantId!)
            .eq('status', 'pending')
            .order('claim_date'));
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _decide(String fn, String idParam, String id, bool approve) async {
    String? note;
    if (!approve) {
      final c = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Reject'),
          content: TextField(controller: c, decoration: const InputDecoration(labelText: 'Reason')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Reject')),
          ],
        ),
      );
      if (ok != true) return;
      note = c.text.trim().isEmpty ? null : c.text.trim();
    }
    try {
      await _s.db.rpc(fn, params: {idParam: id, 'p_approve': approve, 'p_note': note});
      _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final d = DateFormat('EEE d MMM');
    Widget buttons(String fn, String p, String id) => Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: 'Reject', onPressed: () => _decide(fn, p, id, false), icon: const Icon(Icons.close)),
          IconButton.filledTonal(tooltip: 'Approve', onPressed: () => _decide(fn, p, id, true), icon: const Icon(Icons.check)),
        ]);
    return _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(12), children: [
              if (_leave.isEmpty && _claims.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Nothing waiting 🎉'))),
              if (_leave.isNotEmpty) Text('Leave', style: Theme.of(context).textTheme.titleMedium),
              for (final r in _leave)
                ListTile(
                  title: Text('${r['employees']['full_name']} · ${r['leave_types']['name']}'),
                  subtitle: Text('${d.format(DateTime.parse(r['start_date'] as String))} – ${d.format(DateTime.parse(r['end_date'] as String))} · ${r['days']} day(s)'
                      '${r['half_day'] != null ? ' (${r['half_day']})' : ''}${r['reason'] != null ? '\n${r['reason']}' : ''}'),
                  isThreeLine: r['reason'] != null,
                  trailing: buttons('decide_leave', 'p_request', r['id'] as String),
                ),
              if (_claims.isNotEmpty) Text('Claims', style: Theme.of(context).textTheme.titleMedium),
              for (final c in _claims)
                ListTile(
                  title: Text('${c['employees']['full_name']} · ${_money.format(c['amount'])}'),
                  subtitle: Text('${claimCategories[c['category']]} · ${c['description']} · ${c['claim_date']}'),
                  trailing: buttons('decide_claim', 'p_claim', c['id'] as String),
                ),
            ]),
          );
  }
}

class HolidaysScreen extends StatefulWidget {
  const HolidaysScreen({super.key});
  @override
  State<HolidaysScreen> createState() => _HolidaysScreenState();
}

class _HolidaysScreenState extends State<HolidaysScreen> {
  List<Map<String, dynamic>> _rows = [];
  int _year = DateTime.now().year;
  AppSession get _s => AppSession.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await _s.db
        .from('public_holidays')
        .select()
        .eq('tenant_id', _s.tenantId!)
        .gte('holiday_date', '$_year-01-01')
        .lte('holiday_date', '$_year-12-31')
        .order('holiday_date');
    if (mounted) setState(() => _rows = List<Map<String, dynamic>>.from(rows));
  }

  Future<void> _add() async {
    final name = TextEditingController();
    final d = await showDatePicker(context: context, initialDate: DateTime(_year, DateTime.now().month), firstDate: DateTime(_year - 1), lastDate: DateTime(_year + 1, 12, 31));
    if (d == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(DateFormat('EEE d MMM yyyy').format(d)),
        content: TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Holiday name')),
        actions: [FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add'))],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    try {
      await _s.db.from('public_holidays').insert({'tenant_id': _s.tenantId, 'holiday_date': DateFormat('yyyy-MM-dd').format(d), 'name': name.text.trim()});
      _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = _s.can('hr.employee.manage');
    return Scaffold(
      appBar: AppBar(title: Text('Public holidays $_year'), actions: [
        IconButton(onPressed: () { _year--; _load(); }, icon: const Icon(Icons.chevron_left)),
        IconButton(onPressed: () { _year++; _load(); }, icon: const Icon(Icons.chevron_right)),
      ]),
      body: ListView(children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Add the national and state holidays your business observes. They are skipped when counting leave '
              'and paid at the public-holiday rate when staff work.'),
        ),
        for (final h in _rows)
          ListTile(
            title: Text(h['name'] as String),
            subtitle: Text(DateFormat('EEEE d MMMM').format(DateTime.parse(h['holiday_date'] as String))),
            trailing: canEdit
                ? IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await _s.db.from('public_holidays').delete().eq('id', h['id']);
                      _load();
                    },
                  )
                : null,
          ),
      ]),
      floatingActionButton: canEdit ? FloatingActionButton(heroTag: null, onPressed: _add, child: const Icon(Icons.add)) : null,
    );
  }
}
