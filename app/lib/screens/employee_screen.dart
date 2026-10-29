import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

/// Add or edit an employee: work details, private details, pay & statutory set-up.
class EmployeeScreen extends StatefulWidget {
  final String? employeeId;
  const EmployeeScreen({super.key, this.employeeId});
  @override
  State<EmployeeScreen> createState() => _EmployeeScreenState();
}

class _EmployeeScreenState extends State<EmployeeScreen> {
  String? _id;
  Map<String, dynamic> _e = {};
  Map<String, dynamic> _priv = {};
  Map<String, dynamic> _pay = {};
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _balances = [];
  bool _loading = true;
  bool _busy = false;
  final Map<String, TextEditingController> _c = {};

  AppSession get _s => AppSession.instance;
  bool get _canManage => _s.can('hr.employee.manage');
  bool get _canPay => _s.can('hr.payroll.run') || _s.can('hr.employee.manage');

  TextEditingController _t(String key, dynamic v) => _c.putIfAbsent(key, () => TextEditingController(text: v?.toString() ?? ''));

  @override
  void initState() {
    super.initState();
    _id = widget.employeeId;
    _load();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _load() async {
    try {
      if (_id != null) {
        _e = await _s.db.from('employees').select().eq('id', _id!).single();
        if (_canManage) _priv = await _s.db.from('employee_private').select().eq('employee_id', _id!).maybeSingle() ?? {};
        if (_canPay) {
          _pay = await _s.db.from('employee_pay').select().eq('employee_id', _id!).maybeSingle() ?? {};
          _items = List<Map<String, dynamic>>.from(await _s.db.from('employee_pay_items').select().eq('employee_id', _id!).order('kind'));
        }
        _balances = List<Map<String, dynamic>>.from(await _s.db.rpc('leave_balances', params: {'p_employee': _id}) as List);
      } else {
        _e = {'employment_type': 'full_time', 'start_date': DateFormat('yyyy-MM-dd').format(DateTime.now()), 'work_days': [1, 2, 3, 4, 5], 'rest_day': 7,
              'shift_start': '09:00:00', 'shift_end': '18:00:00', 'break_minutes': 60, 'status': 'active'};
        _priv = {'citizenship': 'citizen', 'nationality': 'MY', 'marital_status': 'single', 'id_type': 'mykad'};
        _pay = {'pay_basis': 'monthly', 'tax_category': 1, 'qualifying_children': 0, 'socso_enabled': true, 'eis_enabled': true, 'pcb_enabled': true, 'ot_eligible': true};
      }
      _c.clear();
    } catch (e) {
      _snack('Could not load: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  String? _v(String k) => _c[k] == null || _c[k]!.text.trim().isEmpty ? null : _c[k]!.text.trim();
  double? _n(String k) => _v(k) == null ? null : double.tryParse(_v(k)!);

  Future<void> _save() async {
    if (_v('full_name') == null) {
      _snack('Name is required');
      return;
    }
    setState(() => _busy = true);
    try {
      final emp = {
        'tenant_id': _s.tenantId,
        'full_name': _v('full_name'),
        'preferred_name': _v('preferred_name'),
        'email': _v('email'),
        'phone': _v('phone'),
        'job_title': _v('job_title'),
        'department': _v('department'),
        'employment_type': _e['employment_type'],
        'start_date': _e['start_date'],
        'end_date': _e['end_date'],
        'status': _e['status'],
        'work_days': _e['work_days'],
        'rest_day': _e['rest_day'],
        'shift_start': _e['shift_start'],
        'shift_end': _e['shift_end'],
        'break_minutes': int.tryParse(_v('break_minutes') ?? '') ?? _e['break_minutes'],
        'outlet_id': _e['outlet_id'] ?? _s.outlet?.id,
      };
      if (_id == null) {
        final r = await _s.db.from('employees').insert(emp).select('id').single();
        _id = r['id'] as String;
      } else {
        await _s.db.from('employees').update(emp).eq('id', _id!);
      }
      if (_canManage) {
        await _s.db.from('employee_private').update({
          'id_type': _priv['id_type'],
          'id_no': _v('id_no'),
          'date_of_birth': _priv['date_of_birth'],
          'gender': _priv['gender'],
          'citizenship': _priv['citizenship'],
          'nationality': (_v('nationality') ?? 'MY').toUpperCase(),
          'marital_status': _priv['marital_status'],
          'address': _v('address'),
          'emergency_contact': _v('emergency_contact'),
          'bank_name': _v('bank_name'),
          'bank_account': _v('bank_account'),
        }).eq('employee_id', _id!);
      }
      if (_canPay) {
        await _s.db.from('employee_pay').update({
          'pay_basis': _pay['pay_basis'],
          'basic_salary': _n('basic_salary') ?? 0,
          'daily_rate': _n('daily_rate'),
          'hourly_rate': _n('hourly_rate'),
          'ot_eligible': _pay['ot_eligible'],
          'epf_no': _v('epf_no'),
          'socso_no': _v('socso_no'),
          'tax_no': _v('tax_no'),
          'tax_category': _pay['tax_category'],
          'qualifying_children': _n('qualifying_children') ?? 0,
          'disabled': _pay['disabled'] ?? false,
          'spouse_disabled': _pay['spouse_disabled'] ?? false,
          'zakat_monthly': _n('zakat_monthly') ?? 0,
          'other_reliefs_monthly': _n('other_reliefs_monthly') ?? 0,
          'socso_enabled': _pay['socso_enabled'],
          'eis_enabled': _pay['eis_enabled'],
          'pcb_enabled': _pay['pcb_enabled'],
          'prev_year': _n('prev_gross') == null ? null : DateTime.now().year,
          'prev_gross': _n('prev_gross') ?? 0,
          'prev_epf': _n('prev_epf') ?? 0,
          'prev_pcb': _n('prev_pcb') ?? 0,
        }).eq('employee_id', _id!);
      }
      _snack('Saved');
      setState(() => _loading = true);
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addItem() async {
    var kind = 'earning';
    final name = TextEditingController(), amt = TextEditingController();
    var taxable = true, epf = true, socso = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Monthly allowance / deduction'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'earning', label: Text('Allowance')), ButtonSegment(value: 'deduction', label: Text('Deduction'))],
                selected: {kind},
                onSelectionChanged: (v) => set(() => kind = v.first),
              ),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (e.g. Transport allowance)')),
              TextField(controller: amt, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount per month')),
              if (kind == 'earning') ...[
                CheckboxListTile(contentPadding: EdgeInsets.zero, value: taxable, onChanged: (v) => set(() => taxable = v!), title: const Text('Taxable (PCB)')),
                CheckboxListTile(contentPadding: EdgeInsets.zero, value: epf, onChanged: (v) => set(() => epf = v!), title: const Text('Counts for EPF')),
                CheckboxListTile(contentPadding: EdgeInsets.zero, value: socso, onChanged: (v) => set(() => socso = v!), title: const Text('Counts for SOCSO / EIS')),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    final a = double.tryParse(amt.text);
    if (ok != true || a == null || name.text.trim().isEmpty) return;
    await _s.db.from('employee_pay_items').insert({
      'tenant_id': _s.tenantId,
      'employee_id': _id,
      'kind': kind,
      'name': name.text.trim(),
      'amount': a,
      'taxable': kind == 'earning' && taxable,
      'epf': kind == 'earning' && epf,
      'socso': kind == 'earning' && socso,
    });
    _load();
  }

  Future<void> _adjustLeave(Map<String, dynamic> b) async {
    final days = TextEditingController(), reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Adjust ${b['name']}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: days, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Days (+ carry forward / grant, − forfeit)')),
          TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason *')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    final d = double.tryParse(days.text);
    if (ok != true || d == null || reason.text.trim().isEmpty) return;
    await _s.db.from('leave_adjustments').insert({
      'tenant_id': _s.tenantId,
      'employee_id': _id,
      'leave_type_id': b['leave_type_id'],
      'year': DateTime.now().year,
      'days': d,
      'reason': reason.text.trim(),
    });
    _load();
  }

  Widget _tf(String key, String label, dynamic value, {TextInputType? type, bool enabled = true, String? helper}) => TextField(
        controller: _t(key, value),
        enabled: enabled,
        keyboardType: type,
        decoration: InputDecoration(labelText: label, helperText: helper),
      );

  Widget _date(String label, String? value, void Function(String?) set, {bool clearable = false}) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: Text(value == null ? '—' : DateFormat('d MMM yyyy').format(DateTime.parse(value))),
        trailing: clearable && value != null ? IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => set(null))) : null,
        onTap: !_canManage
            ? null
            : () async {
                final d = await showDatePicker(
                    context: context, initialDate: value == null ? DateTime.now() : DateTime.parse(value), firstDate: DateTime(1940), lastDate: DateTime.now().add(const Duration(days: 365)));
                if (d != null) setState(() => set(DateFormat('yyyy-MM-dd').format(d)));
              },
      );

  Widget _section(String t) => Padding(padding: const EdgeInsets.only(top: 20, bottom: 4), child: Text(t, style: Theme.of(context).textTheme.titleMedium));

  @override
  Widget build(BuildContext context) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Scaffold(
      appBar: AppBar(
        title: Text(_id == null ? 'New employee' : (_e['full_name'] as String? ?? '')),
        actions: [if (_canManage || _canPay) TextButton(onPressed: _busy || _loading ? null : _save, child: const Text('Save'))],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (_e['employee_no'] != null) Text('${_e['employee_no']}${_e['user_id'] != null ? ' · app login linked' : ' · no app login yet'}'),
              _section('Work'),
              _tf('full_name', 'Full name (as in IC/passport) *', _e['full_name'], enabled: _canManage),
              _tf('preferred_name', 'Preferred name', _e['preferred_name'], enabled: _canManage),
              _tf('email', 'Email (used to link their app login)', _e['email'], type: TextInputType.emailAddress, enabled: _canManage),
              _tf('phone', 'Phone', _e['phone'], type: TextInputType.phone, enabled: _canManage),
              Row(children: [
                Expanded(child: _tf('job_title', 'Job title', _e['job_title'], enabled: _canManage)),
                const SizedBox(width: 12),
                Expanded(child: _tf('department', 'Department', _e['department'], enabled: _canManage)),
              ]),
              DropdownButtonFormField<String>(
                value: _e['employment_type'] as String,
                decoration: const InputDecoration(labelText: 'Employment type'),
                items: [for (final t in const ['full_time', 'part_time', 'contract', 'intern', 'daily', 'hourly']) DropdownMenuItem(value: t, child: Text(t.replaceAll('_', ' ')))],
                onChanged: !_canManage ? null : (v) => setState(() => _e['employment_type'] = v),
              ),
              _date('Start date', _e['start_date'] as String?, (v) => _e['start_date'] = v),
              _date('Last day (if leaving)', _e['end_date'] as String?, (v) => _e['end_date'] = v, clearable: true),
              if (_e['end_date'] != null)
                DropdownButtonFormField<String>(
                  value: _e['status'] as String,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: [for (final t in const ['active', 'resigned', 'terminated', 'retired']) DropdownMenuItem(value: t, child: Text(t))],
                  onChanged: !_canManage ? null : (v) => setState(() => _e['status'] = v),
                ),
              const SizedBox(height: 8),
              const Text('Working days'),
              Wrap(spacing: 4, children: [
                for (var i = 1; i <= 7; i++)
                  FilterChip(
                    label: Text(days[i - 1]),
                    selected: (_e['work_days'] as List).contains(i),
                    onSelected: !_canManage
                        ? null
                        : (v) => setState(() {
                              final l = List<int>.from(_e['work_days'] as List);
                              v ? l.add(i) : l.remove(i);
                              l.sort();
                              _e['work_days'] = l;
                            }),
                  ),
              ]),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: _e['rest_day'] as int,
                    decoration: const InputDecoration(labelText: 'Rest day'),
                    items: [for (var i = 1; i <= 7; i++) DropdownMenuItem(value: i, child: Text(days[i - 1]))],
                    onChanged: !_canManage ? null : (v) => setState(() => _e['rest_day'] = v),
                  ),
                ),
                const SizedBox(width: 12),
                for (final k in const ['shift_start', 'shift_end'])
                  Expanded(
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(k == 'shift_start' ? 'Starts' : 'Ends'),
                      subtitle: Text((_e[k] as String).substring(0, 5)),
                      onTap: !_canManage
                          ? null
                          : () async {
                              final p = (_e[k] as String).split(':');
                              final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1])));
                              if (t != null) setState(() => _e[k] = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00');
                            },
                    ),
                  ),
              ]),
              _tf('break_minutes', 'Unpaid break (minutes)', _e['break_minutes'], type: TextInputType.number, enabled: _canManage),
              if (_canManage) ...[
                _section('Personal (private)'),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _priv['citizenship'] as String? ?? 'citizen',
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: const [
                        DropdownMenuItem(value: 'citizen', child: Text('Citizen')),
                        DropdownMenuItem(value: 'pr', child: Text('Permanent resident')),
                        DropdownMenuItem(value: 'foreign', child: Text('Foreign worker')),
                      ],
                      onChanged: (v) => setState(() => _priv['citizenship'] = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: _tf('nationality', 'Nationality (code)', _priv['nationality'])),
                ]),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _priv['id_type'] as String? ?? 'mykad',
                      decoration: const InputDecoration(labelText: 'ID type'),
                      items: const [
                        DropdownMenuItem(value: 'mykad', child: Text('MyKad')),
                        DropdownMenuItem(value: 'mypr', child: Text('MyPR')),
                        DropdownMenuItem(value: 'passport', child: Text('Passport')),
                        DropdownMenuItem(value: 'other', child: Text('Other')),
                      ],
                      onChanged: (v) => setState(() => _priv['id_type'] = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: _tf('id_no', 'ID number', _priv['id_no'])),
                ]),
                _date('Date of birth (needed for EPF/SOCSO age rules)', _priv['date_of_birth'] as String?, (v) => _priv['date_of_birth'] = v),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      value: _priv['gender'] as String?,
                      decoration: const InputDecoration(labelText: 'Gender'),
                      items: const [
                        DropdownMenuItem(value: null, child: Text('—')),
                        DropdownMenuItem(value: 'female', child: Text('Female')),
                        DropdownMenuItem(value: 'male', child: Text('Male')),
                      ],
                      onChanged: (v) => setState(() => _priv['gender'] = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _priv['marital_status'] as String? ?? 'single',
                      decoration: const InputDecoration(labelText: 'Marital status'),
                      items: [for (final m in const ['single', 'married', 'divorced', 'widowed']) DropdownMenuItem(value: m, child: Text(m))],
                      onChanged: (v) => setState(() => _priv['marital_status'] = v),
                    ),
                  ),
                ]),
                _tf('address', 'Address', _priv['address']),
                _tf('emergency_contact', 'Emergency contact', _priv['emergency_contact']),
                Row(children: [
                  Expanded(child: _tf('bank_name', 'Bank', _priv['bank_name'])),
                  const SizedBox(width: 12),
                  Expanded(child: _tf('bank_account', 'Account no.', _priv['bank_account'])),
                ]),
              ],
              if (_canPay) ...[
                _section('Pay'),
                SegmentedButton<String>(
                  segments: const [ButtonSegment(value: 'monthly', label: Text('Monthly')), ButtonSegment(value: 'daily', label: Text('Daily')), ButtonSegment(value: 'hourly', label: Text('Hourly'))],
                  selected: {_pay['pay_basis'] as String},
                  onSelectionChanged: (v) => setState(() => _pay['pay_basis'] = v.first),
                ),
                if (_pay['pay_basis'] == 'monthly') _tf('basic_salary', 'Basic salary per month', _pay['basic_salary'], type: const TextInputType.numberWithOptions(decimal: true), helper: 'Minimum wage RM1,700 (full-time)'),
                if (_pay['pay_basis'] == 'daily') _tf('daily_rate', 'Daily rate', _pay['daily_rate'], type: const TextInputType.numberWithOptions(decimal: true)),
                if (_pay['pay_basis'] == 'hourly') _tf('hourly_rate', 'Hourly rate', _pay['hourly_rate'], type: const TextInputType.numberWithOptions(decimal: true)),
                SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Paid overtime'), value: _pay['ot_eligible'] as bool, onChanged: (v) => setState(() => _pay['ot_eligible'] = v)),
                if (_id != null) ...[
                  Row(children: [
                    const Text('Monthly allowances & deductions'),
                    const Spacer(),
                    IconButton(onPressed: _addItem, icon: const Icon(Icons.add)),
                  ]),
                  for (final it in _items)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(it['name'] as String),
                      subtitle: Text(it['kind'] == 'earning'
                          ? [if (it['taxable'] == true) 'taxable', if (it['epf'] == true) 'EPF', if (it['socso'] == true) 'SOCSO'].join(' · ')
                          : 'deduction'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('${it['kind'] == 'deduction' ? '−' : ''}${it['amount']}'),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () async {
                            await _s.db.from('employee_pay_items').delete().eq('id', it['id']);
                            _load();
                          },
                        ),
                      ]),
                    ),
                ],
                _section('Statutory'),
                Row(children: [
                  Expanded(child: _tf('epf_no', 'EPF no.', _pay['epf_no'])),
                  const SizedBox(width: 12),
                  Expanded(child: _tf('socso_no', 'SOCSO no.', _pay['socso_no'])),
                ]),
                _tf('tax_no', 'Income tax no. (e.g. SG…/IG…)', _pay['tax_no']),
                DropdownButtonFormField<int>(
                  value: _pay['tax_category'] as int,
                  decoration: const InputDecoration(labelText: 'PCB category'),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1 — Single')),
                    DropdownMenuItem(value: 2, child: Text('2 — Married, spouse not working')),
                    DropdownMenuItem(value: 3, child: Text('3 — Married, spouse working / divorced / widowed')),
                  ],
                  onChanged: (v) => setState(() => _pay['tax_category'] = v),
                ),
                Row(children: [
                  Expanded(child: _tf('qualifying_children', 'Child relief units', _pay['qualifying_children'], type: const TextInputType.numberWithOptions(decimal: true))),
                  const SizedBox(width: 12),
                  Expanded(child: _tf('zakat_monthly', 'Zakat per month', _pay['zakat_monthly'], type: const TextInputType.numberWithOptions(decimal: true))),
                ]),
                _tf('other_reliefs_monthly', 'Other reliefs per month (from TP1)', _pay['other_reliefs_monthly'], type: const TextInputType.numberWithOptions(decimal: true)),
                CheckboxListTile(contentPadding: EdgeInsets.zero, value: _pay['disabled'] as bool? ?? false, onChanged: (v) => setState(() => _pay['disabled'] = v), title: const Text('Disabled individual (OKU)')),
                if (_pay['tax_category'] == 2)
                  CheckboxListTile(contentPadding: EdgeInsets.zero, value: _pay['spouse_disabled'] as bool? ?? false, onChanged: (v) => setState(() => _pay['spouse_disabled'] = v), title: const Text('Disabled spouse')),
                Wrap(spacing: 6, children: [
                  for (final k in const [('socso_enabled', 'SOCSO'), ('eis_enabled', 'EIS'), ('pcb_enabled', 'PCB')])
                    FilterChip(label: Text(k.$2), selected: _pay[k.$1] as bool, onSelected: (v) => setState(() => _pay[k.$1] = v)),
                ]),
                const SizedBox(height: 8),
                const Text('Joined mid-year? Earnings from the previous employer this year (from their EA/CP8D):', style: TextStyle(fontSize: 12)),
                Row(children: [
                  Expanded(child: _tf('prev_gross', 'Gross', (_pay['prev_gross'] ?? 0) == 0 ? null : _pay['prev_gross'], type: const TextInputType.numberWithOptions(decimal: true))),
                  const SizedBox(width: 8),
                  Expanded(child: _tf('prev_epf', 'EPF', (_pay['prev_epf'] ?? 0) == 0 ? null : _pay['prev_epf'], type: const TextInputType.numberWithOptions(decimal: true))),
                  const SizedBox(width: 8),
                  Expanded(child: _tf('prev_pcb', 'PCB', (_pay['prev_pcb'] ?? 0) == 0 ? null : _pay['prev_pcb'], type: const TextInputType.numberWithOptions(decimal: true))),
                ]),
              ],
              if (_balances.isNotEmpty) ...[
                _section('Leave ${DateTime.now().year}'),
                for (final b in _balances.where((b) => (b['entitled'] as num) < 365))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(b['name'] as String),
                    subtitle: Text('Entitled ${b['entitled']} · taken ${b['taken']} · pending ${b['pending']}'),
                    trailing: Text('${b['balance']} left'),
                    onTap: _canManage ? () => _adjustLeave(b) : null,
                  ),
              ],
              const SizedBox(height: 16),
              if (_canManage || _canPay) FilledButton(onPressed: _busy ? null : _save, child: Text(_id == null ? 'Add employee' : 'Save')),
              const SizedBox(height: 40),
            ]),
    );
  }
}
