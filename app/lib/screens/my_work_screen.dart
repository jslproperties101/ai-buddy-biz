import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/printing_service.dart';
import '../services/session.dart';

const claimCategories = {
  'travel': 'Travel',
  'mileage': 'Mileage',
  'meal': 'Meal',
  'parking': 'Parking',
  'toll': 'Toll',
  'phone': 'Phone',
  'medical': 'Medical',
  'training': 'Training',
  'supplies': 'Supplies',
  'other': 'Other',
};

/// Staff self-service: clock in/out, leave, claims, payslips.
class MyWorkScreen extends StatefulWidget {
  const MyWorkScreen({super.key});
  @override
  State<MyWorkScreen> createState() => _MyWorkScreenState();
}

class _MyWorkScreenState extends State<MyWorkScreen> {
  String? _employeeId;
  Map<String, dynamic>? _open; // open attendance row
  List<Map<String, dynamic>> _recent = [];
  List<Map<String, dynamic>> _balances = [];
  List<Map<String, dynamic>> _leave = [];
  List<Map<String, dynamic>> _claims = [];
  List<Map<String, dynamic>> _payslips = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  Session get _s => Session.instance;
  NumberFormat get _money => NumberFormat.currency(symbol: '${_s.currency} ');

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      _employeeId = await _s.db.rpc('my_employee_id', params: {'p_tenant': _s.tenantId}) as String?;
      if (_employeeId != null) {
        final id = _employeeId!;
        _recent = List<Map<String, dynamic>>.from(await _s.db.from('attendance').select().eq('employee_id', id).order('clock_in', ascending: false).limit(14));
        _open = _recent.where((a) => a['clock_out'] == null).firstOrNull;
        _balances = List<Map<String, dynamic>>.from(await _s.db.rpc('leave_balances', params: {'p_employee': id}) as List);
        _leave = List<Map<String, dynamic>>.from(await _s.db.from('leave_requests').select('*, leave_types(name)').eq('employee_id', id).order('start_date', ascending: false).limit(20));
        _claims = List<Map<String, dynamic>>.from(await _s.db.from('claims').select().eq('employee_id', id).order('created_at', ascending: false).limit(20));
        _payslips = List<Map<String, dynamic>>.from(await _s.db.from('payslips').select('*, payroll_runs(year, month, pay_date)').eq('employee_id', id).limit(24));
        _payslips.sort((a, b) => ((b['payroll_runs']['year'] as int) * 100 + (b['payroll_runs']['month'] as int))
            .compareTo((a['payroll_runs']['year'] as int) * 100 + (a['payroll_runs']['month'] as int)));
      }
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Offline. My work needs a connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _clock() async {
    setState(() => _busy = true);
    try {
      if (_open == null) {
        await _s.db.rpc('clock_in', params: {'p_tenant': _s.tenantId, 'p_outlet': _s.outlet?.id});
        _snack('Clocked in at ${DateFormat('HH:mm').format(DateTime.now())}');
      } else {
        await _s.db.rpc('clock_out', params: {'p_tenant': _s.tenantId});
        _snack('Clocked out at ${DateFormat('HH:mm').format(DateTime.now())}');
      }
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestLeave() async {
    final types = _balances.where((b) => (b['balance'] as num) > 0).toList();
    if (types.isEmpty) {
      _snack('No leave balance available');
      return;
    }
    var type = types.first;
    DateTimeRange? range;
    String? half;
    final reason = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Apply for leave', style: Theme.of(context).textTheme.titleLarge),
                DropdownButtonFormField<Map<String, dynamic>>(
                  value: type,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: [for (final t in types) DropdownMenuItem(value: t, child: Text('${t['name']} (${t['balance']} left)'))],
                  onChanged: (v) => set(() => type = v!),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Dates'),
                  subtitle: Text(range == null
                      ? 'Choose…'
                      : '${DateFormat('EEE d MMM').format(range!.start)} – ${DateFormat('EEE d MMM').format(range!.end)}'),
                  onTap: () async {
                    final r = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime.now().subtract(const Duration(days: 30)),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (r != null) set(() => range = r);
                  },
                ),
                if (range != null && range!.start == range!.end)
                  SegmentedButton<String?>(
                    segments: const [
                      ButtonSegment(value: null, label: Text('Full day')),
                      ButtonSegment(value: 'am', label: Text('Morning')),
                      ButtonSegment(value: 'pm', label: Text('Afternoon')),
                    ],
                    selected: {half},
                    onSelectionChanged: (v) => set(() => half = v.first),
                  ),
                TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason (optional)')),
                const SizedBox(height: 12),
                FilledButton(onPressed: range == null ? null : () => Navigator.pop(context, true), child: const Text('Submit')),
              ]),
            ),
          ),
        ),
      ),
    );
    if (ok != true || range == null) return;
    final d = DateFormat('yyyy-MM-dd');
    try {
      final r = await _s.db.rpc('request_leave', params: {
        'p_type': type['leave_type_id'],
        'p_start': d.format(range!.start),
        'p_end': d.format(range!.end),
        'p_half': half,
        'p_reason': reason.text.trim().isEmpty ? null : reason.text.trim(),
      });
      _snack('Requested ${r['days']} day(s) — waiting for approval');
      _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _submitClaim() async {
    var cat = 'parking';
    final desc = TextEditingController();
    final amt = TextEditingController();
    final km = TextEditingController();
    var date = DateTime.now();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('New claim', style: Theme.of(context).textTheme.titleLarge),
                Wrap(spacing: 6, children: [
                  for (final c in claimCategories.entries) ChoiceChip(label: Text(c.value), selected: cat == c.key, onSelected: (_) => set(() => cat = c.key)),
                ]),
                TextField(controller: desc, decoration: const InputDecoration(labelText: 'What for? *')),
                Row(children: [
                  Expanded(child: TextField(controller: amt, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Amount (${_s.currency}) *'))),
                  if (cat == 'mileage') ...[
                    const SizedBox(width: 12),
                    Expanded(child: TextField(controller: km, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Km'))),
                  ],
                ]),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Date'),
                  subtitle: Text(DateFormat('d MMM yyyy').format(date)),
                  onTap: () async {
                    final d = await showDatePicker(context: context, initialDate: date, firstDate: DateTime.now().subtract(const Duration(days: 90)), lastDate: DateTime.now());
                    if (d != null) set(() => date = d);
                  },
                ),
                const Text('Keep the receipt — your approver may ask for it.', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 12),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Submit')),
              ]),
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    final a = double.tryParse(amt.text);
    if (a == null || a <= 0 || desc.text.trim().isEmpty) {
      _snack('Enter what it was for and the amount');
      return;
    }
    try {
      await _s.db.rpc('submit_claim', params: {
        'p_tenant': _s.tenantId,
        'p_category': cat,
        'p_description': desc.text.trim(),
        'p_amount': a,
        'p_date': DateFormat('yyyy-MM-dd').format(date),
        'p_km': double.tryParse(km.text),
      });
      _snack('Claim submitted');
      _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _cancelLeave(Map<String, dynamic> r) async {
    try {
      await _s.db.rpc('cancel_leave', params: {'p_request': r['id']});
      _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _cancelClaim(Map<String, dynamic> c) async {
    try {
      await _s.db.from('claims').update({'status': 'cancelled'}).eq('id', c['id']);
      _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _openPayslip(Map<String, dynamic> p) async {
    final items = List<Map<String, dynamic>>.from(await _s.db.from('payslip_items').select().eq('payslip_id', p['id']).order('sort_order'));
    final emp = await _s.db.from('employees').select().eq('id', _employeeId!).single();
    await PrintingService.printPayslip(payslip: p, items: items, employee: emp, year: p['payroll_runs']['year'] as int, month: p['payroll_runs']['month'] as int);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final fmtT = DateFormat('HH:mm');
    final fmtD = DateFormat('EEE d MMM');
    return Scaffold(
      appBar: AppBar(title: const Text('My work')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _employeeId == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error ?? 'Your login is not linked to an employee record yet. Ask HR to add you with the same email you sign in with.',
                        textAlign: TextAlign.center),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.all(16), children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(children: [
                          Text(_open == null ? 'You are clocked out' : 'Clocked in since ${fmtT.format(DateTime.parse(_open!['clock_in'] as String).toLocal())}',
                              style: t.titleMedium),
                          if (_open != null && (_open!['late_minutes'] as int) > 0)
                            Text('${_open!['late_minutes']} min late', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _busy ? null : _clock,
                              icon: Icon(_open == null ? Icons.login : Icons.logout),
                              label: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_open == null ? 'Clock in' : 'Clock out')),
                            ),
                          ),
                        ]),
                      ),
                    ),
                    _head('Leave', 'Apply', _requestLeave),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final b in _balances.where((b) => (b['entitled'] as num) > 0 && (b['entitled'] as num) < 365))
                        Chip(label: Text('${b['code']} ${b['balance']}/${b['entitled']}')),
                    ]),
                    for (final r in _leave.take(6))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${r['leave_types']['name']} · ${r['days']} day(s)'),
                        subtitle: Text('${fmtD.format(DateTime.parse(r['start_date'] as String))} – ${fmtD.format(DateTime.parse(r['end_date'] as String))}'
                            '${r['decision_note'] != null ? ' · ${r['decision_note']}' : ''}'),
                        trailing: r['status'] == 'pending' || (r['status'] == 'approved' && DateTime.parse(r['start_date'] as String).isAfter(DateTime.now()))
                            ? TextButton(onPressed: () => _cancelLeave(r), child: Text('${r['status']} · cancel'))
                            : Text(r['status'] as String),
                      ),
                    _head('Claims', 'New', _submitClaim),
                    for (final c in _claims.take(6))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(c['description'] as String),
                        subtitle: Text('${claimCategories[c['category']]} · ${c['claim_date']}'),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text('${_money.format(c['amount'])} · ${c['status']}'),
                          if (c['status'] == 'pending') IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _cancelClaim(c)),
                        ]),
                      ),
                    _head('Payslips', null, null),
                    if (_payslips.isEmpty) const Text('None yet'),
                    for (final p in _payslips)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.description_outlined),
                        title: Text(DateFormat('MMMM yyyy').format(DateTime(p['payroll_runs']['year'] as int, p['payroll_runs']['month'] as int))),
                        subtitle: Text('Net ${_money.format(p['net_pay'])}'),
                        trailing: const Icon(Icons.picture_as_pdf_outlined),
                        onTap: () => _openPayslip(p),
                      ),
                    _head('Recent attendance', null, null),
                    for (final a in _recent)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${fmtD.format(DateTime.parse(a['work_date'] as String))} · ${fmtT.format(DateTime.parse(a['clock_in'] as String).toLocal())}'
                            ' – ${a['clock_out'] == null ? '…' : fmtT.format(DateTime.parse(a['clock_out'] as String).toLocal())}'),
                        subtitle: Text([
                          if (a['worked_minutes'] != null) '${((a['worked_minutes'] as int) / 60).toStringAsFixed(1)} h',
                          if ((a['late_minutes'] as int) > 0) '${a['late_minutes']} min late',
                          if ((a['ot_minutes'] as int) > 0) 'OT ${a['ot_minutes']} min${(a['ot_approved_minutes'] as int) > 0 ? ' (${a['ot_approved_minutes']} approved)' : ''}',
                          if (a['day_type'] != 'normal') (a['day_type'] as String).replaceAll('_', ' '),
                        ].join(' · ')),
                      ),
                    const SizedBox(height: 40),
                  ]),
                ),
    );
  }

  Widget _head(String title, String? action, VoidCallback? onTap) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Row(children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (action != null) TextButton.icon(onPressed: onTap, icon: const Icon(Icons.add), label: Text(action)),
        ]),
      );
}
