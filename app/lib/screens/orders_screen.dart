import 'dart:async';

import 'package:flutter/material.dart';

import '../services/orders.dart';
import '../services/session.dart';
import 'bookings_screen.dart';
import 'ext_settings_screen.dart';
import 'order_screen.dart';

/// Restaurant & orders: floor plan, order queue (takeaway, delivery, online, QR), kitchen display, bookings.
class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    final tabs = <(String, Widget)>[
      if (s.can('ord.view')) ('Floor', const _FloorTab()),
      if (s.can('ord.view')) ('Orders', const _QueueTab()),
      if (s.can('ord.view') || s.can('ord.kitchen')) ('Kitchen', const KitchenTab()),
      if (s.can('book.view') || s.can('book.manage')) ('Bookings', const BookingsTab()),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Column(children: [
        Row(children: [
          Expanded(child: TabBar(isScrollable: tabs.length > 3, tabs: [for (final t in tabs) Tab(text: t.$1)])),
          if (s.can('ord.settings'))
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.tune),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ExtSettingsScreen()));
                Orders.clearCache();
              },
            ),
        ]),
        Expanded(child: TabBarView(children: [for (final t in tabs) t.$2])),
      ]),
    );
  }
}

/// Polls every [seconds] while visible.
mixin _Polling<T extends StatefulWidget> on State<T> {
  Timer? _timer;
  Future<void> refresh();
  void startPolling(int seconds) {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (mounted && TickerMode.of(context)) refresh();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// ───────────────────────── Floor ─────────────────────────

class _FloorTab extends StatefulWidget {
  const _FloorTab();
  @override
  State<_FloorTab> createState() => _FloorTabState();
}

class _FloorTabState extends State<_FloorTab> with AutomaticKeepAliveClientMixin, _Polling {
  List<Map<String, dynamic>> _tables = [];
  List<Map<String, dynamic>> _areas = [];
  Map<String, Map<String, dynamic>> _open = {}; // table_id → order
  Map<String, int> _readyCount = {};
  Map<String, int> _newCount = {};
  bool _loading = true;
  Session get _s => Session.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    refresh();
    startPolling(20);
  }

  @override
  Future<void> refresh() async {
    final outlet = _s.outlet?.id;
    if (outlet == null) return;
    try {
      final r = await Future.wait([
        _s.db.from('dining_tables').select().eq('outlet_id', outlet).eq('active', true).order('sort_order').order('name'),
        _s.db.from('dining_areas').select().eq('outlet_id', outlet).order('sort_order'),
        _s.db
            .from('orders')
            .select('id, order_no, table_id, status, guests, created_at, items_total, source, order_items(status)')
            .eq('outlet_id', outlet)
            .not('table_id', 'is', null)
            .inFilter('status', ['pending', 'open', 'ready']),
      ]);
      _tables = List<Map<String, dynamic>>.from(r[0] as List);
      _areas = List<Map<String, dynamic>>.from(r[1] as List);
      _open = {for (final o in r[2] as List) (o as Map)['table_id'] as String: Map<String, dynamic>.from(o)};
      _readyCount = {
        for (final o in _open.values) o['table_id'] as String: (o['order_items'] as List).where((i) => i['status'] == 'ready').length
      };
      _newCount = {
        for (final o in _open.values) o['table_id'] as String: (o['order_items'] as List).where((i) => i['status'] == 'new').length
      };
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openTable(Map<String, dynamic> t) async {
    var id = _open[t['id']]?['id'] as String?;
    if (id == null) {
      if (!_s.can('ord.take')) return;
      final guests = await showDialog<int>(
        context: context,
        builder: (_) => SimpleDialog(
          title: Text('Seat ${t['name']} — how many guests?'),
          children: [
            Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
              for (var n = 1; n <= (t['seats'] as int) + 2; n++)
                ActionChip(label: Text('$n'), onPressed: () => Navigator.pop(context, n)),
            ]),
          ],
        ),
      );
      if (guests == null) return;
      try {
        id = await _s.db.rpc('open_order', params: {'p_outlet': _s.outlet!.id, 'p_channel': 'dine_in', 'p_table': t['id'], 'p_guests': guests}) as String;
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Orders.errorText(e))));
        return;
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: id!)));
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    final cs = Theme.of(context).colorScheme;
    if (_tables.isEmpty) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(24), child: Text('No tables yet. Add areas and tables in Settings (top right).', textAlign: TextAlign.center)),
      );
    }
    final groups = <(String, List<Map<String, dynamic>>)>[
      for (final a in _areas) ('${a['name']}', _tables.where((t) => t['area_id'] == a['id']).toList()),
      ('Other', _tables.where((t) => t['area_id'] == null || !_areas.any((a) => a['id'] == t['area_id'])).toList()),
    ].where((g) => g.$2.isNotEmpty).toList();
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Wrap(spacing: 12, children: [
          _legend(cs.surfaceContainerHighest, 'Free'),
          _legend(cs.primaryContainer, 'Seated'),
          _legend(cs.tertiaryContainer, 'QR order waiting'),
          _legend(Colors.green.shade200, 'Food ready'),
        ]),
        for (final g in groups) ...[
          Padding(padding: const EdgeInsets.fromLTRB(4, 16, 4, 8), child: Text(g.$1, style: Theme.of(context).textTheme.titleSmall)),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final t in g.$2)
              Builder(builder: (_) {
                final o = _open[t['id']];
                final ready = _readyCount[t['id']] ?? 0;
                final fresh = (_newCount[t['id']] ?? 0) > 0 && (o?['source'] == 'qr' || o?['status'] == 'pending');
                final color = o == null
                    ? cs.surfaceContainerHighest
                    : ready > 0
                        ? Colors.green.shade200
                        : fresh || o['status'] == 'pending'
                            ? cs.tertiaryContainer
                            : cs.primaryContainer;
                return SizedBox(
                  width: 104,
                  height: 92,
                  child: Material(
                    color: color,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _openTable(t),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${t['name']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87)),
                          Text(o == null ? '${t['seats']} seats' : '${o['guests'] ?? '?'} guests · ${Orders.minutesSince(o['created_at'])}m',
                              style: const TextStyle(fontSize: 12, color: Colors.black87)),
                          const Spacer(),
                          if (o != null)
                            Text(ready > 0 ? '$ready ready' : Orders.money.format(o['items_total']),
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black87)),
                        ]),
                      ),
                    ),
                  ),
                );
              }),
          ]),
        ],
      ]),
    );
  }

  Widget _legend(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 4),
        Text(t, style: const TextStyle(fontSize: 12)),
      ]);
}

