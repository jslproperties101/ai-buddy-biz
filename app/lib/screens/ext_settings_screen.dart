import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/orders.dart';
import '../services/printing_service.dart';
import '../services/session.dart';

/// Settings for orders, tables, kitchen, menu options, delivery, bookings and online shops.
class ExtSettingsScreen extends StatelessWidget {
  const ExtSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget tile(IconData i, String t, String sub, Widget page) => ListTile(
          leading: Icon(i),
          title: Text(t),
          subtitle: Text(sub),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Orders & bookings settings')),
      body: ListView(children: [
        tile(Icons.tune, 'Ordering & booking options', 'QR ordering, online orders, service charge, booking rules, web links', const _GeneralPage()),
        tile(Icons.schedule, 'Opening hours', 'Used for online orders and bookings', const _HoursPage()),
        tile(Icons.table_restaurant_outlined, 'Areas & tables', 'Floor plan, seats, QR codes', const _TablesPage()),
        tile(Icons.restaurant_menu, 'Menu', 'On the menu, sold out ("86"), kitchen station per item', const _MenuPage()),
        tile(Icons.playlist_add_check, 'Options (modifiers)', 'Spice level, add-ons, sizes — and which items use them', const _ModifiersPage()),
        tile(Icons.soup_kitchen_outlined, 'Kitchen stations', 'Kitchen, bar, dessert…', const _StationsPage()),
        tile(Icons.delivery_dining, 'Delivery areas', 'Postcodes, fees and minimum order', const _ZonesPage()),
        tile(Icons.event_available, 'Services, staff & rooms', 'What customers can book and with whom', const _ServicesPage()),
        tile(Icons.storefront_outlined, 'Online shop sync', 'Shopify / WooCommerce orders and stock', const _ShopPage()),
      ]),
    );
  }
}

AppSession get _s => AppSession.instance;

void _snack(BuildContext c, String t) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(t)));

Future<void> _run(BuildContext context, Future<void> Function() f, [String ok = 'Saved']) async {
  try {
    await f();
    if (context.mounted) _snack(context, ok);
  } catch (e) {
    if (context.mounted) _snack(context, Orders.errorText(e));
  }
}

/// Small form dialog: list of (key, label, initial, keyboard) text fields.
Future<Map<String, String>?> _form(BuildContext context, String title, List<(String, String, String, TextInputType?)> fields, {String? delete}) async {
  final c = {for (final f in fields) f.$1: TextEditingController(text: f.$3)};
  final r = await showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final f in fields) TextField(controller: c[f.$1], keyboardType: f.$4, decoration: InputDecoration(labelText: f.$2)),
        ]),
      ),
      actions: [
        if (delete != null) TextButton(onPressed: () => Navigator.pop(context, 'delete'), child: Text(delete)),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
      ],
    ),
  );
  if (r == null) return null;
  if (r == 'delete') return {'__delete': '1'};
  return {for (final e in c.entries) e.key: e.value.text.trim()};
}

const _num = TextInputType.numberWithOptions(decimal: true);

// ───────────────────────── General ─────────────────────────

class _GeneralPage extends StatefulWidget {
  const _GeneralPage();
  @override
  State<_GeneralPage> createState() => _GeneralPageState();
}

