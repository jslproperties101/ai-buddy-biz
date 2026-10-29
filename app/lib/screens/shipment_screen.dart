import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../services/printing_service.dart';
import '../services/session.dart';
import '../widgets/contact_picker.dart';
import '../widgets/port_picker.dart';
import '../widgets/timeline.dart';
import 'invoice_edit_screen.dart';
import 'logistics_screen.dart';

const _incoterms = ['EXW', 'FCA', 'FAS', 'FOB', 'CFR', 'CIF', 'CPT', 'CIP', 'DAP', 'DPU', 'DDP'];
const _eventCodes = {
  'booked': 'Booked',
  'picked_up': 'Picked up',
  'at_origin': 'At origin warehouse / terminal',
  'departed': 'Departed',
  'in_transit': 'In transit',
  'transshipment': 'Transshipment',
  'arrived': 'Arrived',
  'customs': 'With customs',
  'released': 'Released by customs',
  'out_for_delivery': 'Out for delivery',
  'delivered': 'Delivered',
  'exception': 'Problem / delay',
  'note': 'Note',
};
const _chargeCodes = {
  'freight': 'Freight',
  'fuel': 'Fuel surcharge',
  'thc': 'Terminal handling',
  'docs': 'Documentation',
  'customs_clearance': 'Customs clearance',
  'customs_duty': 'Customs duty (disbursement)',
  'import_tax': 'Import tax (disbursement)',
  'insurance': 'Insurance',
  'trucking': 'Trucking',
  'storage': 'Storage',
  'handling': 'Handling',
  'dg_surcharge': 'DG surcharge',
  'other': 'Other',
};

class ShipmentScreen extends StatefulWidget {
  final String? shipmentId;
  const ShipmentScreen({super.key, this.shipmentId});
  @override
  State<ShipmentScreen> createState() => _ShipmentScreenState();
}

class _ShipmentScreenState extends State<ShipmentScreen> {
  String? _id;
  Map<String, dynamic>? _sh; // shipment_list row
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _containers = [];
  List<Map<String, dynamic>> _events = [];
  List<Map<String, dynamic>> _charges = [];
  List<Map<String, dynamic>> _carriers = [];
  List<Map<String, dynamic>> _voyages = [];
  bool _loading = true;
  bool _busy = false;
  bool _editing = false;

  // form state
  String _mode = 'air';
  String _direction = 'export';
  String? _incoterm;
  Map<String, dynamic>? _customer, _shipper, _consignee, _origin, _dest;
  String? _carrierId, _voyageId, _customsStatus;
  DateTime? _etd, _eta;
  bool _dg = false;
  final _c = {
    for (final k in const ['flight_no', 'booking_no', 'master_no', 'house_no', 'cargo_description', 'un_number', 'dg_class',
      'temp_min_c', 'temp_max_c', 'pickup_address', 'delivery_address', 'customs_ref', 'notes'])
      k: TextEditingController()
  };

  AppSession get _s => AppSession.instance;
  bool get _canEdit => _s.can('log.shipment.manage');
  NumberFormat get _money => NumberFormat.currency(symbol: '${_s.currency} ');

