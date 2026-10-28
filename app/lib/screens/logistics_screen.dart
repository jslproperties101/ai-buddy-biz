import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';
import '../widgets/port_picker.dart';
import 'shipment_screen.dart';

const modeLabels = {
  'sea_fcl': 'Sea FCL',
  'sea_lcl': 'Sea LCL',
  'air': 'Air',
  'road': 'Road',
  'rail': 'Rail',
  'courier': 'Courier',
};
const modeIcons = {
  'sea_fcl': Icons.directions_boat_outlined,
  'sea_lcl': Icons.directions_boat_outlined,
  'air': Icons.flight_outlined,
  'road': Icons.local_shipping_outlined,
  'rail': Icons.train_outlined,
  'courier': Icons.inventory_outlined,
};
const containerTypes = ['20GP', '40GP', '40HC', '45HC', '20RF', '40RF', '20OT', '40OT', '20FR', '40FR', '20TK'];

String statusLabel(String s) => s.replaceAll('_', ' ').replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase());

class LogisticsScreen extends StatelessWidget {
  const LogisticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    final tabs = <(String, Widget)>[
      ('Shipments', const _ShipmentsTab()),
      if (s.can('log.shipment.manage')) ('Quote', const QuoteTab()),
      if (s.can('log.rate.manage')) ('Rates', const _RatesTab()),
      ('Fleet', const _FleetTab()),
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

// ---------------- Shipments ----------------

class _ShipmentsTab extends StatefulWidget {
  const _ShipmentsTab();
  @override
  State<_ShipmentsTab> createState() => _ShipmentsTabState();
}

class _ShipmentsTabState extends State<_ShipmentsTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _rows = [];
  String _filter = 'active';
  String _q = '';
  bool _loading = true;
  String? _error;
  Session get _s => Session.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      var q = _s.db.from('shipment_list').select().eq('tenant_id', _s.tenantId!);
      q = switch (_filter) {
        'active' => q.not('status', 'in', '(draft,quoted,delivered,cancelled)'),
        'draft' => q.inFilter('status', ['draft', 'quoted']),
        'late' => q.eq('late', true),
        'delivered' => q.eq('status', 'delivered'),
        _ => q,
      };
      final t = _q.replaceAll(RegExp(r'[,()%]'), ' ').trim();
      if (t.isNotEmpty) {
        q = q.or('ref.ilike.%$t%,master_no.ilike.%$t%,house_no.ilike.%$t%,booking_no.ilike.%$t%,'
            'containers.ilike.%$t%,customer_name.ilike.%$t%,consignee_name.ilike.%$t%');
      }
      _rows = List<Map<String, dynamic>>.from(await q.order('created_at', ascending: false).limit(200));
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Offline. Shipments need a connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open([String? id]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShipmentScreen(shipmentId: id)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final fmt = DateFormat('d MMM');
    final err = Theme.of(context).colorScheme.error;
    return Scaffold(
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Ref, AWB, B/L, container, customer',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) {
              _q = v;
              _load();
            },
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(children: [
            for (final f in const [('active', 'In progress'), ('late', 'Late'), ('draft', 'Drafts & quotes'), ('delivered', 'Delivered'), ('all', 'All')])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(f.$2),
                  selected: _filter == f.$1,
                  onSelected: (_) {
                    _filter = f.$1;
                    _load();
                  },
                ),
              ),
          ]),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _rows.isEmpty
                      ? ListView(children: const [SizedBox(height: 80), Center(child: Text('No shipments here'))])
                      : ListView.builder(
                          itemCount: _rows.length,
                          itemBuilder: (_, i) {
                            final r = _rows[i];
                            final late = r['late'] == true;
                            final eta = r['eta'] == null ? null : DateTime.parse(r['eta'] as String).toLocal();
                            return ListTile(
                              leading: Icon(modeIcons[r['mode']]),
                              title: Text('${r['ref']} · ${r['origin_code'] ?? '?'} → ${r['dest_code'] ?? '?'}'),
                              subtitle: Text([
                                r['customer_name'] ?? r['consignee_name'],
                                r['house_no'] ?? r['master_no'] ?? r['containers'],
                                if (eta != null) 'ETA ${fmt.format(eta)}',
                              ].whereType<String>().join(' · ')),
                              trailing: Text(late ? 'LATE' : statusLabel(r['status'] as String),
                                  style: TextStyle(fontSize: 12, color: late ? err : null)),
                              onTap: () => _open(r['id'] as String),
                            );
                          },
                        ),
                ),
        ),
      ]),
      floatingActionButton: _s.can('log.shipment.manage')
          ? FloatingActionButton.extended(heroTag: null, onPressed: () => _open(), icon: const Icon(Icons.add), label: const Text('Shipment'))
          : null,
    );
  }
}