class _GeneralPageState extends State<_GeneralPage> {
  Map<String, dynamic>? _st;
  final _url = TextEditingController();
  final _prep = TextEditingController();
  final _svc = TextEditingController();
  final _slot = TextEditingController();
  final _tableMins = TextEditingController();
  final _maxParty = TextEditingController();
  final _notice = TextEditingController();
  final _ahead = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _st = await Orders.settings(refresh: true);
    final st = _st ?? {};
    _url.text = (st['web_base_url'] ?? '') as String;
    _prep.text = '${st['prep_minutes'] ?? 20}';
    _svc.text = '${st['service_charge_pct'] ?? 0}';
    _slot.text = '${st['booking_slot_minutes'] ?? 15}';
    _tableMins.text = '${st['table_booking_minutes'] ?? 90}';
    _maxParty.text = '${st['booking_max_party'] ?? 12}';
    _notice.text = '${st['booking_min_notice_minutes'] ?? 60}';
    _ahead.text = '${st['booking_days_ahead'] ?? 60}';
    if (mounted) setState(() {});
  }

  bool _b(String k) => _st?[k] == true;
  void _flip(String k, bool v) => setState(() => _st![k] = v);

  Future<void> _save() async {
    final url = _url.text.trim();
    if (url.isNotEmpty && !url.startsWith('https://')) return _snack(context, 'The web pages address must start with https://');
    await _run(context, () async {
      await _s.db.from('ext_settings').update({
        'web_base_url': url.isEmpty ? null : url,
        'qr_ordering': _b('qr_ordering'),
        'qr_auto_send': _b('qr_auto_send'),
        'online_ordering': _b('online_ordering'),
        'pickup_enabled': _b('pickup_enabled'),
        'delivery_enabled': _b('delivery_enabled'),
        'prep_minutes': int.tryParse(_prep.text) ?? 20,
        'service_charge_pct': double.tryParse(_svc.text) ?? 0,
        'service_charge_dine_in_only': _b('service_charge_dine_in_only'),
        'booking_enabled': _b('booking_enabled'),
        'booking_slot_minutes': int.tryParse(_slot.text) ?? 15,
        'table_booking_minutes': int.tryParse(_tableMins.text) ?? 90,
        'booking_max_party': int.tryParse(_maxParty.text) ?? 12,
        'booking_min_notice_minutes': int.tryParse(_notice.text) ?? 60,
        'booking_days_ahead': int.tryParse(_ahead.text) ?? 60,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('tenant_id', _s.tenantId!);
      await Orders.settings(refresh: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_st == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final key = _st!['online_key'] as String;
    final menuLink = Orders.webPage('menu.html', 'k=$key');
    final bookLink = Orders.webPage('book.html', 'k=$key');
    Widget sw(String k, String t, [String? sub]) =>
        SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(t), subtitle: sub == null ? null : Text(sub), value: _b(k), onChanged: (v) => _flip(k, v));
    Widget link(String label, String? url) => ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          subtitle: Text(url ?? 'Set the web pages address first'),
          trailing: url == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: url));
                    _snack(context, 'Copied');
                  }),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Ordering & booking'), actions: [TextButton(onPressed: _save, child: const Text('Save'))]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
              labelText: 'Web pages address', hintText: 'https://order.yourshop.com', helperText: 'Where menu.html, order.html and book.html are hosted (see README)'),
        ),
        link('Online ordering link', menuLink),
        link('Booking link', bookLink),
        const Divider(),
        Text('At the table', style: Theme.of(context).textTheme.titleSmall),
        sw('qr_ordering', 'Customers can order by scanning the table QR'),
        sw('qr_auto_send', 'Send QR orders straight to the kitchen', 'Off: staff accept each QR order first'),
        TextField(controller: _svc, keyboardType: _num, decoration: const InputDecoration(labelText: 'Service charge %')),
        sw('service_charge_dine_in_only', 'Service charge for dine-in only'),
        const Divider(),
        Text('Online orders', style: Theme.of(context).textTheme.titleSmall),
        sw('online_ordering', 'Take online orders (pickup / delivery)'),
        sw('pickup_enabled', 'Pickup'),
        sw('delivery_enabled', 'Delivery', 'Set delivery areas and fees under Delivery areas'),
        TextField(controller: _prep, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Usual preparation time (minutes)')),
        const Text('Customers pay when they collect or on delivery (cash, card or QR at the counter). Online card payment is not built in yet.',
            style: TextStyle(fontSize: 12)),
        const Divider(),
        Text('Bookings', style: Theme.of(context).textTheme.titleSmall),
        sw('booking_enabled', 'Customers can book online'),
        Row(children: [
          Expanded(child: TextField(controller: _slot, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Time step (min)'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _tableMins, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Table booking length (min)'))),
        ]),
        Row(children: [
          Expanded(child: TextField(controller: _maxParty, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Largest party online'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _notice, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Minimum notice (min)'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _ahead, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Days ahead'))),
        ]),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => _run(context, () async {
            final n = await _s.db.rpc('queue_booking_reminders', params: {'p_tenant': _s.tenantId});
            if (context.mounted) _snack(context, '$n reminder(s) queued');
          }, 'Done'),
          icon: const Icon(Icons.notifications_outlined),
          label: const Text('Send reminders for the next 24 hours now'),
        ),
      ]),
    );
  }
}

// ───────────────────────── Opening hours ─────────────────────────

class _HoursPage extends StatefulWidget {
  const _HoursPage();
  @override
  State<_HoursPage> createState() => _HoursPageState();
}