// ───────────────────────── Order queue ─────────────────────────

class _QueueTab extends StatefulWidget {
  const _QueueTab();
  @override
  State<_QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<_QueueTab> with AutomaticKeepAliveClientMixin, _Polling {
  List<Map<String, dynamic>> _rows = [];
  String _filter = 'active';
  bool _loading = true;
  Session get _s => Session.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    refresh();
    startPolling(20);
  }

  @override
  Future<void> refresh() async {
    try {
      var q = _s.db
          .from('orders')
          .select('id, order_no, channel, source, status, customer_name, fulfilment, scheduled_for, created_at, items_total, '
              'external_provider, external_ref, prepaid, rider_id, dining_tables(name)')
          .eq('tenant_id', _s.tenantId!);
      if (_s.outlet != null) q = q.eq('outlet_id', _s.outlet!.id);
      q = switch (_filter) {
        'active' => q.inFilter('status', ['pending', 'open', 'ready', 'out_for_delivery', 'delivered']),
        'pending' => q.eq('status', 'pending'),
        'done' => q.inFilter('status', ['completed', 'cancelled']).gte('created_at', DateTime.now().subtract(const Duration(days: 2)).toUtc().toIso8601String()),
        _ => q,
      };
      _rows = List<Map<String, dynamic>>.from(await q.order('created_at', ascending: _filter != 'done').limit(150));
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _new() async {
    String channel = 'takeaway';
    final name = TextEditingController();
    final phone = TextEditingController();
    final addr = TextEditingController();
    final fee = TextEditingController(text: '0');
    final ref = TextEditingController();
    String provider = 'grabfood';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('New order'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'takeaway', label: Text('Takeaway')),
                  ButtonSegment(value: 'delivery', label: Text('Delivery')),
                  ButtonSegment(value: 'marketplace', label: Text('App')),
                ],
                selected: {channel},
                onSelectionChanged: (v) => set(() => channel = v.first),
              ),
              if (channel == 'marketplace') ...[
                DropdownButtonFormField<String>(
                  value: provider,
                  decoration: const InputDecoration(labelText: 'From'),
                  items: [for (final m in Orders.marketplaces.entries) if (!['shopify', 'woocommerce'].contains(m.key)) DropdownMenuItem(value: m.key, child: Text(m.value))],
                  onChanged: (v) => set(() => provider = v ?? 'other'),
                ),
                TextField(controller: ref, decoration: const InputDecoration(labelText: 'Their order number')),
              ],
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Customer name')),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
              if (channel == 'delivery') ...[
                TextField(controller: addr, maxLines: 2, decoration: const InputDecoration(labelText: 'Delivery address')),
                TextField(controller: fee, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Delivery fee')),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      final id = await _s.db.rpc('open_order', params: {
        'p_outlet': _s.outlet!.id,
        'p_channel': channel,
        'p_customer': {
          'name': name.text,
          'phone': phone.text,
          if (channel == 'delivery') 'address': addr.text,
          if (channel == 'delivery') 'delivery_fee': double.tryParse(fee.text) ?? 0,
          if (channel == 'marketplace') 'external_provider': provider,
          if (channel == 'marketplace') 'external_ref': ref.text.trim(),
        },
      }) as String;
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: id)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Orders.errorText(e))));
    }
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final pending = _rows.where((r) => r['status'] == 'pending').length;
    return Scaffold(
      floatingActionButton: _s.can('ord.take') && _s.outlet != null
          ? FloatingActionButton.extended(heroTag: null, onPressed: _new, icon: const Icon(Icons.add), label: const Text('Order'))
          : null,
      body: Column(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(children: [
            for (final f in [('active', 'Active'), ('pending', 'New${pending > 0 ? ' ($pending)' : ''}'), ('done', 'Last 2 days')])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(f.$2),
                  selected: _filter == f.$1,
                  onSelected: (_) {
                    setState(() => _filter = f.$1);
                    refresh();
                  },
                ),
              ),
          ]),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: refresh,
                  child: _rows.isEmpty
                      ? ListView(children: const [Padding(padding: EdgeInsets.all(32), child: Text('No orders here.', textAlign: TextAlign.center))])
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 88),
                          itemCount: _rows.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final o = _rows[i];
                            final table = (o['dining_tables'] as Map?)?['name'];
                            final st = o['status'] as String;
                            return ListTile(
                              tileColor: st == 'pending' ? cs.tertiaryContainer : null,
                              leading: CircleAvatar(child: Icon(switch (o['channel']) {
                                'dine_in' => Icons.table_restaurant_outlined,
                                'delivery' => Icons.delivery_dining,
                                'online' => o['fulfilment'] == 'shipping' ? Icons.local_shipping_outlined : Icons.language,
                                'marketplace' => Icons.storefront_outlined,
                                _ => Icons.shopping_bag_outlined,
                              }, size: 20)),
                              title: Text('${o['order_no']} · ${table != null ? 'Table $table' : (o['customer_name'] ?? Orders.channelLabels[o['channel']])}'),
                              subtitle: Text([
                                Orders.statusLabels[st] ?? st,
                                if (o['external_provider'] != null) '${Orders.marketplaces[o['external_provider']] ?? o['external_provider']} ${o['external_ref'] ?? ''}',
                                if (o['scheduled_for'] != null) 'for ${Orders.time(o['scheduled_for'])}' else '${Orders.minutesSince(o['created_at'])} min ago',
                                if (o['prepaid'] == true) 'paid',
                              ].join(' · ')),
                              trailing: Text(Orders.money.format(o['items_total'])),
                              onTap: () async {
                                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: o['id'] as String)));
                                refresh();
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