// ---------------- Quote & landed cost ----------------

class QuoteTab extends StatefulWidget {
  const QuoteTab({super.key});
  @override
  State<QuoteTab> createState() => _QuoteTabState();
}

class _QuoteTabState extends State<QuoteTab> with AutomaticKeepAliveClientMixin {
  String _mode = 'air';
  Map<String, dynamic>? _origin;
  Map<String, dynamic>? _dest;
  final _kg = TextEditingController();
  final _cbm = TextEditingController();
  final Map<String, int> _containers = {'40HC': 1};
  List<Map<String, dynamic>> _options = [];
  bool _searched = false;

  // landed cost
  final _hs = TextEditingController();
  final _value = TextEditingController();
  final _freight = TextEditingController();
  final _ins = TextEditingController(text: '0');
  final _originCountry = TextEditingController();
  final _manualRate = TextEditingController();
  Map<String, dynamic>? _landed;

  Session get _s => Session.instance;
  NumberFormat _m(String cur) => NumberFormat.currency(symbol: '$cur ');

  @override
  bool get wantKeepAlive => true;

  String? get _portKind => _mode == 'air' ? 'air' : (_mode.startsWith('sea') ? 'sea' : null);

  Future<void> _quote() async {
    if (_origin == null || _dest == null) {
      _snack('Choose origin and destination');
      return;
    }
    try {
      final r = await _s.db.rpc('freight_quote', params: {
        'p_tenant': _s.tenantId,
        'p_mode': _mode,
        'p_origin': _origin!['id'],
        'p_dest': _dest!['id'],
        'p_gross_kg': double.tryParse(_kg.text) ?? 0,
        'p_cbm': double.tryParse(_cbm.text) ?? 0,
        'p_containers': _mode == 'sea_fcl' ? _containers : <String, int>{},
      }) as List;
      setState(() {
        _options = List<Map<String, dynamic>>.from(r);
        _searched = true;
      });
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _calcLanded() async {
    if (_dest == null) {
      _snack('Choose the destination first');
      return;
    }
    final v = double.tryParse(_value.text);
    if (v == null) {
      _snack('Enter the goods value');
      return;
    }
    try {
      final r = await _s.db.rpc('landed_cost', params: {
        'p_tenant': _s.tenantId,
        'p_dest_country': _dest!['country_code'],
        'p_hs_code': _hs.text.trim(),
        'p_origin_country': _originCountry.text.trim().isEmpty ? _origin?['country_code'] : _originCountry.text.trim().toUpperCase(),
        'p_goods_value': v,
        'p_freight': double.tryParse(_freight.text) ?? 0,
        'p_insurance': double.tryParse(_ins.text) ?? 0,
        'p_manual_duty_rate': _manualRate.text.trim().isEmpty ? null : (double.tryParse(_manualRate.text) ?? 0) / 100,
      });
      setState(() => _landed = Map<String, dynamic>.from(r as Map));
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _book(Map<String, dynamic> o) async {
    try {
      final row = await _s.db
          .from('shipments')
          .insert({
            'tenant_id': _s.tenantId,
            'mode': _mode,
            'status': 'quoted',
            'origin_port_id': _origin!['id'],
            'dest_port_id': _dest!['id'],
            'carrier_id': o['carrier_id'],
          })
          .select('id')
          .single();
      final id = row['id'] as String;
      await _s.db.from('shipment_charges').insert([
        {
          'tenant_id': _s.tenantId,
          'shipment_id': id,
          'side': 'revenue',
          'code': 'freight',
          'description': '${modeLabels[_mode]} freight ${_origin!['code']}–${_dest!['code']} (${o['basis']})',
          'unit_price': o['sell'],
          'currency': o['currency'],
        },
        {
          'tenant_id': _s.tenantId,
          'shipment_id': id,
          'side': 'cost',
          'code': 'freight',
          'description': 'Freight — ${o['carrier_name'] ?? 'carrier'}',
          'unit_price': o['buy'],
          'currency': o['currency'],
          'supplier_id': o['carrier_id'],
        },
      ]);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShipmentScreen(shipmentId: id)));
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Freight quote', style: t.titleMedium),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final m in modeLabels.entries)
          ChoiceChip(
            avatar: Icon(modeIcons[m.key], size: 18),
            label: Text(m.value),
            selected: _mode == m.key,
            onSelected: (_) => setState(() {
              final changedKind = (_mode == 'air') != (m.key == 'air');
              _mode = m.key;
              if (changedKind) {
                _origin = null;
                _dest = null;
              }
              _options = [];
              _searched = false;
            }),
          ),
      ]),
      Row(children: [
        Expanded(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('From'),
            subtitle: Text(portLabel(_origin)),
            onTap: () async {
              final p = await PortPicker.show(context, kind: _portKind);
              if (p != null) setState(() => _origin = p);
            },
          ),
        ),
        const Icon(Icons.arrow_forward),
        const SizedBox(width: 8),
        Expanded(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('To'),
            subtitle: Text(portLabel(_dest)),
            onTap: () async {
              final p = await PortPicker.show(context, kind: _portKind);
              if (p != null) setState(() => _dest = p);
            },
          ),
        ),
      ]),
      if (_mode == 'sea_fcl')
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final ct in const ['20GP', '40GP', '40HC', '20RF', '40RF'])
            InputChip(
              label: Text('$ct × ${_containers[ct] ?? 0}'),
              selected: (_containers[ct] ?? 0) > 0,
              onPressed: () => setState(() => _containers[ct] = (_containers[ct] ?? 0) + 1),
              onDeleted: (_containers[ct] ?? 0) > 0 ? () => setState(() => _containers[ct] = (_containers[ct] ?? 0) - 1) : null,
            ),
        ])
      else
        Row(children: [
          Expanded(child: TextField(controller: _kg, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Gross weight (kg)'))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: _cbm, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Volume (cbm)'))),
        ]),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: _quote, icon: const Icon(Icons.request_quote_outlined), label: const Text('Get prices')),
      if (_searched && _options.isEmpty)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('No valid rate cards for this lane. Add rates in the Rates tab, or price it by hand on a shipment.'),
        ),
      for (final o in _options)
        Card(
          child: ListTile(
            title: Text('${o['carrier_name'] ?? 'Any carrier'} · ${_m(o['currency'] as String).format(o['sell'])}'),
            subtitle: Text([
              o['basis'],
              'cost ${_m(o['currency'] as String).format(o['buy'])}',
              'margin ${_m(o['currency'] as String).format(o['margin'])}',
              if (o['transit_days'] != null) '${o['transit_days']} days',
              'valid to ${o['valid_to']}',
            ].join(' · ')),
            trailing: TextButton(onPressed: () => _book(o), child: const Text('Use')),
          ),
        ),
      const Divider(height: 40),
      Text('Duties & taxes (landed cost)', style: t.titleMedium),
      Text(_dest == null ? 'Choose a destination above' : 'Into ${_dest!['country_code']}', style: t.bodySmall),
      Row(children: [
        Expanded(child: TextField(controller: _hs, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'HS code'))),
        const SizedBox(width: 12),
        Expanded(child: TextField(controller: _originCountry, maxLength: 2, decoration: const InputDecoration(labelText: 'Made in (country)', counterText: ''))),
      ]),
      Row(children: [
        Expanded(child: TextField(controller: _value, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Goods value'))),
        const SizedBox(width: 12),
        Expanded(child: TextField(controller: _freight, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Freight'))),
        const SizedBox(width: 12),
        Expanded(child: TextField(controller: _ins, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Insurance'))),
      ]),
      TextField(
        controller: _manualRate,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Duty rate % (optional, if you know it)'),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(onPressed: _calcLanded, icon: const Icon(Icons.calculate_outlined), label: const Text('Calculate')),
      if (_landed != null) _landedCard(_landed!),
      const SizedBox(height: 40),
    ]);
  }

  Widget _landedCard(Map<String, dynamic> r) {
    String n(dynamic v) => NumberFormat('#,##0.00').format((v as num).toDouble());
    String pct(dynamic v) => '${((v as num) * 100).toStringAsFixed(2)}%';
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(r['currency_note'] as String, style: Theme.of(context).textTheme.bodySmall),
          _kv('Customs value (${r['basis']})', n(r['customs_value'])),
          _kv('Duty ${r['duty_found'] == true ? pct(r['duty_rate']) : '(rate unknown)'}', n(r['duty'])),
          _kv('${r['tax_name']} ${pct(r['tax_rate'])}', n(r['import_tax'])),
          if ((r['flat_charge'] as num) > 0) _kv('Possible flat charge', n(r['flat_charge'])),
          const Divider(),
          _kv('Duties & taxes', n(r['total_taxes']), bold: true),
          _kv('Landed cost', n(r['landed_cost']), bold: true),
          for (final note in (r['notes'] as List? ?? []))
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $note', style: const TextStyle(fontSize: 12))),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Estimate only. Confirm the HS code and rates with your customs broker.', style: TextStyle(fontSize: 11)),
          ),
        ]),
      ),
    );
  }

  Widget _kv(String a, String b, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(child: Text(a, style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null)),
          Text(b, style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null),
        ]),
      );
}