class _HoursPageState extends State<_HoursPage> {
  List<Map<String, dynamic>> _rows = [];
  static const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_s.outlet == null) return;
    _rows = List<Map<String, dynamic>>.from(await _s.db.from('business_hours').select().eq('outlet_id', _s.outlet!.id).order('weekday').order('opens'));
    if (mounted) setState(() {});
  }

  Future<TimeOfDay?> _time(TimeOfDay t, String help) => showTimePicker(context: context, initialTime: t, helpText: help);
  String _hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _add(int day) async {
    final o = await _time(const TimeOfDay(hour: 10, minute: 0), 'Opens');
    if (o == null || !mounted) return;
    final c = await _time(const TimeOfDay(hour: 22, minute: 0), 'Closes');
    if (c == null || !mounted) return;
    await _run(context, () async => _s.db.from('business_hours').insert({'tenant_id': _s.tenantId, 'outlet_id': _s.outlet!.id, 'weekday': day, 'opens': _hm(o), 'closes': _hm(c)}));
    _load();
  }

  Future<void> _copyMonday() async {
    final mon = _rows.where((r) => r['weekday'] == 1).toList();
    if (mon.isEmpty) return _snack(context, 'Set Monday first');
    await _run(context, () async {
      await _s.db.from('business_hours').delete().eq('outlet_id', _s.outlet!.id).neq('weekday', 1);
      await _s.db.from('business_hours').insert([
        for (var d = 2; d <= 7; d++)
          for (final r in mon) {'tenant_id': _s.tenantId, 'outlet_id': _s.outlet!.id, 'weekday': d, 'opens': r['opens'], 'closes': r['closes']}
      ]);
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Hours · ${_s.outlet?.name ?? ''}'), actions: [TextButton(onPressed: _copyMonday, child: const Text('Copy Mon to all'))]),
      body: ListView(children: [
        if (_rows.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No hours set: online orders are accepted any time and bookings are closed.')),
        for (var d = 1; d <= 7; d++)
          ListTile(
            title: Text(_days[d - 1]),
            subtitle: Wrap(spacing: 6, children: [
              for (final r in _rows.where((r) => r['weekday'] == d))
                InputChip(
                  label: Text('${'${r['opens']}'.substring(0, 5)}–${'${r['closes']}'.substring(0, 5)}'),
                  onDeleted: () async {
                    await _s.db.from('business_hours').delete().eq('id', r['id']);
                    _load();
                  },
                ),
              if (!_rows.any((r) => r['weekday'] == d)) const Text('Closed'),
            ]),
            trailing: IconButton(icon: const Icon(Icons.add), onPressed: () => _add(d)),
          ),
      ]),
    );
  }
}

// ───────────────────────── Areas & tables ─────────────────────────

class _TablesPage extends StatefulWidget {
  const _TablesPage();
  @override
  State<_TablesPage> createState() => _TablesPageState();
}

class _TablesPageState extends State<_TablesPage> {
  List<Map<String, dynamic>> _areas = [], _tables = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_s.outlet == null) return;
    _areas = List<Map<String, dynamic>>.from(await _s.db.from('dining_areas').select().eq('outlet_id', _s.outlet!.id).order('sort_order'));
    _tables = List<Map<String, dynamic>>.from(await _s.db.from('dining_tables').select().eq('outlet_id', _s.outlet!.id).order('sort_order').order('name'));
    if (mounted) setState(() {});
  }

  Future<void> _area([Map<String, dynamic>? a]) async {
    final r = await _form(context, a == null ? 'New area' : 'Area', [('name', 'Name (Indoor, Patio…)', (a?['name'] ?? '') as String, null)],
        delete: a == null ? null : 'Delete');
    if (r == null) return;
    if (!mounted) return;
    await _run(context, () async {
      if (r['__delete'] != null) {
        await _s.db.from('dining_areas').delete().eq('id', a!['id']);
      } else if (a == null) {
        await _s.db.from('dining_areas').insert({'tenant_id': _s.tenantId, 'outlet_id': _s.outlet!.id, 'name': r['name'], 'sort_order': _areas.length});
      } else {
        await _s.db.from('dining_areas').update({'name': r['name']}).eq('id', a['id']);
      }
    });
    _load();
  }

  Future<void> _table([Map<String, dynamic>? t]) async {
    String? area = (t?['area_id'] ?? (_areas.isEmpty ? null : _areas.first['id'])) as String?;
    bool bookable = (t?['bookable'] ?? true) as bool;
    bool active = (t?['active'] ?? true) as bool;
    final name = TextEditingController(text: (t?['name'] ?? 'T${_tables.length + 1}') as String);
    final seats = TextEditingController(text: '${t?['seats'] ?? 4}');
    final res = await showDialog<String>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(t == null ? 'New table' : 'Table'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name / number')),
            TextField(controller: seats, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Seats')),
            DropdownButtonFormField<String?>(
              value: area,
              decoration: const InputDecoration(labelText: 'Area'),
              items: [const DropdownMenuItem(value: null, child: Text('—')), for (final a in _areas) DropdownMenuItem(value: a['id'] as String, child: Text('${a['name']}'))],
              onChanged: (v) => set(() => area = v),
            ),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Can be booked'), value: bookable, onChanged: (v) => set(() => bookable = v)),
            if (t != null) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('In use'), value: active, onChanged: (v) => set(() => active = v)),
          ]),
          actions: [
            if (t != null) TextButton(onPressed: () => Navigator.pop(context, 'qr'), child: const Text('New QR code')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (res == null || !mounted) return;
    await _run(context, () async {
      if (res == 'qr') {
        // replaces the token so an old printed / photographed QR stops working
        await _s.db.rpc('rotate_table_qr', params: {'p_table': t!['id']});
        return;
      }
      final data = {'name': name.text.trim(), 'seats': int.tryParse(seats.text) ?? 4, 'area_id': area, 'bookable': bookable, 'active': active};
      if (t == null) {
        await _s.db.from('dining_tables').insert({...data, 'tenant_id': _s.tenantId, 'outlet_id': _s.outlet!.id, 'sort_order': _tables.length});
      } else {
        await _s.db.from('dining_tables').update(data).eq('id', t['id']);
      }
    }, res == 'qr' ? 'New QR code made — print it again' : 'Saved');
    _load();
  }

  Future<void> _printQr() async {
    await Orders.settings(refresh: true);
    final base = Orders.webPage('menu.html', 'k=');
    if (base == null) return _snack(context, 'Set the web pages address in Ordering & booking options first');
    await PrintingService.printTableQrs(
      tables: [for (final t in _tables) if (t['active'] == true) t],
      urlFor: (t) => Orders.webPage('menu.html', 'k=${t['qr_token']}')!,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Areas & tables'), actions: [
        IconButton(tooltip: 'Print QR codes', onPressed: _tables.isEmpty ? null : _printQr, icon: const Icon(Icons.qr_code_2)),
      ]),
      floatingActionButton: FloatingActionButton.extended(heroTag: null, onPressed: () => _table(), icon: const Icon(Icons.add), label: const Text('Table')),
      body: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
        ListTile(
          title: Text('Areas', style: Theme.of(context).textTheme.titleMedium),
          trailing: TextButton.icon(onPressed: () => _area(), icon: const Icon(Icons.add), label: const Text('Area')),
        ),
        Wrap(spacing: 6, children: [for (final a in _areas) ActionChip(label: Text('${a['name']}'), onPressed: () => _area(a))]),
        const Divider(),
        for (final t in _tables)
          ListTile(
            leading: const Icon(Icons.table_restaurant_outlined),
            title: Text('${t['name']}${t['active'] == true ? '' : ' (not in use)'}'),
            subtitle: Text('${t['seats']} seats · ${_areas.where((a) => a['id'] == t['area_id']).firstOrNull?['name'] ?? 'no area'}'
                '${t['bookable'] == true ? '' : ' · not bookable'}'),
            onTap: () => _table(t),
          ),
      ]),
    );
  }
}

