import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/printing_service.dart';
import '../services/session.dart';

class PayrollListTab extends StatefulWidget {
  const PayrollListTab({super.key});
  @override
  State<PayrollListTab> createState() => _PayrollListTabState();
}

class _PayrollListTabState extends State<PayrollListTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _runs = [];
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
      _runs = List<Map<String, dynamic>>.from(await _s.db
          .from('payroll_run_summary')
          .select()
          .eq('tenant_id', _s.tenantId!)
          .order('year', ascending: false)
          .order('month', ascending: false)
          .limit(36));
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _new() async {
    final now = DateTime.now();
    var ym = DateTime(now.year, now.month);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Run payroll'),
          content: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(onPressed: () => set(() => ym = DateTime(ym.year, ym.month - 1)), icon: const Icon(Icons.chevron_left)),
            Text(DateFormat('MMMM yyyy').format(ym), style: Theme.of(context).textTheme.titleMedium),
            IconButton(onPressed: () => set(() => ym = DateTime(ym.year, ym.month + 1)), icon: const Icon(Icons.chevron_right)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Prepare')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      final id = await _s.db.rpc('create_payroll_run', params: {'p_tenant': _s.tenantId, 'p_year': ym.year, 'p_month': ym.month}) as String;
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PayrollRunScreen(runId: id)));
      _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(children: [
                if (_runs.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No payroll yet'))),
                for (final r in _runs)
                  ListTile(
                    title: Text(DateFormat('MMMM yyyy').format(DateTime(r['year'] as int, r['month'] as int))),
                    subtitle: Text('${r['headcount']} staff · net ${_money.format(r['net'])} · cost ${_money.format(r['employer_cost'])}'
                        '${(r['warnings'] as int) > 0 ? ' · ${r['warnings']} warning(s)' : ''}'),
                    trailing: Chip(label: Text((r['status'] as String).toUpperCase())),
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PayrollRunScreen(runId: r['id'] as String)));
                      _load();
                    },
                  ),
                const SizedBox(height: 80),
              ]),
            ),
      floatingActionButton: _s.can('hr.payroll.run')
          ? FloatingActionButton.extended(heroTag: null, onPressed: _new, icon: const Icon(Icons.payments_outlined), label: const Text('Run payroll'))
          : null,
    );
  }
}

class PayrollRunScreen extends StatefulWidget {
  final String runId;
  const PayrollRunScreen({super.key, required this.runId});
  @override
  State<PayrollRunScreen> createState() => _PayrollRunScreenState();
}