// ---------------- Rate cards ----------------

class _RatesTab extends StatefulWidget {
  const _RatesTab();
  @override
  State<_RatesTab> createState() => _RatesTabState();
}

class _RatesTabState extends State<_RatesTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _rows = [];
  bool _showExpired = false;
  bool _loading = true;
  Session get _s => Session.instance;

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
          .from('freight_rates')
          .select('*, carrier:suppliers(name), origin:ports!freight_rates_origin_port_id_fkey(code), dest:ports!freight_rates_dest_port_id_fkey(code)')
          .eq('tenant_id', _s.tenantId!);
      if (!_showExpired) q = q.gte('valid_to', DateFormat('yyyy-MM-dd').format(DateTime.now()));
      _rows = List<Map<String, dynamic>>.from(await q.order('valid_to').limit(300));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load rates: $e')));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit([Map<String, dynamic>? r]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RateForm(rate: r),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final soon = DateTime.now().add(const Duration(days: 7));
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(children: [
                SwitchListTile(
                  title: const Text('Show expired rates'),
                  value: _showExpired,
                  onChanged: (v) {
                    _showExpired = v;
                    _load();
                  },
                ),
                if (_rows.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No rate cards yet'))),
                for (final r in _rows)
                  Builder(builder: (_) {
                    final to = DateTime.parse(r['valid_to'] as String);
                    final expiring = to.isBefore(soon);
                    return ListTile(
                      leading: Icon(modeIcons[r['mode']]),
                      title: Text('${r['origin']?['code']} → ${r['dest']?['code']} · ${r['carrier']?['name'] ?? 'Any carrier'}'),
                      subtitle: Text([
                        modeLabels[r['mode']],
                        if (r['container_type'] != null) r['container_type'],
                        'buy ${r['buy_rate']} / sell ${r['sell_rate']} ${r['currency']} per ${r['unit']}',
                        if ((r['min_charge'] as num) > 0) 'min ${r['min_charge']}',
                      ].join(' · ')),
                      trailing: Text('to ${r['valid_to']}',
                          style: TextStyle(fontSize: 12, color: expiring ? Theme.of(context).colorScheme.error : null)),
                      onTap: () => _edit(r),
                    );
                  }),
                const SizedBox(height: 80),
              ]),
            ),
      floatingActionButton: FloatingActionButton(heroTag: null, onPressed: () => _edit(), child: const Icon(Icons.add)),
    );
  }
}