// ───────────────────────── Menu flags ─────────────────────────

class _MenuPage extends StatefulWidget {
  const _MenuPage();
  @override
  State<_MenuPage> createState() => _MenuPageState();
}

class _MenuPageState extends State<_MenuPage> {
  List<Map<String, dynamic>> _rows = [], _stations = [];
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = await Orders.settings();
    final hidden = {st?['service_variant_id'], st?['delivery_variant_id']};
    final rows = await _s.db.from('products').select('id, name, on_menu, sold_out, station_id, kind, product_variants(id)').eq('tenant_id', _s.tenantId!).eq('active', true).order('name');
    _rows = [for (final r in rows) if (!(r['product_variants'] as List).any((v) => hidden.contains(v['id']))) r];
    _stations = List<Map<String, dynamic>>.from(await _s.db.from('kitchen_stations').select().eq('tenant_id', _s.tenantId!).order('name'));
    if (mounted) setState(() {});
  }

  Future<void> _set(Map<String, dynamic> p, {bool? soldOut, bool? onMenu, String? station}) async {
    try {
      await _s.db.rpc('set_menu_flags', params: {'p_product': p['id'], 'p_sold_out': soldOut, 'p_on_menu': onMenu, 'p_station': station});
      setState(() {
        if (soldOut != null) p['sold_out'] = soldOut;
        if (onMenu != null) p['on_menu'] = onMenu;
        if (station != null) p['station_id'] = station;
      });
    } catch (e) {
      if (mounted) _snack(context, Orders.errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _rows.where((r) => _q.isEmpty || '${r['name']}'.toLowerCase().contains(_q.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Menu')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search', isDense: true), onChanged: (v) => setState(() => _q = v)),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Add new items and prices in Catalog. Here you choose what shows on the QR/online menu, mark items sold out, and pick the kitchen station.',
              style: TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: ListView(children: [
            for (final p in shown)
              ListTile(
                title: Text('${p['name']}'),
                subtitle: Row(children: [
                  FilterChip(label: const Text('On menu'), selected: p['on_menu'] == true, onSelected: (v) => _set(p, onMenu: v), visualDensity: VisualDensity.compact),
                  const SizedBox(width: 6),
                  FilterChip(label: const Text('Sold out'), selected: p['sold_out'] == true, onSelected: (v) => _set(p, soldOut: v), visualDensity: VisualDensity.compact),
                ]),
                trailing: DropdownButton<String?>(
                  value: _stations.any((s) => s['id'] == p['station_id']) ? p['station_id'] as String : null,
                  hint: const Text('Station'),
                  items: [for (final s in _stations) DropdownMenuItem(value: s['id'] as String, child: Text('${s['name']}'))],
                  onChanged: (v) => v == null ? null : _set(p, station: v),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

// ───────────────────────── Modifiers ─────────────────────────

class _ModifiersPage extends StatefulWidget {
  const _ModifiersPage();
  @override
  State<_ModifiersPage> createState() => _ModifiersPageState();
}

class _ModifiersPageState extends State<_ModifiersPage> {
  List<Map<String, dynamic>> _groups = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _groups = List<Map<String, dynamic>>.from(await _s.db
        .from('modifier_groups')
        .select('*, modifiers(*), product_modifier_groups(product_id)')
        .eq('tenant_id', _s.tenantId!)
        .order('name'));
    if (mounted) setState(() {});
  }

  Future<void> _group([Map<String, dynamic>? g]) async {
    final r = await _form(context, g == null ? 'New option group' : 'Option group', [
      ('name', 'Name (e.g. Spice level, Add-ons, Size)', (g?['name'] ?? '') as String, null),
      ('min', 'Must choose at least (0 = optional)', '${g?['min_select'] ?? 0}', TextInputType.number),
      ('max', 'Can choose up to', '${g?['max_select'] ?? 1}', TextInputType.number),
    ], delete: g == null ? null : 'Delete');
    if (r == null || !mounted) return;
    await _run(context, () async {
      if (r['__delete'] != null) {
        await _s.db.from('modifier_groups').delete().eq('id', g!['id']);
        return;
      }
      final data = {'name': r['name'], 'min_select': int.tryParse(r['min']!) ?? 0, 'max_select': int.tryParse(r['max']!) ?? 1};
      if (g == null) {
        await _s.db.from('modifier_groups').insert({...data, 'tenant_id': _s.tenantId});
      } else {
        await _s.db.from('modifier_groups').update(data).eq('id', g['id']);
      }
    });
    Orders.clearCache();
    _load();
  }

  Future<void> _option(Map<String, dynamic> g, [Map<String, dynamic>? m]) async {
    final r = await _form(context, m == null ? 'New option' : 'Option', [
      ('name', 'Name (e.g. Extra egg)', (m?['name'] ?? '') as String, null),
      ('price', 'Extra price (0 = free)', '${m?['price_delta'] ?? 0}', _num),
    ], delete: m == null ? null : 'Delete');
    if (r == null || !mounted) return;
    await _run(context, () async {
      if (r['__delete'] != null) {
        await _s.db.from('modifiers').delete().eq('id', m!['id']);
        return;
      }
      final data = {'name': r['name'], 'price_delta': double.tryParse(r['price']!) ?? 0};
      if (m == null) {
        await _s.db.from('modifiers').insert({...data, 'tenant_id': _s.tenantId, 'group_id': g['id'], 'sort_order': (g['modifiers'] as List).length});
      } else {
        await _s.db.from('modifiers').update(data).eq('id', m['id']);
      }
    });
    Orders.clearCache();
    _load();
  }

  Future<void> _products(Map<String, dynamic> g) async {
    final products = await _s.db.from('products').select('id, name').eq('tenant_id', _s.tenantId!).eq('active', true).eq('on_menu', true).order('name');
    final on = {for (final l in g['product_modifier_groups'] as List) l['product_id'] as String};
    if (!mounted) return;
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => StatefulBuilder(
        builder: (context, set) => Scaffold(
          appBar: AppBar(title: Text('Items with ${g['name']}'), actions: [TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save'))]),
          body: ListView(children: [
            for (final p in products)
              CheckboxListTile(
                value: on.contains(p['id']),
                title: Text('${p['name']}'),
                onChanged: (v) => set(() => v == true ? on.add(p['id'] as String) : on.remove(p['id'])),
              ),
          ]),
        ),
      ),
    ));
    if (ok != true || !mounted) return;
    await _run(context, () async {
      await _s.db.from('product_modifier_groups').delete().eq('group_id', g['id']);
      if (on.isNotEmpty) {
        await _s.db.from('product_modifier_groups').insert([for (final p in on) {'tenant_id': _s.tenantId, 'product_id': p, 'group_id': g['id']}]);
      }
    });
    Orders.clearCache();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Options')),
      floatingActionButton: FloatingActionButton.extended(heroTag: null, onPressed: () => _group(), icon: const Icon(Icons.add), label: const Text('Group')),
      body: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
        if (_groups.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Create groups like "Spice level" (choose 1) or "Add-ons" (up to 3).')),
        for (final g in _groups)
          Card(
            margin: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ListTile(
                title: Text('${g['name']}'),
                subtitle: Text('${(g['min_select'] as int) > 0 ? 'required, ' : ''}choose up to ${g['max_select']} · used by ${(g['product_modifier_groups'] as List).length} item(s)'),
                trailing: IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _group(g)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final m in (g['modifiers'] as List))
                    ActionChip(
                      label: Text('${m['name']}${(m['price_delta'] as num) > 0 ? ' +${(m['price_delta'] as num).toStringAsFixed(2)}' : ''}'),
                      onPressed: () => _option(g, m as Map<String, dynamic>),
                    ),
                  ActionChip(avatar: const Icon(Icons.add, size: 16), label: const Text('Option'), onPressed: () => _option(g)),
                ]),
              ),
              Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => _products(g), child: const Text('Choose items'))),
            ]),
          ),
      ]),
    );
  }
}

