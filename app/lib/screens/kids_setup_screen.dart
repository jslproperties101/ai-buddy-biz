import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/kids.dart';
import '../services/session.dart';

/// Centre settings, rooms & ratios, fee plans, extra charges and monthly fee invoices.
class KidsSetupTab extends StatefulWidget {
  const KidsSetupTab({super.key});
  @override
  State<KidsSetupTab> createState() => _KidsSetupTabState();
}

class _KidsSetupTabState extends State<KidsSetupTab> with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _settings;
  List<Map<String, dynamic>> _rooms = [];
  List<Map<String, dynamic>> _plans = [];
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  bool _loading = true;
  bool _billing = false;
  AppSession get _s => AppSession.instance;
  bool get _manage => _s.can('kids.manage');

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        _s.db.from('kids_settings').select().eq('tenant_id', _s.tenantId!).maybeSingle(),
        _s.db.from('kids_rooms').select().eq('tenant_id', _s.tenantId!).order('min_age_months'),
        _s.db.from('kids_fee_plans').select().eq('tenant_id', _s.tenantId!).order('name'),
      ]);
      _settings = r[0] == null ? null : Map<String, dynamic>.from(r[0] as Map);
      _rooms = List<Map<String, dynamic>>.from(r[1] as List);
      _plans = List<Map<String, dynamic>>.from(r[2] as List);
    } catch (e) {
      _snack(Kids.errorText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _run(Future<void> Function() f, String ok) async {
    try {
      await f();
      _snack(ok);
    } catch (e) {
      _snack(Kids.errorText(e));
    }
    _load();
  }

  String _t(dynamic v) => (v ?? '').toString().length >= 5 ? v.toString().substring(0, 5) : '${v ?? ''}';

  Future<void> _editSettings() async {
    final st = _settings ?? {};
    String type = (st['centre_type'] ?? 'taska') as String;
    TimeOfDay open = _tod(st['opening_time'], const TimeOfDay(hour: 7, minute: 0));
    TimeOfDay close = _tod(st['closing_time'], const TimeOfDay(hour: 18, minute: 30));
    final fee = TextEditingController(text: '${st['late_fee'] ?? 0}');
    final block = TextEditingController(text: '${st['late_block_minutes'] ?? 15}');
    final grace = TextEditingController(text: '${st['late_grace_minutes'] ?? 5}');
    final due = TextEditingController(text: '${st['due_days'] ?? 7}');
    bool notify = (st['notify_checkin'] ?? true) as bool;
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => StatefulBuilder(
        builder: (context, set) => Scaffold(
          appBar: AppBar(title: const Text('Centre settings'), actions: [
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            DropdownButtonFormField<String>(
              value: type,
              decoration: const InputDecoration(labelText: 'Type of centre'),
              items: const [
                DropdownMenuItem(value: 'taska', child: Text('TASKA — childcare 0–4 (JKM)')),
                DropdownMenuItem(value: 'tadika', child: Text('TADIKA — kindergarten 4–6 (KPM)')),
                DropdownMenuItem(value: 'after_school', child: Text('After-school care / transit')),
                DropdownMenuItem(value: 'other', child: Text('Other')),
              ],
              onChanged: (v) => set(() => type = v ?? 'taska'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Opens ${open.format(context)} · closes ${close.format(context)}'),
              trailing: const Icon(Icons.schedule),
              onTap: () async {
                final o = await showTimePicker(context: context, initialTime: open, helpText: 'Opening time');
                if (o == null || !context.mounted) return;
                final c = await showTimePicker(context: context, initialTime: close, helpText: 'Closing time');
                if (c != null) set(() {
                  open = o;
                  close = c;
                });
              },
            ),
            const SizedBox(height: 8),
            Text('Late pick-up', style: Theme.of(context).textTheme.titleSmall),
            Row(children: [
              Expanded(child: TextField(controller: fee, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Fee (${_s.currency})'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: block, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'per … minutes'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: grace, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Grace (min)'))),
            ]),
            const Text('Late fees are added to the next monthly invoice automatically. Set the fee to 0 to only record lateness.', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            TextField(controller: due, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Fees due (days after the 1st)')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Message parents at check-in and pick-up'),
              value: notify,
              onChanged: (v) => set(() => notify = v),
            ),
          ]),
        ),
      ),
    ));
    if (ok != true) return;
    String hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    await _run(
        () async => _s.db.from('kids_settings').upsert({
              'tenant_id': _s.tenantId,
              'centre_type': type,
              'opening_time': hm(open),
              'closing_time': hm(close),
              'late_fee': double.tryParse(fee.text) ?? 0,
              'late_block_minutes': int.tryParse(block.text) ?? 15,
              'late_grace_minutes': int.tryParse(grace.text) ?? 5,
              'due_days': int.tryParse(due.text) ?? 7,
              'notify_checkin': notify,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            }),
        'Saved');
  }

  TimeOfDay _tod(dynamic v, TimeOfDay d) {
    final p = '${v ?? ''}'.split(':');
    if (p.length < 2) return d;
    return TimeOfDay(hour: int.tryParse(p[0]) ?? d.hour, minute: int.tryParse(p[1]) ?? d.minute);
  }

  Future<void> _editRoom([Map<String, dynamic>? r]) async {
    final name = TextEditingController(text: (r?['name'] ?? '') as String);
    final minA = TextEditingController(text: '${r?['min_age_months'] ?? 0}');
    final maxA = TextEditingController(text: '${r?['max_age_months'] ?? 12}');
    final ratio = TextEditingController(text: '${r?['ratio_children'] ?? 3}');
    final cap = TextEditingController(text: r?['capacity']?.toString() ?? '');
    bool active = (r?['active'] ?? true) as bool;
    int suggested() {
      final m = int.tryParse(maxA.text) ?? 48;
      return m <= 12 ? 3 : m <= 36 ? 5 : m <= 60 ? 10 : 15;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(r == null ? 'Add room' : 'Edit room'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (e.g. Babies, Toddlers)')),
              Row(children: [
                Expanded(child: TextField(controller: minA, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'From age (months)'))),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: maxA,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Up to (months)'),
                    onChanged: (_) => set(() {}),
                  ),
                ),
              ]),
              TextField(
                controller: ratio,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'Children per carer', helperText: 'Usual for this age: 1:${suggested()}'),
              ),
              TextField(controller: cap, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Capacity (optional)')),
              if (r != null) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('In use'), value: active, onChanged: (v) => set(() => active = v)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    final ratioN = int.tryParse(ratio.text) ?? suggested();
    if (ratioN > suggested() && mounted) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Ratio is looser than usual'),
          content: Text('1:$ratioN is more children per carer than the usual 1:${suggested()} for this age. Check your licence conditions.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Change it')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Keep')),
          ],
        ),
      );
      if (sure != true) return;
    }
    final data = {
      'name': name.text.trim(),
      'min_age_months': int.tryParse(minA.text) ?? 0,
      'max_age_months': int.tryParse(maxA.text) ?? 48,
      'ratio_children': ratioN,
      'capacity': int.tryParse(cap.text),
      'active': active,
    };
    await _run(() async {
      if (r == null) {
        await _s.db.from('kids_rooms').insert({...data, 'tenant_id': _s.tenantId, 'outlet_id': _s.outlet?.id});
      } else {
        await _s.db.from('kids_rooms').update(data).eq('id', r['id']);
      }
    }, 'Room saved');
  }

  Future<void> _editPlan([Map<String, dynamic>? p]) async {
    final name = TextEditingController(text: (p?['name'] ?? '') as String);
    final fee = TextEditingController(text: p?['monthly_fee']?.toString() ?? '');
    final reg = TextEditingController(text: '${p?['registration_fee'] ?? 0}');
    final dep = TextEditingController(text: '${p?['deposit'] ?? 0}');
    final sib = TextEditingController(text: '${p?['sibling_discount_pct'] ?? 0}');
    bool active = (p?['active'] ?? true) as bool;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(p == null ? 'Add fee plan' : 'Edit fee plan'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (e.g. Full day, Half day)')),
              TextField(controller: fee, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Monthly fee (${_s.currency})')),
              TextField(controller: reg, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Registration fee (once)')),
              TextField(controller: dep, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Deposit (once, refundable)')),
              TextField(controller: sib, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Sibling discount % (2nd child onwards)')),
              if (p != null) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('In use'), value: active, onChanged: (v) => set(() => active = v)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty || double.tryParse(fee.text) == null) return;
    final data = {
      'name': name.text.trim(),
      'monthly_fee': double.parse(fee.text),
      'registration_fee': double.tryParse(reg.text) ?? 0,
      'deposit': double.tryParse(dep.text) ?? 0,
      'sibling_discount_pct': double.tryParse(sib.text) ?? 0,
      'active': active,
    };
    await _run(() async {
      if (p == null) {
        await _s.db.from('kids_fee_plans').insert({...data, 'tenant_id': _s.tenantId});
      } else {
        await _s.db.from('kids_fee_plans').update(data).eq('id', p['id']);
      }
    }, 'Fee plan saved');
  }

  Future<void> _extraCharge() async {
    final kids = await _s.db.from('children').select('id, full_name').eq('tenant_id', _s.tenantId!).eq('status', 'enrolled').order('full_name');
    if (!mounted) return;
    String? child;
    final desc = TextEditingController();
    final amt = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Extra charge'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: child,
              decoration: const InputDecoration(labelText: 'Child'),
              items: [for (final k in kids) DropdownMenuItem(value: k['id'] as String, child: Text(k['full_name'] as String))],
              onChanged: (v) => set(() => child = v),
            ),
            TextField(controller: desc, decoration: const InputDecoration(labelText: 'What (field trip, uniform, books…)')),
            TextField(controller: amt, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Amount (${_s.currency})')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    final a = double.tryParse(amt.text);
    if (ok != true || child == null || desc.text.trim().isEmpty || a == null || a <= 0) return;
    await _run(
        () async => _s.db.from('kids_extra_charges').insert({'tenant_id': _s.tenantId, 'child_id': child, 'description': desc.text.trim(), 'amount': a}),
        'Added — it goes on the next invoice');
  }

  Future<void> _generate(bool issue) async {
    final label = DateFormat('MMMM yyyy').format(_month);
    final sure = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${issue ? 'Create and issue' : 'Create draft'} invoices for $label?'),
        content: Text('One invoice per paying guardian: monthly fees (sibling discount on younger children), first-time registration '
            'fee and deposit, unbilled late pick-up fees and extra charges. Families already invoiced for $label are skipped.'
            '${issue ? '\n\nIssued invoices are numbered and posted to your accounts, and parents can see them in the app.' : ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(issue ? 'Create & issue' : 'Create drafts')),
        ],
      ),
    );
    if (sure != true) return;
    setState(() => _billing = true);
    try {
      final r = await _s.db.rpc('generate_kids_invoices', params: {'p_tenant': _s.tenantId, 'p_month': Kids.isoDate(_month), 'p_issue': issue}) as Map;
      _snack('${r['created']} invoice(s) created${issue ? ', ${r['issued']} issued' : ''}, total ${_s.currency} ${(r['total'] as num).toStringAsFixed(2)}'
          '${(r['skipped_existing'] as int) > 0 ? ' · ${r['skipped_existing']} already done' : ''}');
    } catch (e) {
      _snack(Kids.errorText(e));
    }
    if (mounted) setState(() => _billing = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    final st = _settings;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        if (_manage) ...[
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Centre settings'),
            subtitle: Text(st == null
                ? 'Not set'
                : '${(st['centre_type'] as String).toUpperCase()} · ${_t(st['opening_time'])}–${_t(st['closing_time'])}'
                    '${(st['late_fee'] as num) > 0 ? ' · late ${_s.currency} ${st['late_fee']}/${st['late_block_minutes']} min' : ''}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editSettings,
          ),
          const Divider(),
          ListTile(
            title: Text('Rooms & ratios', style: Theme.of(context).textTheme.titleMedium),
            trailing: TextButton.icon(onPressed: () => _editRoom(), icon: const Icon(Icons.add), label: const Text('Room')),
          ),
          if (_rooms.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('Typical TASKA rooms: Babies 0–12 months (1:3), Toddlers 1–3 years (1:5), 3–4 years (1:10).'),
            ),
          for (final r in _rooms)
            ListTile(
              title: Text(r['name'] as String),
              subtitle: Text('${r['min_age_months']}–${r['max_age_months']} months · 1 carer : ${r['ratio_children']} children'
                  '${r['capacity'] != null ? ' · max ${r['capacity']}' : ''}${r['active'] == true ? '' : ' · not in use'}'),
              onTap: () => _editRoom(r),
            ),
          const Divider(),
          ListTile(
            title: Text('Fee plans', style: Theme.of(context).textTheme.titleMedium),
            trailing: TextButton.icon(onPressed: () => _editPlan(), icon: const Icon(Icons.add), label: const Text('Plan')),
          ),
          for (final p in _plans)
            ListTile(
              title: Text(p['name'] as String),
              subtitle: Text('${_s.currency} ${(p['monthly_fee'] as num).toStringAsFixed(2)}/month'
                  '${(p['registration_fee'] as num) > 0 ? ' · registration ${(p['registration_fee'] as num).toStringAsFixed(2)}' : ''}'
                  '${(p['deposit'] as num) > 0 ? ' · deposit ${(p['deposit'] as num).toStringAsFixed(2)}' : ''}'
                  '${(p['sibling_discount_pct'] as num) > 0 ? ' · siblings −${p['sibling_discount_pct']}%' : ''}'
                  '${p['active'] == true ? '' : ' · not in use'}'),
              onTap: () => _editPlan(p),
            ),
          const Divider(),
        ],
        if (_s.can('kids.billing')) ...[
          ListTile(title: Text('Monthly fees', style: Theme.of(context).textTheme.titleMedium)),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1))),
            Text(DateFormat('MMMM yyyy').format(_month), style: const TextStyle(fontWeight: FontWeight.w600)),
            IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1))),
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(child: OutlinedButton(onPressed: _billing ? null : () => _generate(false), child: const Text('Create drafts'))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton(onPressed: _billing ? null : () => _generate(true), child: const Text('Create & issue'))),
            ]),
          ),
          if (_manage)
            ListTile(
              leading: const Icon(Icons.add_card_outlined),
              title: const Text('Add an extra charge'),
              subtitle: const Text('Field trips, uniforms, books — billed on the next invoice'),
              onTap: _extraCharge,
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Invoices appear under Invoices (record payments there). Fee lines use the "exempt" tax code — '
                'check with your tax adviser whether any of your services are taxable.', style: TextStyle(fontSize: 12)),
          ),
        ],
      ]),
    );
  }
}