class _RateForm extends StatefulWidget {
  final Map<String, dynamic>? rate;
  const _RateForm({this.rate});
  @override
  State<_RateForm> createState() => _RateFormState();
}

class _RateFormState extends State<_RateForm> {
  late String _mode = (widget.rate?['mode'] ?? 'air') as String;
  late String? _ct = widget.rate?['container_type'] as String? ?? '40HC';
  late String _unit = (widget.rate?['unit'] ?? 'kg') as String;
  Map<String, dynamic>? _origin, _dest, _carrier;
  late final _buy = TextEditingController(text: widget.rate?['buy_rate']?.toString() ?? '');
  late final _sell = TextEditingController(text: widget.rate?['sell_rate']?.toString() ?? '');
  late final _min = TextEditingController(text: widget.rate?['min_charge']?.toString() ?? '0');
  late final _cur = TextEditingController(text: (widget.rate?['currency'] ?? Session.instance.currency) as String);
  late final _days = TextEditingController(text: widget.rate?['transit_days']?.toString() ?? '');
  late DateTime _to = widget.rate == null ? DateTime.now().add(const Duration(days: 30)) : DateTime.parse(widget.rate!['valid_to'] as String);
  List<Map<String, dynamic>> _carriers = [];
  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _carriers = List<Map<String, dynamic>>.from(await _s.db
        .from('suppliers')
        .select('id, name, category')
        .eq('tenant_id', _s.tenantId!)
        .inFilter('category', ['carrier_sea', 'carrier_air', 'trucking', 'forwarder', 'agent'])
        .order('name'));
    final r = widget.rate;
    if (r != null) {
      final ports = await _s.db.from('ports').select('id, code, name, country_code, kind').inFilter('id', [r['origin_port_id'], r['dest_port_id']]);
      for (final p in ports) {
        if (p['id'] == r['origin_port_id']) _origin = p;
        if (p['id'] == r['dest_port_id']) _dest = p;
      }
      _carrier = _carriers.where((c) => c['id'] == r['carrier_id']).firstOrNull;
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    if (_origin == null || _dest == null || double.tryParse(_buy.text) == null || double.tryParse(_sell.text) == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fill in lane, buy and sell')));
      return;
    }
    final data = {
      'tenant_id': _s.tenantId,
      'carrier_id': _carrier?['id'],
      'mode': _mode,
      'origin_port_id': _origin!['id'],
      'dest_port_id': _dest!['id'],
      'container_type': _mode == 'sea_fcl' ? _ct : null,
      'unit': _mode == 'sea_fcl' ? 'container' : _unit,
      'min_charge': double.tryParse(_min.text) ?? 0,
      'buy_rate': double.parse(_buy.text),
      'sell_rate': double.parse(_sell.text),
      'currency': _cur.text.trim().toUpperCase(),
      'transit_days': int.tryParse(_days.text),
      'valid_to': DateFormat('yyyy-MM-dd').format(_to),
    };
    try {
      if (widget.rate == null) {
        await _s.db.from('freight_rates').insert(data);
      } else {
        await _s.db.from('freight_rates').update(data).eq('id', widget.rate!['id']);
      }
      if (mounted) Navigator.pop(context, true);
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final kind = _mode == 'air' ? 'air' : (_mode.startsWith('sea') ? 'sea' : null);
    final units = _mode == 'sea_lcl' ? const ['w/m', 'shipment'] : const ['kg', 'shipment'];
    if (_mode != 'sea_fcl' && !units.contains(_unit)) _unit = units.first;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.rate == null ? 'New rate' : 'Edit rate', style: Theme.of(context).textTheme.titleLarge),
            Wrap(spacing: 6, children: [
              for (final m in modeLabels.entries)
                ChoiceChip(label: Text(m.value), selected: _mode == m.key, onSelected: (_) => setState(() => _mode = m.key)),
            ]),
            DropdownButtonFormField<String?>(
              value: _carrier?['id'] as String?,
              decoration: const InputDecoration(labelText: 'Carrier'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Any / not set')),
                for (final c in _carriers) DropdownMenuItem<String?>(value: c['id'] as String, child: Text(c['name'] as String)),
              ],
              onChanged: (v) => setState(() => _carrier = _carriers.where((c) => c['id'] == v).firstOrNull),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('From'),
              subtitle: Text(portLabel(_origin)),
              onTap: () async {
                final p = await PortPicker.show(context, kind: kind);
                if (p != null) setState(() => _origin = p);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('To'),
              subtitle: Text(portLabel(_dest)),
              onTap: () async {
                final p = await PortPicker.show(context, kind: kind);
                if (p != null) setState(() => _dest = p);
              },
            ),
            if (_mode == 'sea_fcl')
              DropdownButtonFormField<String>(
                value: _ct,
                decoration: const InputDecoration(labelText: 'Container'),
                items: [for (final c in containerTypes) DropdownMenuItem(value: c, child: Text(c))],
                onChanged: (v) => setState(() => _ct = v),
              )
            else
              DropdownButtonFormField<String>(
                value: _unit,
                decoration: const InputDecoration(labelText: 'Priced per'),
                items: [for (final u in units) DropdownMenuItem(value: u, child: Text(u == 'w/m' ? 'W/M (revenue ton)' : u))],
                onChanged: (v) => setState(() => _unit = v!),
              ),
            Row(children: [
              Expanded(child: TextField(controller: _buy, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Buy (cost)'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _sell, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Sell'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _cur, decoration: const InputDecoration(labelText: 'Currency'))),
            ]),
            Row(children: [
              if (_mode != 'sea_fcl')
                Expanded(child: TextField(controller: _min, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Minimum (sell)'))),
              if (_mode != 'sea_fcl') const SizedBox(width: 12),
              Expanded(child: TextField(controller: _days, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Transit days'))),
            ]),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Valid until'),
              subtitle: Text(DateFormat('d MMM yyyy').format(_to)),
              onTap: () async {
                final d = await showDatePicker(context: context, initialDate: _to, firstDate: DateTime.now().subtract(const Duration(days: 365)), lastDate: DateTime.now().add(const Duration(days: 730)));
                if (d != null) setState(() => _to = d);
              },
            ),
            FilledButton(onPressed: _save, child: const Text('Save')),
            if (widget.rate != null)
              TextButton(
                onPressed: () async {
                  await _s.db.from('freight_rates').delete().eq('id', widget.rate!['id']);
                  if (context.mounted) Navigator.pop(context, true);
                },
                child: const Text('Delete'),
              ),
          ]),
        ),
      ),
    );
  }
}