// ───────────────────────── Stations ─────────────────────────

class _StationsPage extends StatefulWidget {
  const _StationsPage();
  @override
  State<_StationsPage> createState() => _StationsPageState();
}

class _StationsPageState extends State<_StationsPage> {
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _rows = List<Map<String, dynamic>>.from(await _s.db.from('kitchen_stations').select().eq('tenant_id', _s.tenantId!).order('name'));
    if (mounted) setState(() {});
  }

  Future<void> _edit([Map<String, dynamic>? r]) async {
    final f = await _form(context, r == null ? 'New station' : 'Station', [('name', 'Name (Kitchen, Bar, Dessert)', (r?['name'] ?? '') as String, null)],
        delete: r == null ? null : 'Delete');
    if (f == null || !mounted) return;
    await _run(context, () async {
      if (f['__delete'] != null) {
        await _s.db.from('kitchen_stations').delete().eq('id', r!['id']);
      } else if (r == null) {
        await _s.db.from('kitchen_stations').insert({'tenant_id': _s.tenantId, 'name': f['name']});
      } else {
        await _s.db.from('kitchen_stations').update({'name': f['name']}).eq('id', r['id']);
      }
    });
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Kitchen stations')),
        floatingActionButton: FloatingActionButton(heroTag: null, onPressed: () => _edit(), child: const Icon(Icons.add)),
        body: ListView(children: [
          for (final r in _rows) ListTile(leading: const Icon(Icons.soup_kitchen_outlined), title: Text('${r['name']}'), onTap: () => _edit(r)),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Each item goes to its station on the kitchen display (Menu page). Put a tablet at each station and filter by it.', style: TextStyle(fontSize: 12)),
          ),
        ]),
      );
}