class _PayrollRunScreenState extends State<PayrollRunScreen> {
  Map<String, dynamic>? _run;
  List<Map<String, dynamic>> _slips = [];
  bool _loading = true;
  bool _busy = false;
  AppSession get _s => AppSession.instance;
  NumberFormat get _money => NumberFormat.currency(symbol: '${_s.currency} ');
  bool get _draft => _run?['status'] == 'draft';
  bool get _canRun => _s.can('hr.payroll.run');
  String get _period => _run == null ? '' : DateFormat('MMMM yyyy').format(DateTime(_run!['year'] as int, _run!['month'] as int));

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _load() async {
    try {
      _run = await _s.db.from('payroll_run_summary').select().eq('id', widget.runId).single();
      _slips = List<Map<String, dynamic>>.from(await _s.db
          .from('payslips')
          .select('*, employees(full_name, employee_no, job_title, department, start_date)')
          .eq('run_id', widget.runId));
      _slips.sort((a, b) => (a['employees']['full_name'] as String).compareTo(b['employees']['full_name'] as String));
    } catch (e) {
      _snack('Could not load: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _rpc(String fn, Map<String, dynamic> params, String done, {String? confirm}) async {
    if (confirm != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Are you sure?'),
          content: Text(confirm),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      await _s.db.rpc(fn, params: params);
      _snack(done);
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSlip(Map<String, dynamic> p) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PayslipSheet(payslip: p, editable: _draft && _canRun, period: _period, onChanged: _load),
    );
    _load();
  }

  Future<void> _printAll() async {
    final ids = _slips.map((p) => p['id']).toList();
    final items = List<Map<String, dynamic>>.from(await _s.db.from('payslip_items').select().inFilter('payslip_id', ids).order('sort_order'));
    for (final p in _slips) {
      await PrintingService.printPayslip(
        payslip: p,
        items: items.where((i) => i['payslip_id'] == p['id']).toList(),
        employee: Map<String, dynamic>.from(p['employees'] as Map),
        year: _run!['year'] as int,
        month: _run!['month'] as int,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _run;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Payroll $_period'),
        actions: [
          if (r != null && !_draft) IconButton(tooltip: 'Print payslips', onPressed: _printAll, icon: const Icon(Icons.print_outlined)),
          if (r != null)
            IconButton(
              tooltip: 'Statutory summary',
              onPressed: () => PrintingService.printPayrollSummary(run: r, slips: _slips),
              icon: const Icon(Icons.summarize_outlined),
            ),
        ],
      ),
      body: _loading || r == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                Row(children: [
                  Chip(label: Text((r['status'] as String).toUpperCase())),
                  const Spacer(),
                  Text('${r['headcount']} staff'),
                ]),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _kpi('Gross', r['gross']),
                  _kpi('Net to staff', r['net']),
                  _kpi('EPF', r['epf']),
                  _kpi('SOCSO', r['socso']),
                  _kpi('EIS', r['eis']),
                  _kpi('PCB', r['pcb']),
                  _kpi('Total cost', r['employer_cost']),
                ]),
                const SizedBox(height: 12),
                if (_draft && _canRun) ...[
                  Row(children: [
                    Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : () => _rpc('recalc_payroll_run', {'p_run': widget.runId}, 'Recalculated'), icon: const Icon(Icons.refresh), label: const Text('Recalculate'))),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : () => _rpc('approve_payroll_run', {'p_run': widget.runId}, 'Approved — staff can now see their payslips',
                            confirm: 'Approving locks these payslips, posts them to your accounts and shows them to staff.'),
                        icon: const Icon(Icons.verified_outlined),
                        label: const Text('Approve'),
                      ),
                    ),
                  ]),
                  const Text('Recalculate after changing attendance, leave, claims or employee pay.', style: TextStyle(fontSize: 12)),
                ],
                if (r['status'] == 'approved' && _canRun)
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _rpc('mark_payroll_paid', {'p_run': widget.runId}, 'Marked as paid'),
                    icon: const Icon(Icons.account_balance_outlined),
                    label: const Text('Mark salaries paid'),
                  ),
                if (!_draft && _canRun) ...[
                  const SizedBox(height: 8),
                  Text('Pay the authorities by the 15th of next month', style: t.bodySmall),
                  Wrap(spacing: 8, children: [
                    for (final s in const [('epf', 'EPF', 'epf_paid'), ('socso_eis', 'SOCSO + EIS', 'socso_paid'), ('pcb', 'PCB', 'pcb_paid')])
                      FilterChip(
                        label: Text('${s.$2} ${r[s.$3] == true ? 'paid' : 'unpaid'}'),
                        selected: r[s.$3] == true,
                        onSelected: r[s.$3] == true ? null : (_) => _rpc('pay_statutory', {'p_run': widget.runId, 'p_scheme': s.$1}, '${s.$2} recorded as paid'),
                      ),
                  ]),
                ],
                const Divider(height: 24),
                for (final p in _slips)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: (p['warnings'] as List).isNotEmpty ? Icon(Icons.warning_amber, color: Theme.of(context).colorScheme.error) : const Icon(Icons.person_outline),
                    title: Text(p['employees']['full_name'] as String),
                    subtitle: Text('Gross ${_money.format(p['gross'])} · EPF ${p['epf_ee']} · PCB ${p['pcb']}'
                        '${(p['warnings'] as List).isNotEmpty ? '\n${(p['warnings'] as List).join('\n')}' : ''}'),
                    isThreeLine: (p['warnings'] as List).isNotEmpty,
                    trailing: Text(_money.format(p['net_pay']), style: const TextStyle(fontWeight: FontWeight.bold)),
                    onTap: () => _openSlip(p),
                  ),
                const SizedBox(height: 40),
              ]),
            ),
    );
  }

  Widget _kpi(String label, dynamic v) => SizedBox(
        width: 150,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              FittedBox(child: Text(_money.format(v), style: Theme.of(context).textTheme.titleMedium)),
            ]),
          ),
        ),
      );
}

class _PayslipSheet extends StatefulWidget {
  final Map<String, dynamic> payslip;
  final bool editable;
  final String period;
  final Future<void> Function() onChanged;
  const _PayslipSheet({required this.payslip, required this.editable, required this.period, required this.onChanged});
  @override
  State<_PayslipSheet> createState() => _PayslipSheetState();
}