// ---------------- Fleet: vessels & voyages ----------------

class _FleetTab extends StatefulWidget {
  const _FleetTab();
  @override
  State<_FleetTab> createState() => _FleetTabState();
}

class _FleetTabState extends State<_FleetTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _voyages = [];
  List<Map<String, dynamic>> _vessels = [];
  bool _loading = true;
  Session get _s => Session.instance;
  bool get _canEdit => _s.can('log.fleet.manage');

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _vessels = List<Map<String, dynamic>>.from(await _s.db.from('vessels').select().eq('tenant_id', _s.tenantId!).order('name'));
      _voyages = List<Map<String, dynamic>>.from(await _s.db
          .from('voyages')
          .select('*, vessel:vessels(name), pol:ports!voyages_pol_id_fkey(code), pod:ports!voyages_pod_id_fkey(code)')
          .eq('tenant_id', _s.tenantId!)
          .neq('status', 'cancelled')
          .order('etd', ascending: false)
          .limit(100));
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addVessel() async {
    final name = TextEditingController();
    final imo = TextEditingController();
    final mmsi = TextEditingController();
    final flag = TextEditingController();
    final teu = TextEditingController();
    var type = 'container';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Add vessel'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Vessel name *')),
              TextField(controller: imo, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'IMO number (7 digits)')),
              TextField(controller: mmsi, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'MMSI (9 digits)')),
              TextField(controller: flag, maxLength: 2, decoration: const InputDecoration(labelText: 'Flag (country code)', counterText: '')),
              DropdownButtonFormField<String>(
                value: type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [for (final t in const ['container', 'feeder', 'bulk', 'tanker', 'general', 'roro', 'reefer', 'barge', 'other']) DropdownMenuItem(value: t, child: Text(t))],
                onChanged: (v) => set(() => type = v!),
              ),
              TextField(controller: teu, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'TEU capacity')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    try {
      await _s.db.from('vessels').insert({
        'tenant_id': _s.tenantId,
        'name': name.text.trim(),
        'imo': imo.text.trim().isEmpty ? null : imo.text.trim(),
        'mmsi': mmsi.text.trim().isEmpty ? null : mmsi.text.trim(),
        'flag': flag.text.trim().isEmpty ? null : flag.text.trim().toUpperCase(),
        'vessel_type': type,
        'teu_capacity': int.tryParse(teu.text),
      });
      _load();
    } on PostgrestException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.message.contains('imo') ? 'That IMO number is not valid (check digit)' : e.message)));
      }
    }
  }

  Future<void> _addVoyage() async {
    if (_vessels.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add a vessel first')));
      return;
    }
    String vessel = _vessels.first['id'] as String;
    final no = TextEditingController();
    final service = TextEditingController();
    Map<String, dynamic>? pol, pod;
    DateTime? etd, eta;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Add voyage'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: vessel,
                decoration: const InputDecoration(labelText: 'Vessel'),
                items: [for (final v in _vessels) DropdownMenuItem(value: v['id'] as String, child: Text(v['name'] as String))],
                onChanged: (v) => set(() => vessel = v!),
              ),
              TextField(controller: no, decoration: const InputDecoration(labelText: 'Voyage no. *')),
              TextField(controller: service, decoration: const InputDecoration(labelText: 'Service / route')),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Port of loading'),
                subtitle: Text(portLabel(pol)),
                onTap: () async {
                  final p = await PortPicker.show(context, kind: 'sea');
                  if (p != null) set(() => pol = p);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Port of discharge'),
                subtitle: Text(portLabel(pod)),
                onTap: () async {
                  final p = await PortPicker.show(context, kind: 'sea');
                  if (p != null) set(() => pod = p);
                },
              ),
              for (final which in const ['ETD', 'ETA'])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(which),
                  subtitle: Text((which == 'ETD' ? etd : eta) == null ? '—' : DateFormat('d MMM yyyy').format((which == 'ETD' ? etd : eta)!)),
                  onTap: () async {
                    final d = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime.now().subtract(const Duration(days: 90)), lastDate: DateTime.now().add(const Duration(days: 365)));
                    if (d != null) set(() => which == 'ETD' ? etd = d : eta = d);
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
    if (ok != true || no.text.trim().isEmpty) return;
    try {
      await _s.db.from('voyages').insert({
        'tenant_id': _s.tenantId,
        'vessel_id': vessel,
        'voyage_no': no.text.trim().toUpperCase(),
        'service': service.text.trim().isEmpty ? null : service.text.trim(),
        'pol_id': pol?['id'],
        'pod_id': pod?['id'],
        'etd': etd?.toUtc().toIso8601String(),
        'eta': eta?.toUtc().toIso8601String(),
      });
      _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final fmt = DateFormat('d MMM');
    String d(dynamic v) => v == null ? '—' : fmt.format(DateTime.parse(v as String).toLocal());
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(children: [
                ListTile(title: Text('Voyages', style: Theme.of(context).textTheme.titleMedium)),
                if (_voyages.isEmpty) const ListTile(title: Text('No voyages yet')),
                for (final v in _voyages)
                  ListTile(
                    leading: const Icon(Icons.directions_boat_outlined),
                    title: Text('${v['vessel']?['name']} · ${v['voyage_no']}'),
                    subtitle: Text('${v['pol']?['code'] ?? '?'} → ${v['pod']?['code'] ?? '?'} · ETD ${d(v['etd'])} · ETA ${d(v['eta'])}'
                        '${v['service'] != null ? ' · ${v['service']}' : ''}'),
                    trailing: Text(v['status'] as String, style: const TextStyle(fontSize: 12)),
                    onTap: !_canEdit
                        ? null
                        : () async {
                            final st = await showModalBottomSheet<String>(
                              context: context,
                              builder: (_) => SafeArea(
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  for (final s in const ['scheduled', 'departed', 'arrived', 'cancelled'])
                                    ListTile(title: Text('Mark $s'), onTap: () => Navigator.pop(context, s)),
                                ]),
                              ),
                            );
                            if (st == null) return;
                            await _s.db.from('voyages').update({
                              'status': st,
                              if (st == 'departed') 'atd': DateTime.now().toUtc().toIso8601String(),
                              if (st == 'arrived') 'ata': DateTime.now().toUtc().toIso8601String(),
                            }).eq('id', v['id']);
                            _load();
                          },
                  ),
                ListTile(title: Text('Vessels', style: Theme.of(context).textTheme.titleMedium)),
                if (_vessels.isEmpty) const ListTile(title: Text('No vessels yet')),
                for (final v in _vessels)
                  ListTile(
                    leading: Icon(v['own'] == true ? Icons.star_outline : Icons.sailing_outlined),
                    title: Text(v['name'] as String),
                    subtitle: Text([
                      if (v['imo'] != null) 'IMO ${v['imo']}',
                      if (v['flag'] != null) 'flag ${v['flag']}',
                      v['vessel_type'],
                      if (v['teu_capacity'] != null) '${v['teu_capacity']} TEU',
                    ].join(' · ')),
                  ),
                const SizedBox(height: 100),
              ]),
            ),
      floatingActionButton: _canEdit
          ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
              FloatingActionButton.small(heroTag: 'vessel', onPressed: _addVessel, tooltip: 'Add vessel', child: const Icon(Icons.sailing_outlined)),
              const SizedBox(height: 8),
              FloatingActionButton.extended(heroTag: 'voyage', onPressed: _addVoyage, icon: const Icon(Icons.add), label: const Text('Voyage')),
            ])
          : null,
    );
  }
}