// ───────────────────────── Delivery zones ─────────────────────────

class _ZonesPage extends StatefulWidget {
  const _ZonesPage();
  @override
  State<_ZonesPage> createState() => _ZonesPageState();
}

class _ZonesPageState extends State<_ZonesPage> {
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_s.outlet == null) return;
    _rows = List<Map<String, dynamic>>.from(await _s.db.from('delivery_zones').select().eq('outlet_id', _s.outlet!.id).order('fee'));
    if (mounted) setState(() {});
  }

  Future<void> _edit([Map<String, dynamic>? z]) async {
    final f = await _form(context, z == null ? 'New delivery area' : 'Delivery area', [
      ('name', 'Name (e.g. Bangsar)', (z?['name'] ?? '') as String, null),
      ('postcodes', 'Postcodes, comma separated (empty = any)', ((z?['postcodes'] as List?) ?? const []).join(', '), null),
      ('fee', 'Delivery fee', '${z?['fee'] ?? 0}', _num),
      ('min', 'Minimum order', '${z?['min_order'] ?? 0}', _num),
    ], delete: z == null ? null : 'Delete');
    if (f == null || !mounted) return;
    await _run(context, () async {
      if (f['__delete'] != null) {
        await _s.db.from('delivery_zones').delete().eq('id', z!['id']);
        return;
      }
      final data = {
        'name': f['name'],
        'postcodes': [for (final p in f['postcodes']!.split(RegExp(r'[,\s]+'))) if (p.trim().isNotEmpty) p.trim()],
        'fee': double.tryParse(f['fee']!) ?? 0,
        'min_order': double.tryParse(f['min']!) ?? 0,
      };
      if (z == null) {
        await _s.db.from('delivery_zones').insert({...data, 'tenant_id': _s.tenantId, 'outlet_id': _s.outlet!.id});
      } else {
        await _s.db.from('delivery_zones').update(data).eq('id', z['id']);
      }
    });
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Delivery areas')),
        floatingActionButton: FloatingActionButton(heroTag: null, onPressed: () => _edit(), child: const Icon(Icons.add)),
        body: ListView(children: [
          for (final z in _rows)
            ListTile(
              title: Text('${z['name']}'),
              subtitle: Text('Fee ${Orders.money.format(z['fee'])} · min ${Orders.money.format(z['min_order'])} · '
                  '${(z['postcodes'] as List).isEmpty ? 'any postcode' : (z['postcodes'] as List).join(', ')}'),
              onTap: () => _edit(z),
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Riders are staff with the Driver role (invite them in More → Team & access). '
                'For GrabFood / foodpanda / ShopeeFood orders, add them as "App" orders with their order number.', style: TextStyle(fontSize: 12)),
          ),
        ]),
      );
}

// ───────────────────────── Services & resources ─────────────────────────

class _ServicesPage extends StatefulWidget {
  const _ServicesPage();
  @override
  State<_ServicesPage> createState() => _ServicesPageState();
}