class _PayslipSheetState extends State<_PayslipSheet> {
  late Map<String, dynamic> _p = widget.payslip;
  List<Map<String, dynamic>> _items = [];
  AppSession get _s => AppSession.instance;
  NumberFormat get _money => NumberFormat.currency(symbol: '${_s.currency} ');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await _s.db.from('payslip_items').select().eq('payslip_id', _p['id']).order('sort_order');
    final p = await _s.db.from('payslips').select('*, employees(full_name, employee_no, job_title, department, start_date)').eq('id', _p['id']).single();
    if (mounted) setState(() {
      _items = List<Map<String, dynamic>>.from(items);
      _p = p;
    });
  }

  Future<void> _add() async {
    var kind = 'earning';
    var code = 'bonus';
    final name = TextEditingController(text: 'Bonus'), amt = TextEditingController();
    var taxable = true, additional = true, epf = true, socso = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Add to this payslip'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: code,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(value: 'bonus', child: Text('Bonus')),
                  DropdownMenuItem(value: 'commission', child: Text('Commission')),
                  DropdownMenuItem(value: 'allowance', child: Text('One-off allowance')),
                  DropdownMenuItem(value: 'arrears', child: Text('Back pay (arrears)')),
                  DropdownMenuItem(value: 'advance', child: Text('Salary advance repayment (deduction)')),
                  DropdownMenuItem(value: 'deduction', child: Text('Other deduction')),
                ],
                onChanged: (v) => set(() {
                  code = v!;
                  kind = (v == 'advance' || v == 'deduction') ? 'deduction' : 'earning';
                  additional = const ['bonus', 'commission', 'arrears'].contains(v);
                  socso = v == 'commission' || v == 'allowance';
                  name.text = {'bonus': 'Bonus', 'commission': 'Commission', 'allowance': 'Allowance', 'arrears': 'Arrears', 'advance': 'Advance repayment', 'deduction': 'Deduction'}[v]!;
                }),
              ),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Description')),
              TextField(controller: amt, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount')),
              if (kind == 'earning') ...[
                CheckboxListTile(contentPadding: EdgeInsets.zero, value: taxable, onChanged: (v) => set(() => taxable = v!), title: const Text('Taxable')),
                CheckboxListTile(contentPadding: EdgeInsets.zero, value: additional, onChanged: (v) => set(() => additional = v!), title: const Text('Additional pay for PCB (bonus/commission/arrears)')),
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
    if (ok != true || a == null) return;
    try {
      await _s.db.rpc('add_payslip_item', params: {
        'p_payslip': _p['id'],
        'p_kind': kind,
        'p_code': code,
        'p_name': name.text.trim(),
        'p_amount': a,
        'p_taxable': kind == 'earning' && taxable,
        'p_additional': kind == 'earning' && additional,
        'p_epf': kind == 'earning' && epf,
        'p_socso': kind == 'earning' && socso,
      });
      await _load();
      await widget.onChanged();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _remove(Map<String, dynamic> it) async {
    try {
      await _s.db.rpc('remove_payslip_item', params: {'p_item': it['id']});
      await _load();
      await widget.onChanged();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final pcb = (p['calc'] as Map?)?['pcb'] as Map?;
    Widget row(String a, dynamic v, {bool bold = false, bool neg = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(a, style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null)),
            Text('${neg ? '−' : ''}${_money.format(v)}', style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null),
          ]),
        );
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text(p['employees']['full_name'] as String, style: Theme.of(context).textTheme.titleLarge),
          Text(widget.period),
          const Divider(),
          for (final it in _items)
            Row(children: [
              Expanded(child: Text(it['name'] as String)),
              Text('${it['kind'] == 'deduction' ? '−' : ''}${_money.format(it['amount'])}'),
              if (widget.editable && it['system'] != true)
                IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 16), onPressed: () => _remove(it)),
            ]),
          if (widget.editable) Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Bonus, commission, deduction…'))),
          const Divider(),
          row('EPF (employee)', p['epf_ee'], neg: true),
          row('SOCSO (employee)', p['socso_ee'], neg: true),
          row('EIS (employee)', p['eis_ee'], neg: true),
          row('PCB (income tax)', p['pcb'], neg: true),
          if ((p['zakat'] as num) > 0) row('Zakat', p['zakat'], neg: true),
          const Divider(),
          row('Net pay', p['net_pay'], bold: true),
          const SizedBox(height: 12),
          Text('Employer pays', style: Theme.of(context).textTheme.titleSmall),
          row('EPF', p['epf_er']),
          row('SOCSO', p['socso_er']),
          row('EIS', p['eis_er']),
          row('Total cost to business', p['employer_cost'], bold: true),
          if (pcb != null && pcb['P'] != null) ...[
            const SizedBox(height: 12),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('How PCB was worked out'),
              children: [
                Text('Yearly chargeable income estimate P = ${pcb['P']}\nReliefs ${pcb['reliefs']} · EPF counted this month ${pcb['K1']} · '
                    'future months ${pcb['K2']} × ${pcb['n']}\nTax for the year ${pcb['yearly_tax']} · this month ${pcb['mtd_normal']}'
                    '${(pcb['mtd_additional'] as num? ?? 0) > 0 ? ' + on bonus ${pcb['mtd_additional']}' : ''}'
                    '${(pcb['zakat'] as num? ?? 0) > 0 ? ' − zakat ${pcb['zakat']}' : ''}',
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
          ],
          for (final w in (p['warnings'] as List)) ListTile(dense: true, leading: const Icon(Icons.warning_amber), title: Text(w as String)),
        ]),
      ),
    );
  }
}