// ───────────────────────── Kitchen display ─────────────────────────

class KitchenTab extends StatefulWidget {
  const KitchenTab({super.key});
  @override
  State<KitchenTab> createState() => _KitchenTabState();
}

class _KitchenTabState extends State<KitchenTab> with AutomaticKeepAliveClientMixin, _Polling {
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _stations = [];
  String? _station;
  bool _showReady = false;
  bool _loading = true;
  Session get _s => Session.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    refresh();
    startPolling(10);
  }

  @override
  Future<void> refresh() async {
    try {
      final r = await Future.wait([
        _s.db
            .from('order_items')
            .select('id, order_id, name, qty, modifiers, note, course, status, sent_at, station_id, orders!inner(order_no, channel, outlet_id, scheduled_for, dining_tables(name))')
            .eq('tenant_id', _s.tenantId!)
            .inFilter('status', _showReady ? ['sent', 'preparing', 'ready'] : ['sent', 'preparing'])
            .order('sent_at'),
        _s.db.from('kitchen_stations').select().eq('tenant_id', _s.tenantId!).order('name'),
      ]);
      _items = [
        for (final i in r[0] as List)
          if (_s.outlet == null || (i as Map)['orders']['outlet_id'] == _s.outlet!.id) Map<String, dynamic>.from(i as Map)
      ];
      _stations = List<Map<String, dynamic>>.from(r[1] as List);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _set(List<String> ids, String status) async {
    try {
      await _s.db.rpc('set_items_status', params: {'p_items': ids, 'p_status': status});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Orders.errorText(e))));
    }
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    final cs = Theme.of(context).colorScheme;
    final shown = _items.where((i) => _station == null || i['station_id'] == _station).toList();
    final tickets = <String, List<Map<String, dynamic>>>{};
    for (final i in shown) {
      (tickets[i['order_id'] as String] ??= []).add(i);
    }
    final canBump = _s.can('ord.kitchen');
    return Column(children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          ChoiceChip(label: const Text('All stations'), selected: _station == null, onSelected: (_) => setState(() => _station = null)),
          for (final st in _stations)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: ChoiceChip(label: Text('${st['name']}'), selected: _station == st['id'], onSelected: (_) => setState(() => _station = st['id'] as String)),
            ),
          const SizedBox(width: 12),
          FilterChip(
            label: const Text('Show ready'),
            selected: _showReady,
            onSelected: (v) {
              setState(() => _showReady = v);
              refresh();
            },
          ),
        ]),
      ),
      Expanded(
        child: tickets.isEmpty
            ? const Center(child: Text('Nothing to cook 🎉'))
            : RefreshIndicator(
                onRefresh: refresh,
                child: GridView(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 320, mainAxisExtent: 300, mainAxisSpacing: 8, crossAxisSpacing: 8),
                  children: [
                    for (final t in tickets.entries)
                      Builder(builder: (_) {
                        final o = t.value.first['orders'] as Map;
                        final age = t.value.map((i) => Orders.minutesSince(i['sent_at'])).reduce((a, b) => a > b ? a : b);
                        final late = age >= 15;
                        final table = (o['dining_tables'] as Map?)?['name'];
                        return Card(
                          margin: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12), side: BorderSide(color: late ? cs.error : cs.outlineVariant, width: late ? 2 : 1)),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              color: late ? cs.errorContainer : cs.secondaryContainer,
                              child: Row(children: [
                                Expanded(
                                  child: Text('${o['order_no']} · ${table != null ? 'T $table' : Orders.channelLabels[o['channel']]}',
                                      style: const TextStyle(fontWeight: FontWeight.bold)),
                                ),
                                Text('${age}m'),
                              ]),
                            ),
                            Expanded(
                              child: ListView(padding: EdgeInsets.zero, children: [
                                for (final i in t.value)
                                  ListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    title: Text('${(i['qty'] as num) % 1 == 0 ? (i['qty'] as num).toInt() : i['qty']}× ${i['name']}',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            decoration: i['status'] == 'ready' ? TextDecoration.lineThrough : null)),
                                    subtitle: (i['modifiers'] as List).isEmpty && i['note'] == null
                                        ? null
                                        : Text([for (final m in i['modifiers'] as List) m['name'], if (i['note'] != null) '“${i['note']}”'].join(', '),
                                            style: TextStyle(color: cs.error)),
                                    trailing: Icon(
                                      i['status'] == 'preparing' ? Icons.local_fire_department : i['status'] == 'ready' ? Icons.check_circle : Icons.circle_outlined,
                                      color: i['status'] == 'preparing' ? Colors.orange.shade800 : i['status'] == 'ready' ? Colors.green.shade700 : null,
                                    ),
                                    onTap: !canBump
                                        ? null
                                        : () => _set([i['id'] as String], switch (i['status']) { 'sent' => 'preparing', 'preparing' => 'ready', _ => 'sent' }),
                                  ),
                              ]),
                            ),
                            if (canBump)
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: FilledButton(
                                  onPressed: t.value.every((i) => i['status'] == 'ready')
                                      ? null
                                      : () => _set([for (final i in t.value) if (i['status'] != 'ready') i['id'] as String], 'ready'),
                                  child: const Text('All ready'),
                                ),
                              ),
                          ]),
                        );
                      }),
                  ],
                ),
              ),
      ),
    ]);
  }
}