class _ServicesPageState extends State<_ServicesPage> {
  List<Map<String, dynamic>> _services = [], _resources = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _services = List<Map<String, dynamic>>.from(await _s.db.from('booking_services').select().eq('tenant_id', _s.tenantId!).order('name'));
    _resources = List<Map<String, dynamic>>.from(await _s.db.from('booking_resources').select('*, resource_services(service_id)').eq('tenant_id', _s.tenantId!).order('name'));
    if (mounted) setState(() {});
  }

  Future<void> _service([Map<String, dynamic>? v]) async {
    final f = await _form(context, v == null ? 'New service' : 'Service', [
      ('name', 'Name (Haircut, Massage 60 min…)', (v?['name'] ?? '') as String, null),
      ('minutes', 'Duration (minutes)', '${v?['duration_minutes'] ?? 30}', TextInputType.number),
      ('buffer', 'Clean-up time after (minutes)', '${v?['buffer_minutes'] ?? 0}', TextInputType.number),
      ('price', 'Price', '${v?['price'] ?? 0}', _num),
      ('desc', 'Description (shown online)', (v?['description'] ?? '') as String, null),
    ], delete: v == null ? null : 'Stop offering');
    if (f == null || !mounted) return;
    await _run(context, () async {
      if (f['__delete'] != null) {
        await _s.db.from('booking_services').update({'active': false}).eq('id', v!['id']);
        return;
      }
      final data = {
        'name': f['name'],
        'duration_minutes': int.tryParse(f['minutes']!) ?? 30,
        'buffer_minutes': int.tryParse(f['buffer']!) ?? 0,
        'price': double.tryParse(f['price']!) ?? 0,
        'description': f['desc']!.isEmpty ? null : f['desc'],
        'active': true,
      };
      if (v == null) {
        await _s.db.from('booking_services').insert({...data, 'tenant_id': _s.tenantId});
      } else {
        await _s.db.from('booking_services').update(data).eq('id', v['id']);
      }
    });
    _load();
  }

  Future<void> _resource([Map<String, dynamic>? r]) async {
    final name = TextEditingController(text: (r?['name'] ?? '') as String);
    String kind = (r?['kind'] ?? 'staff') as String;
    final offers = {for (final x in (r?['resource_services'] as List? ?? const [])) x['service_id'] as String};
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => StatefulBuilder(
        builder: (context, set) => Scaffold(
          appBar: AppBar(title: Text(r == null ? 'New staff / room' : '${r['name']}'), actions: [TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save'))]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (e.g. Aina, Room 2, Court A)')),
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'staff', label: Text('Person')), ButtonSegment(value: 'room', label: Text('Room')), ButtonSegment(value: 'equipment', label: Text('Equipment'))],
              selected: {kind},
              onSelectionChanged: (v) => set(() => kind = v.first),
            ),
            const SizedBox(height: 8),
            const Text('Offers these services:'),
            for (final s in _services.where((s) => s['active'] == true))
              CheckboxListTile(
                value: offers.contains(s['id']),
                title: Text('${s['name']}'),
                onChanged: (v) => set(() => v == true ? offers.add(s['id'] as String) : offers.remove(s['id'])),
              ),
          ]),
        ),
      ),
    ));
    if (ok != true || name.text.trim().isEmpty || !mounted) return;
    await _run(context, () async {
      String id;
      if (r == null) {
        id = (await _s.db.from('booking_resources').insert({'tenant_id': _s.tenantId, 'outlet_id': _s.outlet!.id, 'name': name.text.trim(), 'kind': kind}).select('id').single())['id'] as String;
      } else {
        id = r['id'] as String;
        await _s.db.from('booking_resources').update({'name': name.text.trim(), 'kind': kind}).eq('id', id);
      }
      await _s.db.from('resource_services').delete().eq('resource_id', id);
      if (offers.isNotEmpty) {
        await _s.db.from('resource_services').insert([for (final sid in offers) {'tenant_id': _s.tenantId, 'resource_id': id, 'service_id': sid}]);
      }
    });
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Services, staff & rooms')),
        body: ListView(children: [
          ListTile(
            title: Text('Services', style: Theme.of(context).textTheme.titleMedium),
            trailing: TextButton.icon(onPressed: () => _service(), icon: const Icon(Icons.add), label: const Text('Service')),
          ),
          for (final v in _services.where((s) => s['active'] == true))
            ListTile(
              title: Text('${v['name']}'),
              subtitle: Text('${v['duration_minutes']} min${(v['buffer_minutes'] as int) > 0 ? ' + ${v['buffer_minutes']} min' : ''} · ${Orders.money.format(v['price'])}'),
              onTap: () => _service(v),
            ),
          const Divider(),
          ListTile(
            title: Text('Staff & rooms', style: Theme.of(context).textTheme.titleMedium),
            subtitle: const Text('Each can only have one booking at a time'),
            trailing: TextButton.icon(onPressed: _s.outlet == null ? null : () => _resource(), icon: const Icon(Icons.add), label: const Text('Add')),
          ),
          for (final r in _resources)
            ListTile(
              leading: Icon(r['kind'] == 'staff' ? Icons.person_outline : r['kind'] == 'room' ? Icons.meeting_room_outlined : Icons.build_outlined),
              title: Text('${r['name']}'),
              subtitle: Text(_services.where((s) => (r['resource_services'] as List).any((x) => x['service_id'] == s['id'])).map((s) => s['name']).join(', ')),
              onTap: () => _resource(r),
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Table bookings use your tables (Areas & tables). Set opening hours so customers see free times.', style: TextStyle(fontSize: 12)),
          ),
        ]),
      );
}

// ───────────────────────── Online shop sync ─────────────────────────

class _ShopPage extends StatefulWidget {
  const _ShopPage();
  @override
  State<_ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends State<_ShopPage> {
  List<Map<String, dynamic>> _channels = [];
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _channels = List<Map<String, dynamic>>.from(await _s.db.from('shop_channels').select().eq('tenant_id', _s.tenantId!));
    if (mounted) setState(() {});
  }