  @override
  void initState() {
    super.initState();
    _id = widget.shipmentId;
    _editing = _id == null;
    _load();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _load() async {
    try {
      _carriers = List<Map<String, dynamic>>.from(await _s.db
          .from('suppliers')
          .select('id, name, category')
          .eq('tenant_id', _s.tenantId!)
          .order('name'));
      _voyages = List<Map<String, dynamic>>.from(await _s.db
          .from('voyages')
          .select('id, voyage_no, etd, eta, vessel:vessels(name)')
          .eq('tenant_id', _s.tenantId!)
          .neq('status', 'cancelled')
          .order('etd', ascending: false)
          .limit(50));
      if (_id != null) {
        final sh = await _s.db.from('shipment_list').select().eq('id', _id!).single();
        _sh = sh;
        _items = List<Map<String, dynamic>>.from(await _s.db.from('shipment_items').select().eq('shipment_id', _id!).order('sort_order'));
        _containers = List<Map<String, dynamic>>.from(await _s.db.from('shipment_containers').select().eq('shipment_id', _id!));
        _events = List<Map<String, dynamic>>.from(await _s.db.from('shipment_events').select().eq('shipment_id', _id!).order('at', ascending: false));
        if (_canEdit || _s.can('log.finance')) {
          _charges = List<Map<String, dynamic>>.from(
              await _s.db.from('shipment_charges').select('*, supplier:suppliers(name)').eq('shipment_id', _id!).order('created_at'));
        }
        _fill(sh);
      }
    } catch (e) {
      _snack('Could not load: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  void _fill(Map<String, dynamic> sh) {
    _mode = sh['mode'] as String;
    _direction = sh['direction'] as String;
    _incoterm = sh['incoterm'] as String?;
    _carrierId = sh['carrier_id'] as String?;
    _voyageId = sh['voyage_id'] as String?;
    _customsStatus = sh['customs_status'] as String;
    _etd = sh['etd'] == null ? null : DateTime.parse(sh['etd'] as String).toLocal();
    _eta = sh['eta'] == null ? null : DateTime.parse(sh['eta'] as String).toLocal();
    _dg = sh['dangerous_goods'] as bool;
    for (final e in _c.entries) {
      e.value.text = sh[e.key]?.toString() ?? '';
    }
    _customer = sh['customer_id'] == null ? null : {'id': sh['customer_id'], 'name': sh['customer_name']};
    _shipper = sh['shipper_id'] == null ? null : {'id': sh['shipper_id'], 'name': sh['shipper_name']};
    _consignee = sh['consignee_id'] == null ? null : {'id': sh['consignee_id'], 'name': sh['consignee_name']};
    _origin = sh['origin_port_id'] == null ? null : {'id': sh['origin_port_id'], 'code': sh['origin_code'], 'name': sh['origin_name'], 'country_code': sh['origin_country']};
    _dest = sh['dest_port_id'] == null ? null : {'id': sh['dest_port_id'], 'code': sh['dest_code'], 'name': sh['dest_name'], 'country_code': sh['dest_country']};
  }

  Future<void> _save() async {
    String? v(String k) => _c[k]!.text.trim().isEmpty ? null : _c[k]!.text.trim();
    final data = {
      'tenant_id': _s.tenantId,
      'mode': _mode,
      'direction': _direction,
      'incoterm': _incoterm,
      'customer_id': _customer?['id'],
      'shipper_id': _shipper?['id'],
      'consignee_id': _consignee?['id'],
      'carrier_id': _carrierId,
      'origin_port_id': _origin?['id'],
      'dest_port_id': _dest?['id'],
      'voyage_id': _mode.startsWith('sea') ? _voyageId : null,
      'flight_no': _mode == 'air' ? v('flight_no')?.toUpperCase() : null,
      'booking_no': v('booking_no'),
      'master_no': v('master_no'),
      'house_no': v('house_no'),
      'etd': _etd?.toUtc().toIso8601String(),
      'eta': _eta?.toUtc().toIso8601String(),
      'cargo_description': v('cargo_description'),
      'dangerous_goods': _dg,
      'un_number': _dg ? v('un_number')?.toUpperCase() : null,
      'dg_class': _dg ? v('dg_class') : null,
      'temp_min_c': double.tryParse(_c['temp_min_c']!.text),
      'temp_max_c': double.tryParse(_c['temp_max_c']!.text),
      'pickup_address': v('pickup_address'),
      'delivery_address': v('delivery_address'),
      'customs_status': _customsStatus ?? 'not_required',
      'customs_ref': v('customs_ref'),
      'notes': v('notes'),
    };
    setState(() => _busy = true);
    try {
      if (_id == null) {
        final r = await _s.db.from('shipments').insert(data).select('id').single();
        _id = r['id'] as String;
      } else {
        await _s.db.from('shipments').update(data).eq('id', _id!);
      }
      _editing = false;
      await _load();
    } on PostgrestException catch (e) {
      final m = e.message;
      _snack(m.contains('shipments_check1')
          ? 'Dangerous goods need a UN number'
          : m.contains('shipments_check')
              ? 'ETA must be after ETD'
              : m.contains('un_number')
                  ? 'UN number looks like UN1263'
                  : m);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- items ----------
  Future<void> _editItem([Map<String, dynamic>? it]) async {
    final f = {
      for (final k in const ['description', 'hs_code', 'origin_country', 'packages', 'length_cm', 'width_cm', 'height_cm', 'weight_kg', 'units', 'unit_value'])
        k: TextEditingController(text: it?[k]?.toString() ?? (k == 'packages' ? '1' : ''))
    };
    var pkg = (it?['package_type'] ?? 'carton') as String;
    const labels = {
      'description': 'Description *',
      'hs_code': 'HS code',
      'origin_country': 'Made in (country code)',
      'packages': 'Packages *',
      'length_cm': 'L cm',
      'width_cm': 'W cm',
      'height_cm': 'H cm',
      'weight_kg': 'Weight per package (kg)',
      'units': 'Pieces inside (total)',
      'unit_value': 'Value per piece',
    };
    Widget tf(String k, {bool num = false}) => TextField(
          controller: f[k],
          keyboardType: num ? const TextInputType.numberWithOptions(decimal: true) : null,
          decoration: InputDecoration(labelText: labels[k], isDense: true),
        );
    final res = await showDialog<String>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(it == null ? 'Add cargo' : 'Edit cargo'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              tf('description'),
              Row(children: [Expanded(child: tf('hs_code', num: true)), const SizedBox(width: 8), Expanded(child: tf('origin_country'))]),
              Row(children: [
                Expanded(child: tf('packages', num: true)),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: pkg,
                    isDense: true,
                    decoration: const InputDecoration(labelText: 'Type'),
                    items: [for (final p in const ['carton', 'pallet', 'crate', 'drum', 'bag', 'roll', 'bundle', 'envelope', 'piece', 'other']) DropdownMenuItem(value: p, child: Text(p))],
                    onChanged: (v) => set(() => pkg = v!),
                  ),
                ),
              ]),
              Row(children: [
                Expanded(child: tf('length_cm', num: true)),
                const SizedBox(width: 8),
                Expanded(child: tf('width_cm', num: true)),
                const SizedBox(width: 8),
                Expanded(child: tf('height_cm', num: true)),
              ]),
              tf('weight_kg', num: true),
              Row(children: [Expanded(child: tf('units', num: true)), const SizedBox(width: 8), Expanded(child: tf('unit_value', num: true))]),
            ]),
          ),
          actions: [
            if (it != null) TextButton(onPressed: () => Navigator.pop(context, 'delete'), child: const Text('Delete')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (res == null) return;
    try {
      if (res == 'delete') {
        await _s.db.from('shipment_items').delete().eq('id', it!['id']);
      } else {
        if (f['description']!.text.trim().isEmpty || (int.tryParse(f['packages']!.text) ?? 0) <= 0) {
          _snack('Description and number of packages are required');
          return;
        }
        final units = int.tryParse(f['units']!.text);
        final unitValue = double.tryParse(f['unit_value']!.text);
        final data = {
          'tenant_id': _s.tenantId,
          'shipment_id': _id,
          'description': f['description']!.text.trim(),
          'hs_code': f['hs_code']!.text.replaceAll(RegExp(r'[^0-9]'), '').isEmpty ? null : f['hs_code']!.text.replaceAll(RegExp(r'[^0-9]'), ''),
          'origin_country': f['origin_country']!.text.trim().isEmpty ? null : f['origin_country']!.text.trim().toUpperCase(),
          'package_type': pkg,
          'packages': int.parse(f['packages']!.text),
          'length_cm': double.tryParse(f['length_cm']!.text),
          'width_cm': double.tryParse(f['width_cm']!.text),
          'height_cm': double.tryParse(f['height_cm']!.text),
          'weight_kg': double.tryParse(f['weight_kg']!.text) ?? 0,
          'units': units,
          'unit_value': unitValue,
          'value': units != null && unitValue != null ? units * unitValue : null,
          'sort_order': it?['sort_order'] ?? _items.length,
        };
        if (it == null) {
          await _s.db.from('shipment_items').insert(data);
        } else {
          await _s.db.from('shipment_items').update(data).eq('id', it['id']);
        }
      }
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message.contains('hs_code') ? 'HS code should be 4–12 digits' : e.message);
    }
  }

  // ---------- containers ----------
  Future<void> _editContainer([Map<String, dynamic>? ct]) async {
    final no = TextEditingController(text: ct?['container_no'] as String? ?? '');
    final seal = TextEditingController(text: ct?['seal_no'] as String? ?? '');
    final tare = TextEditingController(text: ct?['tare_kg']?.toString() ?? '');
    final cargo = TextEditingController(text: ct?['cargo_kg']?.toString() ?? '');
    var size = (ct?['size_type'] ?? '40HC') as String;
    var status = (ct?['status'] ?? 'planned') as String;
    final res = await showDialog<String>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(ct == null ? 'Add container' : 'Container'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: size,
                decoration: const InputDecoration(labelText: 'Size / type'),
                items: [for (final c in containerTypes) DropdownMenuItem(value: c, child: Text(c))],
                onChanged: (v) => set(() => size = v!),
              ),
              TextField(
                controller: no,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Container no. (e.g. MSKU1234565)', helperText: 'Check digit is verified'),
              ),
              TextField(controller: seal, decoration: const InputDecoration(labelText: 'Seal no.')),
              Row(children: [
                Expanded(child: TextField(controller: tare, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Tare kg'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: cargo, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Cargo kg'))),
              ]),
              DropdownButtonFormField<String>(
                value: status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: [
                  for (final c in const ['planned', 'empty_released', 'gated_in', 'loaded', 'discharged', 'gated_out', 'delivered', 'returned'])
                    DropdownMenuItem(value: c, child: Text(statusLabel(c)))
                ],
                onChanged: (v) => set(() => status = v!),
              ),
            ]),
          ),
          actions: [
            if (ct != null) TextButton(onPressed: () => Navigator.pop(context, 'delete'), child: const Text('Delete')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (res == null) return;
    try {
      if (res == 'delete') {
        await _s.db.from('shipment_containers').delete().eq('id', ct!['id']);
      } else {
        final data = {
          'tenant_id': _s.tenantId,
          'shipment_id': _id,
          'size_type': size,
          'container_no': no.text.trim().isEmpty ? null : no.text.replaceAll(' ', '').toUpperCase(),
          'seal_no': seal.text.trim().isEmpty ? null : seal.text.trim(),
          'tare_kg': double.tryParse(tare.text),
          'cargo_kg': double.tryParse(cargo.text),
          'status': status,
        };
        if (ct == null) {
          await _s.db.from('shipment_containers').insert(data);
        } else {
          await _s.db.from('shipment_containers').update(data).eq('id', ct['id']);
        }
      }
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message.contains('container_no') ? 'That container number fails the ISO 6346 check digit — please re-check it' : e.message);
    }
  }

  // ---------- tracking ----------
  Future<void> _addEvent() async {
    var code = 'in_transit';
    final loc = TextEditingController();
    final note = TextEditingController();
    var public = true;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Post update', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final e in _eventCodes.entries)
                    ChoiceChip(label: Text(e.value), selected: code == e.key, onSelected: (_) => set(() => code = e.key)),
                ]),
                TextField(controller: loc, decoration: const InputDecoration(labelText: 'Where?')),
                TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Details (optional)')),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show to customer on tracking page'),
                  value: public,
                  onChanged: (v) => set(() => public = v),
                ),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Post')),
              ]),
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await _s.db.rpc('add_shipment_event', params: {
        'p_shipment': _id,
        'p_code': code,
        'p_location': loc.text.trim().isEmpty ? null : loc.text.trim(),
        'p_note': note.text.trim().isEmpty ? null : note.text.trim(),
        'p_public': public,
      });
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  // ---------- charges ----------
  Future<void> _editCharge(String side, [Map<String, dynamic>? ch]) async {
    final locked = ch != null && (ch['invoice_id'] != null || ch['posted_at'] != null);
    if (locked) {
      _snack(ch['invoice_id'] != null ? 'Already invoiced' : 'Already posted to accounts');
      return;
    }
    var code = (ch?['code'] ?? 'freight') as String;
    final desc = TextEditingController(text: ch?['description'] as String? ?? '');
    final qty = TextEditingController(text: ch?['qty']?.toString() ?? '1');
    final price = TextEditingController(text: ch?['unit_price']?.toString() ?? '');
    final cur = TextEditingController(text: (ch?['currency'] ?? _s.currency) as String);
    final fx = TextEditingController(text: ch?['fx_rate']?.toString() ?? '1');
    String? supplier = ch?['supplier_id'] as String? ?? (side == 'cost' ? _carrierId : null);
    String? taxCode = ch?['tax_code'] as String?;
    final res = await showDialog<String>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(side == 'revenue' ? 'Charge to customer' : 'Cost from supplier'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: code,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [for (final e in _chargeCodes.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => set(() {
                  code = v!;
                  if (desc.text.isEmpty) desc.text = _chargeCodes[v]!;
                }),
              ),
              TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
              Row(children: [
                Expanded(child: TextField(controller: qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Qty (${_sh?['chargeable_unit'] ?? ''})'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Rate'))),
              ]),
              Row(children: [
                Expanded(child: TextField(controller: cur, decoration: const InputDecoration(labelText: 'Currency'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: fx, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'FX to ${_s.currency}'))),
              ]),
              if (side == 'cost')
                DropdownButtonFormField<String?>(
                  value: supplier,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Supplier'),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('—')),
                    for (final c in _carriers) DropdownMenuItem<String?>(value: c['id'] as String, child: Text(c['name'] as String)),
                  ],
                  onChanged: (v) => set(() => supplier = v),
                )
              else
                DropdownButtonFormField<String?>(
                  value: _s.taxTable.containsKey(taxCode) ? taxCode : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Tax when invoiced'),
                  items: [
                    DropdownMenuItem<String?>(value: null, child: Text('Default (${_s.taxFor(null).name})')),
                    for (final t in _s.taxTable.values) DropdownMenuItem<String?>(value: t.code, child: Text(t.name)),
                  ],
                  onChanged: (v) => set(() => taxCode = v),
                ),
            ]),
          ),
          actions: [
            if (ch != null) TextButton(onPressed: () => Navigator.pop(context, 'delete'), child: const Text('Delete')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (res == null) return;
    try {
      if (res == 'delete') {
        await _s.db.from('shipment_charges').delete().eq('id', ch!['id']);
      } else {
        final p = double.tryParse(price.text);
        if (p == null || desc.text.trim().isEmpty) {
          _snack('Enter a description and rate');
          return;
        }
        final data = {
          'tenant_id': _s.tenantId,
          'shipment_id': _id,
          'side': side,
          'code': code,
          'description': desc.text.trim(),
          'qty': double.tryParse(qty.text) ?? 1,
          'unit_price': p,
          'currency': cur.text.trim().toUpperCase(),
          'fx_rate': double.tryParse(fx.text) ?? 1,
          'supplier_id': side == 'cost' ? supplier : null,
          'tax_code': side == 'revenue' ? taxCode : null,
        };
        if (ch == null) {
          await _s.db.from('shipment_charges').insert(data);
        } else {
          await _s.db.from('shipment_charges').update(data).eq('id', ch['id']);
        }
      }
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _invoice() async {
    try {
      final inv = await _s.db.rpc('invoice_shipment', params: {'p_shipment': _id}) as String;
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => InvoiceEditScreen(invoiceId: inv)));
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _postCosts() async {
    try {
      final n = await _s.db.rpc('post_shipment_costs', params: {'p_shipment': _id});
      _snack('$n cost line(s) posted to accounts payable');
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _customsEstimate() async {
    try {
      final r = Map<String, dynamic>.from(await _s.db.rpc('shipment_customs_estimate', params: {'p_shipment': _id}) as Map);
      if (!mounted) return;
      String n(dynamic v) => NumberFormat('#,##0.00').format((v as num).toDouble());
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('Duties & taxes into ${r['destination']}'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Goods ${n(r['goods_value'])} · freight ${n(r['freight'])}'),
              const Divider(),
              for (final l in (r['lines'] as List))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('${l['description']} (HS ${l['hs_code'] ?? '?'}): duty ${n(l['duty'])}'
                      '${l['duty_found'] == true ? '' : ' — rate unknown'} · ${l['tax_name']} ${n(l['import_tax'])}'),
                ),
              const Divider(),
              Text('Duty ${n(r['duty'])}'),
              Text('Import tax ${n(r['import_tax'])}'),
              Text('Total ${n(r['total_taxes'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Estimate in the values you entered; confirm with your customs broker.', style: TextStyle(fontSize: 12)),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
        ),
      );
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _cancel() async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel shipment?'),
        content: TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason *')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Back')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Cancel shipment')),
        ],
      ),
    );
    if (ok != true || reason.text.trim().isEmpty) return;
    try {
      await _s.db.rpc('cancel_shipment', params: {'p_shipment': _id, 'p_reason': reason.text.trim()});
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  String get _trackingLink {
    final token = _sh?['public_token'] as String? ?? '';
    return AppConfig.trackingUrl.isEmpty ? 'Tracking code: $token' : '${AppConfig.trackingUrl}?t=$token';
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final sh = _sh;
    return Scaffold(
      appBar: AppBar(
        title: Text(sh?['ref'] as String? ?? 'New shipment'),
        actions: [
          if (sh != null) ...[
            IconButton(
              tooltip: 'Copy tracking link',
              icon: const Icon(Icons.share_location_outlined),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _trackingLink));
                _snack(sh['status'] == 'draft' ? 'Copied — the link works once the shipment leaves draft' : 'Tracking link copied');
              },
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'label':
                    await PrintingService.printShippingLabels(shipment: sh, trackingText: _trackingLink);
                  case 'ci':
                    await PrintingService.printCommercialInvoice(shipment: sh, items: _items, containers: _containers);
                  case 'customs':
                    await _customsEstimate();
                  case 'edit':
                    setState(() => _editing = true);
                  case 'cancel':
                    await _cancel();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'label', child: Text('Print package labels')),
                const PopupMenuItem(value: 'ci', child: Text('Commercial invoice & packing list')),
                const PopupMenuItem(value: 'customs', child: Text('Estimate duties & taxes')),
                if (_canEdit) const PopupMenuItem(value: 'edit', child: Text('Edit details')),
                if (_canEdit && sh['status'] != 'cancelled' && sh['status'] != 'delivered')
                  const PopupMenuItem(value: 'cancel', child: Text('Cancel shipment')),
              ],
            ),
          ],
        ],
      ),
      floatingActionButton: sh != null && (_canEdit || _s.can('log.event.add')) && sh['status'] != 'cancelled'
          ? FloatingActionButton.extended(heroTag: null, onPressed: _addEvent, icon: const Icon(Icons.add_location_alt_outlined), label: const Text('Update'))
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _editing && _canEdit
              ? _form()
              : RefreshIndicator(onRefresh: _load, child: _detail()),
    );
  }

  Widget _detail() {
    final sh = _sh!;
    final t = Theme.of(context).textTheme;
    final fmt = DateFormat('d MMM yyyy, HH:mm');
    String d(dynamic v) => v == null ? '—' : fmt.format(DateTime.parse(v as String).toLocal());
    final revenue = (sh['revenue'] as num).toDouble();
    final cost = (sh['cost'] as num).toDouble();
    final err = Theme.of(context).colorScheme.error;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(modeIcons[sh['mode']]),
              const SizedBox(width: 8),
              Text(statusLabel(sh['status'] as String), style: t.titleLarge),
              const Spacer(),
              if (sh['late'] == true) Text('LATE', style: TextStyle(color: err, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 4),
            Text('${sh['origin_code'] ?? '?'} ${sh['origin_name'] ?? ''}  →  ${sh['dest_code'] ?? '?'} ${sh['dest_name'] ?? ''}'),
            Text('${modeLabels[sh['mode']]} · ${sh['direction']}${sh['incoterm'] != null ? ' · ${sh['incoterm']}' : ''}'),
            const SizedBox(height: 4),
            Text('ETD ${d(sh['etd'])}  ·  ETA ${d(sh['eta'])}', style: t.bodySmall),
            if (sh['atd'] != null || sh['ata'] != null) Text('Departed ${d(sh['atd'])}  ·  Arrived ${d(sh['ata'])}', style: t.bodySmall),
            if (sh['delivered_at'] != null) Text('Delivered ${d(sh['delivered_at'])}', style: t.bodySmall),
          ]),
        ),
      ),
      _section('Parties & references'),
      ...[
        ('Customer (pays)', sh['customer_name']),
        ('Shipper', sh['shipper_name']),
        ('Consignee', sh['consignee_name']),
        ('Carrier', sh['carrier_name']),
        if (sh['vessel_name'] != null) ('Vessel / voyage', '${sh['vessel_name']} ${sh['voyage_no']}'),
        if (sh['flight_no'] != null) ('Flight', sh['flight_no']),
        ('Booking no.', sh['booking_no']),
        (sh['mode'] == 'air' ? 'MAWB' : 'MBL', sh['master_no']),
        (sh['mode'] == 'air' ? 'HAWB' : 'HBL', sh['house_no']),
        ('Customs', '${statusLabel(sh['customs_status'] as String)}${sh['customs_ref'] != null ? ' · ${sh['customs_ref']}' : ''}'),
        if (sh['dangerous_goods'] == true) ('Dangerous goods', '${sh['un_number']} class ${sh['dg_class'] ?? '?'}'),
        if (sh['temp_min_c'] != null || sh['temp_max_c'] != null) ('Temperature', '${sh['temp_min_c'] ?? '?'} to ${sh['temp_max_c'] ?? '?'} °C'),
        if (sh['pickup_address'] != null) ('Pick up', sh['pickup_address']),
        if (sh['delivery_address'] != null) ('Deliver to', sh['delivery_address']),
      ].where((e) => e.$2 != null).map((e) => _kv(e.$1, '${e.$2}')),
      _section('Cargo', action: _canEdit ? () => _editItem() : null),
      Text('${sh['packages']} pkgs · ${sh['gross_kg']} kg · ${sh['volume_cbm']} cbm · chargeable ${sh['chargeable']} ${sh['chargeable_unit']}'
          '${sh['declared_value'] != null ? ' · value ${NumberFormat('#,##0.00').format(sh['declared_value'])}' : ''}',
          style: t.bodySmall),
      for (final it in _items)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(it['description'] as String),
          subtitle: Text([
            '${it['packages']} ${it['package_type']}',
            if (it['length_cm'] != null) '${it['length_cm']}×${it['width_cm']}×${it['height_cm']} cm',
            '${it['weight_kg']} kg each',
            if (it['hs_code'] != null) 'HS ${it['hs_code']}',
          ].join(' · ')),
          trailing: it['value'] == null ? null : Text(NumberFormat('#,##0.00').format(it['value'])),
          onTap: _canEdit ? () => _editItem(it) : null,
        ),
      if (_mode.startsWith('sea') || _containers.isNotEmpty) ...[
        _section('Containers', action: _canEdit ? () => _editContainer() : null),
        for (final c in _containers)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.view_in_ar_outlined),
            title: Text('${c['container_no'] ?? 'Not assigned'} · ${c['size_type']}'),
            subtitle: Text([
              statusLabel(c['status'] as String),
              if (c['seal_no'] != null) 'seal ${c['seal_no']}',
              if ((c['vgm_kg'] as num) > 0) 'VGM ${c['vgm_kg']} kg',
            ].join(' · ')),
            onTap: _canEdit ? () => _editContainer(c) : null,
          ),
      ],
      _section('Tracking'),
      if (_events.isEmpty) const Text('No updates yet'),
      for (final e in _events)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(e['code'] == 'exception' ? Icons.warning_amber : Icons.radio_button_checked,
              size: 18, color: e['code'] == 'exception' ? err : null),
          title: Text('${_eventCodes[e['code']] ?? e['code']}${e['location'] != null ? ' — ${e['location']}' : ''}'),
          subtitle: Text('${d(e['at'])}${e['note'] != null ? '\n${e['note']}' : ''}${e['public'] == false ? '\n(internal)' : ''}'),
        ),
      if (_canEdit || _s.can('log.finance')) ...[
        _section('Charges'),
        Row(children: [
          _stat('Revenue', _money.format(revenue)),
          _stat('Cost', _money.format(cost)),
          _stat('Profit', '${_money.format(revenue - cost)}${revenue > 0 ? ' (${((revenue - cost) / revenue * 100).toStringAsFixed(0)}%)' : ''}'),
        ]),
        for (final side in const ['revenue', 'cost']) ...[
          Row(children: [
            Text(side == 'revenue' ? 'To customer' : 'From suppliers', style: t.titleSmall),
            const Spacer(),
            if (_canEdit) TextButton.icon(onPressed: () => _editCharge(side), icon: const Icon(Icons.add), label: const Text('Add')),
          ]),
          for (final ch in _charges.where((c) => c['side'] == side))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(ch['description'] as String),
              subtitle: Text([
                '${ch['qty']} × ${ch['unit_price']} ${ch['currency']}',
                if ((ch['fx_rate'] as num) != 1) '@ ${ch['fx_rate']}',
                if (ch['supplier'] != null) ch['supplier']['name'],
                if (ch['invoice_id'] != null) 'invoiced',
                if (ch['posted_at'] != null) 'posted',
              ].join(' · ')),
              trailing: Text(_money.format(ch['amount_base'])),
              onTap: _canEdit ? () => _editCharge(side, ch) : null,
            ),
        ],
        if (_s.can('log.finance'))
          Wrap(spacing: 8, children: [
            FilledButton.tonalIcon(onPressed: _invoice, icon: const Icon(Icons.receipt_long_outlined), label: const Text('Invoice customer')),
            OutlinedButton.icon(onPressed: _postCosts, icon: const Icon(Icons.account_balance_outlined), label: const Text('Post costs')),
          ]),
      ],
      const Divider(height: 32),
      if (_canEdit || _s.can('log.shipment.view')) Timeline(shipmentId: _id),
      const SizedBox(height: 80),
    ]);
  }

  Widget _section(String title, {VoidCallback? action}) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Row(children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (action != null) IconButton(onPressed: action, icon: const Icon(Icons.add)),
        ]),
      );

  Widget _kv(String a, String b) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(a, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: Text(b)),
        ]),
      );

  Widget _stat(String label, String value) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              FittedBox(child: Text(value, style: Theme.of(context).textTheme.titleSmall)),
            ]),
          ),
        ),
      );

  Widget _form() {
    final kind = _mode == 'air' ? 'air' : (_mode.startsWith('sea') ? 'sea' : null);
    Widget party(String label, Map<String, dynamic>? v, void Function(Map<String, dynamic>?) set) => ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          subtitle: Text(v?['company'] as String? ?? v?['name'] as String? ?? 'Choose…'),
          trailing: v == null ? const Icon(Icons.chevron_right) : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => set(null))),
          onTap: () async {
            final c = await ContactPicker.show(context, title: 'Search $label');
            if (c != null) setState(() => set(c));
          },
        );
    Widget tf(String k, String label, {TextInputType? type, int lines = 1}) => TextField(
          controller: _c[k],
          keyboardType: type,
          maxLines: lines,
          decoration: InputDecoration(labelText: label),
        );
    Widget date(String label, DateTime? v, void Function(DateTime) set) => Expanded(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(label),
            subtitle: Text(v == null ? '—' : DateFormat('d MMM yyyy').format(v)),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: v ?? DateTime.now(),
                firstDate: DateTime.now().subtract(const Duration(days: 365)),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (d != null) setState(() => set(d));
            },
          ),
        );
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final m in modeLabels.entries)
          ChoiceChip(
            avatar: Icon(modeIcons[m.key], size: 18),
            label: Text(m.value),
            selected: _mode == m.key,
            onSelected: (_) => setState(() => _mode = m.key),
          ),
      ]),
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            value: _direction,
            decoration: const InputDecoration(labelText: 'Direction'),
            items: [for (final d in const ['export', 'import', 'domestic', 'cross_trade']) DropdownMenuItem(value: d, child: Text(statusLabel(d)))],
            onChanged: (v) => setState(() => _direction = v!),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<String?>(
            value: _incoterm,
            decoration: const InputDecoration(labelText: 'Incoterm'),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('—')),
              for (final i in _incoterms) DropdownMenuItem<String?>(value: i, child: Text(i)),
            ],
            onChanged: (v) => setState(() => _incoterm = v),
          ),
        ),
      ]),
      party('Customer (who pays)', _customer, (v) => _customer = v),
      party('Shipper', _shipper, (v) => _shipper = v),
      party('Consignee', _consignee, (v) => _consignee = v),
      Row(children: [
        Expanded(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('From'),
            subtitle: Text(portLabel(_origin)),
            onTap: () async {
              final p = await PortPicker.show(context, kind: kind);
              if (p != null) setState(() => _origin = p);
            },
          ),
        ),
        Expanded(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('To'),
            subtitle: Text(portLabel(_dest)),
            onTap: () async {
              final p = await PortPicker.show(context, kind: kind);
              if (p != null) setState(() => _dest = p);
            },
          ),
        ),
      ]),
      DropdownButtonFormField<String?>(
        value: _carriers.any((c) => c['id'] == _carrierId) ? _carrierId : null,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Carrier'),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('—')),
          for (final c in _carriers.where((c) => const ['carrier_sea', 'carrier_air', 'trucking', 'forwarder', 'agent'].contains(c['category'])))
            DropdownMenuItem<String?>(value: c['id'] as String, child: Text(c['name'] as String)),
        ],
        onChanged: (v) => setState(() => _carrierId = v),
      ),
      if (_mode.startsWith('sea'))
        DropdownButtonFormField<String?>(
          value: _voyages.any((v) => v['id'] == _voyageId) ? _voyageId : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Vessel / voyage'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('—')),
            for (final v in _voyages) DropdownMenuItem<String?>(value: v['id'] as String, child: Text('${v['vessel']?['name']} ${v['voyage_no']}')),
          ],
          onChanged: (v) => setState(() {
            _voyageId = v;
            final voy = _voyages.where((x) => x['id'] == v).firstOrNull;
            if (voy != null) {
              _etd ??= voy['etd'] == null ? null : DateTime.parse(voy['etd'] as String).toLocal();
              _eta ??= voy['eta'] == null ? null : DateTime.parse(voy['eta'] as String).toLocal();
            }
          }),
        ),
      if (_mode == 'air') tf('flight_no', 'Flight no. (e.g. MH4)'),
      Row(children: [date('ETD', _etd, (d) => _etd = d), date('ETA', _eta, (d) => _eta = d)]),
      tf('booking_no', 'Booking no.'),
      Row(children: [
        Expanded(child: tf('master_no', _mode == 'air' ? 'MAWB (e.g. 232-12345675)' : 'Master B/L')),
        const SizedBox(width: 12),
        Expanded(child: tf('house_no', _mode == 'air' ? 'HAWB' : 'House B/L')),
      ]),
      tf('cargo_description', 'Cargo description', lines: 2),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Dangerous goods'), value: _dg, onChanged: (v) => setState(() => _dg = v)),
      if (_dg)
        Row(children: [
          Expanded(child: tf('un_number', 'UN number (e.g. UN1263)')),
          const SizedBox(width: 12),
          Expanded(child: tf('dg_class', 'Class (e.g. 3)')),
        ]),
      Row(children: [
        Expanded(child: tf('temp_min_c', 'Min °C', type: const TextInputType.numberWithOptions(decimal: true, signed: true))),
        const SizedBox(width: 12),
        Expanded(child: tf('temp_max_c', 'Max °C', type: const TextInputType.numberWithOptions(decimal: true, signed: true))),
      ]),
      tf('pickup_address', 'Pick-up address', lines: 2),
      tf('delivery_address', 'Delivery address', lines: 2),
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            value: _customsStatus ?? 'not_required',
            decoration: const InputDecoration(labelText: 'Customs'),
            items: [
              for (final c in const ['not_required', 'pending', 'lodged', 'inspection', 'held', 'cleared'])
                DropdownMenuItem(value: c, child: Text(statusLabel(c)))
            ],
            onChanged: (v) => setState(() => _customsStatus = v),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: tf('customs_ref', 'Declaration ref.')),
      ]),
      tf('notes', 'Internal notes', lines: 3),
      const SizedBox(height: 16),
      FilledButton(onPressed: _busy ? null : _save, child: Text(_id == null ? 'Create shipment' : 'Save')),
      if (_id != null) TextButton(onPressed: () => setState(() => _editing = false), child: const Text('Cancel')),
      const SizedBox(height: 40),
    ]);
  }
}