// ───────────────────────── Deliveries (riders) ─────────────────────────

class DeliveriesScreen extends StatefulWidget {
  const DeliveriesScreen({super.key});
  @override
  State<DeliveriesScreen> createState() => _DeliveriesScreenState();
}

class _DeliveriesScreenState extends State<DeliveriesScreen> with _Polling {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    refresh();
    startPolling(30);
  }

  @override
  Future<void> refresh() async {
    try {
      _rows = List<Map<String, dynamic>>.from(await _s.db
          .from('orders')
          .select('id, order_no, status, customer_name, customer_phone, delivery_address, delivery_postcode, notes, items_total, delivery_fee, prepaid, '
              'order_items(name, qty, status)')
          .eq('tenant_id', _s.tenantId!)
          .eq('rider_id', _s.db.auth.currentUser!.id)
          .inFilter('status', ['open', 'ready', 'out_for_delivery'])
          .order('created_at'));
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _update(String id, String status) async {
    try {
      await _s.db.rpc('delivery_update', params: {'p_order': id, 'p_status': status});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Orders.errorText(e))));
    }
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        if (_rows.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Text('No deliveries assigned to you right now.', textAlign: TextAlign.center)),
        for (final o in _rows)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${o['order_no']} · ${o['customer_name'] ?? ''}', style: Theme.of(context).textTheme.titleMedium),
                Text('${o['delivery_address'] ?? ''} ${o['delivery_postcode'] ?? ''}'),
                if (o['customer_phone'] != null) Text('📞 ${o['customer_phone']}'),
                if (o['notes'] != null) Text('Note: ${o['notes']}'),
                const SizedBox(height: 4),
                Text([for (final i in o['order_items'] as List) if (i['status'] != 'void') '${i['qty']}× ${i['name']}'].join(', '),
                    style: const TextStyle(fontSize: 13)),
                Text(o['prepaid'] == true ? 'Paid online' : 'Collect payment: about ${Orders.money.format((o['items_total'] as num) + (o['delivery_fee'] as num))} + tax',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Row(children: [
                  if (o['status'] != 'out_for_delivery')
                    Expanded(child: FilledButton(onPressed: () => _update(o['id'] as String, 'out_for_delivery'), child: const Text('Picked up — on my way'))),
                  if (o['status'] == 'out_for_delivery')
                    Expanded(child: FilledButton(onPressed: () => _update(o['id'] as String, 'delivered'), child: const Text('Delivered'))),
                ]),
              ]),
            ),
          ),
      ]),
    );
  }
}