  Future<void> _connect(String provider) async {
    final shopify = provider == 'shopify';
    final f = await _form(context, shopify ? 'Connect Shopify' : 'Connect WooCommerce', shopify
        ? [
            ('shop_domain', 'Shop address (your-shop.myshopify.com)', '', TextInputType.url),
            ('access_token', 'Admin API access token (shpat_…)', '', null),
            ('location_id', 'Location ID (optional, gid://shopify/Location/…)', '', null),
          ]
        : [
            ('base_url', 'Shop address (https://…)', 'https://', TextInputType.url),
            ('consumer_key', 'Consumer key (ck_…)', '', null),
            ('consumer_secret', 'Consumer secret (cs_…)', '', null),
          ]);
    if (f == null || _s.outlet == null || !mounted) return;
    f.removeWhere((k, v) => v.isEmpty);
    if (shopify) f['shop_domain'] = (f['shop_domain'] ?? '').toLowerCase().replaceAll(RegExp(r'^https?://'), '').replaceAll('/', '');
    await _run(context, () async => _s.db.rpc('set_shop_secret', params: {'p_tenant': _s.tenantId, 'p_provider': provider, 'p_config': f, 'p_outlet': _s.outlet!.id}),
        'Connected — stock comes from ${_s.outlet!.name}');
    _load();
  }

  Future<void> _sync() async {
    setState(() => _syncing = true);
    try {
      final r = await _s.db.functions.invoke('shop-sync', body: {'tenant_id': _s.tenantId, 'remap': true});
      final res = (r.data as Map?)?['results'] as List? ?? const [];
      if (mounted) {
        _snack(context, res.isEmpty
            ? 'Nothing to sync'
            : res.map((x) => '${x['provider']}: ${x['linked']} linked, ${x['imported']} orders, ${x['pushed']} stock updates${x['error'] != null ? ' — ${x['error']}' : ''}').join('\n'));
      }
    } catch (e) {
      if (mounted) _snack(context, Orders.errorText(e));
    }
    if (mounted) setState(() => _syncing = false);
    _load();
  }

  Future<void> _toggle(Map<String, dynamic> c, String k, bool v) async {
    await _run(context, () async => _s.db.from('shop_channels').update({k: v}).eq('tenant_id', _s.tenantId!).eq('provider', c['provider']));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final has = {for (final c in _channels) c['provider']};
    return Scaffold(
      appBar: AppBar(title: const Text('Online shop sync'), actions: [
        if (_channels.isNotEmpty)
          TextButton(onPressed: _syncing ? null : _sync, child: Text(_syncing ? 'Syncing…' : 'Sync now')),
      ]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        const Text('Products are matched by SKU. Shop orders arrive in Orders as "New" (marked paid when paid online); '
            'stock you have at the chosen outlet, minus what open orders already promise, is sent to the shop. '
            'The sync runs every 5 minutes once set up on the server (see README).', style: TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        for (final c in _channels)
          Card(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ListTile(
                leading: Icon(c['enabled'] == true ? Icons.cloud_done_outlined : Icons.cloud_off_outlined),
                title: Text(c['provider'] == 'shopify' ? 'Shopify' : 'WooCommerce'),
                subtitle: Text([
                  c['last_sync_at'] == null ? 'Not synced yet' : 'Last sync ${Orders.time(c['last_sync_at'])}',
                  if ((c['stats'] as Map?)?.isNotEmpty == true)
                    '${c['stats']['linked'] ?? 0} linked · ${c['stats']['imported'] ?? 0} orders · ${c['stats']['pushed'] ?? 0} stock updates',
                  if (c['last_error'] != null) '⚠ ${c['last_error']}',
                ].join('\n')),
                isThreeLine: true,
              ),
              SwitchListTile(title: const Text('Sync on'), value: c['enabled'] == true, onChanged: (v) => _toggle(c, 'enabled', v)),
              SwitchListTile(title: const Text('Import orders'), value: c['import_orders'] == true, onChanged: (v) => _toggle(c, 'import_orders', v)),
              SwitchListTile(title: const Text('Send stock levels'), value: c['push_stock'] == true, onChanged: (v) => _toggle(c, 'push_stock', v)),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => _connect(c['provider'] as String), child: const Text('Change keys / outlet')),
              ),
            ]),
          ),
        if (!has.contains('shopify'))
          OutlinedButton.icon(onPressed: () => _connect('shopify'), icon: const Icon(Icons.add), label: const Text('Connect Shopify')),
        if (!has.contains('woocommerce'))
          OutlinedButton.icon(onPressed: () => _connect('woocommerce'), icon: const Icon(Icons.add), label: const Text('Connect WooCommerce')),
        const SizedBox(height: 12),
        const Text('Shopify: Settings → Apps → Develop apps → create an app with read_orders, read_customers, read_products, read_inventory, '
            'write_inventory and read_locations; install it and copy the Admin API access token.\n'
            'WooCommerce: WooCommerce → Settings → Advanced → REST API → add a key with Read/Write.', style: TextStyle(fontSize: 12)),
      ]),
    );
  }
}
