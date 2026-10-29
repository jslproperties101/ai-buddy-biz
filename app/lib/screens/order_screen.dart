import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../services/orders.dart';
import '../services/printing_service.dart';
import '../services/session.dart';
import 'pos_screen.dart' show PayResult, PaySheet;

/// One order: items by status, add from the menu, send to kitchen, void, move table, rider, checkout.
class OrderScreen extends StatefulWidget {
  final String orderId;
  const OrderScreen({super.key, required this.orderId});
  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  Map<String, dynamic>? _o;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _busy = false;
  AppSession get _s => AppSession.instance;

  String get _status => (_o?['status'] ?? '') as String;
  bool get _active => const ['pending', 'open', 'ready', 'out_for_delivery', 'delivered'].contains(_status);
  bool get _editable => const ['pending', 'open', 'ready'].contains(_status);

  @override
  void initState() {
    super.initState();
    Orders.settings();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        _s.db.from('orders').select('*, dining_tables(name)').eq('id', widget.orderId).single(),
        _s.db.from('order_items').select().eq('order_id', widget.orderId).order('created_at'),
      ]);
      _o = Map<String, dynamic>.from(r[0] as Map);
      _items = List<Map<String, dynamic>>.from(r[1] as List);
    } catch (e) {
      _snack(Orders.errorText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<dynamic> _rpc(String fn, Map<String, dynamic> params, [String? ok]) async {
    setState(() => _busy = true);
    dynamic res;
    try {
      res = await _s.db.rpc(fn, params: params);
      if (ok != null) _snack(ok);
    } catch (e) {
      _snack(Orders.errorText(e));
    }
    await _load();
    if (mounted) setState(() => _busy = false);
    return res;
  }

  Future<String?> _ask(String title, String label) async {
    final t = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(controller: t, autofocus: true, decoration: InputDecoration(labelText: label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('OK')),
        ],
      ),
    );
    return ok == true && t.text.trim().isNotEmpty ? t.text.trim() : null;
  }

  Future<void> _addItems() async {
    final picked = await Navigator.of(context).push<List<Map<String, dynamic>>>(MaterialPageRoute(builder: (_) => const MenuPickerScreen()));
    if (picked == null || picked.isEmpty) return;
    await _rpc('add_order_items', {'p_order': widget.orderId, 'p_items': picked}, 'Added ${picked.length} item(s)');
  }

  Future<void> _itemActions(Map<String, dynamic> i) async {
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('${_qty(i['qty'])}× ${i['name']}'), subtitle: Text(_mods(i))),
          if (i['status'] == 'ready')
            ListTile(leading: const Icon(Icons.room_service_outlined), title: const Text('Served'), onTap: () => Navigator.pop(context, 'served')),
          if (_editable && i['status'] != 'void')
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: Text(i['status'] == 'new' ? 'Remove' : 'Void (manager)'),
              onTap: () => Navigator.pop(context, 'void'),
            ),
        ]),
      ),
    );
    if (a == 'served') {
      await _rpc('set_items_status', {'p_items': [i['id']], 'p_status': 'served'});
    } else if (a == 'void') {
      String? reason = 'not sent';
      if (i['status'] != 'new') reason = await _ask('Void item', 'Reason (e.g. customer changed mind)');
      if (reason == null) return;
      await _rpc('void_order_item', {'p_item': i['id'], 'p_reason': reason});
    }
  }

  Future<void> _moveTable() async {
    final tables = await _s.db
        .from('dining_tables')
        .select('id, name, seats, orders(id, status)')
        .eq('outlet_id', _o!['outlet_id'])
        .eq('active', true)
        .order('sort_order')
        .order('name');
    if (!mounted) return;
    final free = [
      for (final t in tables)
        if (!((t['orders'] as List? ?? const []).any((o) => const ['pending', 'open', 'ready'].contains(o['status'])))) t
    ];
    final id = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Move to a free table')),
          for (final t in free) ListTile(title: Text('${t['name']}'), subtitle: Text('${t['seats']} seats'), onTap: () => Navigator.pop(context, t['id'] as String)),
          if (free.isEmpty) const ListTile(title: Text('No free tables')),
        ]),
      ),
    );
    if (id != null) await _rpc('move_order_table', {'p_order': widget.orderId, 'p_table': id}, 'Moved');
  }

  Future<void> _assignRider() async {
    List list = [];
    try {
      list = await _s.db.rpc('order_riders', params: {'p_tenant': _s.tenantId}) as List;
    } catch (e) {
      _snack(Orders.errorText(e));
    }
    if (!mounted) return;
    final id = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Assign a rider')),
          for (final m in list) ListTile(leading: const Icon(Icons.delivery_dining), title: Text('${m['name']}'), onTap: () => Navigator.pop(context, m['user_id'] as String)),
          if (list.isEmpty) const ListTile(title: Text('No riders yet — invite someone with the Driver role in More → Team & access')),
        ]),
      ),
    );
    if (id != null) await _rpc('assign_rider', {'p_order': widget.orderId, 'p_rider': id}, 'Rider assigned');
  }

  Future<void> _editCustomer() async {
    final o = _o!;
    final name = TextEditingController(text: (o['customer_name'] ?? '') as String);
    final phone = TextEditingController(text: (o['customer_phone'] ?? '') as String);
    final notes = TextEditingController(text: (o['notes'] ?? '') as String);
    final guests = TextEditingController(text: o['guests']?.toString() ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Order details'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Customer name')),
            TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
            if (o['channel'] == 'dine_in') TextField(controller: guests, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Guests')),
            TextField(controller: notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _s.db.from('orders').update({
        'customer_name': name.text.trim().isEmpty ? null : name.text.trim(),
        'customer_phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
        'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
        'guests': int.tryParse(guests.text),
      }).eq('id', widget.orderId);
    } catch (e) {
      _snack(Orders.errorText(e));
    }
    _load();
  }

  Future<void> _bill() async {
    try {
      final q = Map<String, dynamic>.from(await _s.db.rpc('order_quote', params: {'p_order': widget.orderId}) as Map);
      await PrintingService.printOrderBill(order: _o!, quote: q);
    } catch (e) {
      _snack(Orders.errorText(e));
    }
  }

  Future<void> _checkout() async {
    Map<String, dynamic> q;
    try {
      q = Map<String, dynamic>.from(await _s.db.rpc('order_quote', params: {'p_order': widget.orderId}) as Map);
    } catch (e) {
      return _snack(Orders.errorText(e));
    }
    if ((q['unlinked_items'] as num) > 0) {
      return _snack('Some online items aren\'t linked to your products. Add products with the same SKU, then sync again.');
    }
    if (_items.any((i) => i['status'] == 'new')) return _snack('Send or remove the items not yet sent to the kitchen');
    if (!mounted) return;
    final total = (q['total'] as num).toDouble();
    List<Map<String, dynamic>> payments;
    String paidLabel;
    double paid;
    if (_o!['prepaid'] == true) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Paid online'),
          content: Text('This order was paid on ${Orders.marketplaces[_o!['external_provider']] ?? 'the website'}'
              '${_o!['prepaid_amount'] != null ? ' (${Orders.money.format(_o!['prepaid_amount'])})' : ''}. '
              'Close it and record ${Orders.money.format(total)} as paid online?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Complete')),
          ],
        ),
      );
      if (ok != true) return;
      payments = [{'method': 'other', 'amount': total, 'reference': '${_o!['external_provider'] ?? 'online'} ${_o!['external_ref'] ?? ''}'.trim()}];
      paidLabel = 'online';
      paid = total;
    } else {
      final r = await showModalBottomSheet<PayResult>(
        context: context,
        isScrollControlled: true,
        builder: (_) => PaySheet(total: total, money: Orders.money),
      );
      if (r == null) return;
      payments = [{'method': r.method, 'amount': r.amount}];
      paidLabel = r.method;
      paid = r.amount;
      if (r.change > 0 && mounted) {
        await showDialog(
            context: context,
            builder: (_) => AlertDialog(
                  title: Text('Change ${Orders.money.format(r.change)}'),
                  actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
                ));
      }
    }
    final res = await _rpc('checkout_order', {
      'p_order': widget.orderId,
      'p_payments': payments,
      'p_shift': _s.openShiftId,
      'p_client_sale_id': const Uuid().v4(),
    });
    if (res is Map && mounted) {
      final lines = [for (final l in q['lines'] as List) ('${l['name']}', (l['qty'] as num).toDouble(), (l['unit_price'] as num).toDouble(), 0.0)];
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Paid · receipt ${res['receipt_no']}'),
        action: SnackBarAction(
          label: 'Receipt',
          onPressed: () => PrintingService.printReceipt(
            receiptNo: '${res['receipt_no']}',
            lines: lines,
            subtotal: (q['subtotal'] as num).toDouble(),
            discount: 0,
            tax: (q['tax'] as num).toDouble(),
            total: (res['total'] as num).toDouble(),
            paidMethod: paidLabel,
            paid: paid,
          ),
        ),
      ));
    }
  }

  static String _qty(dynamic q) {
    final d = (q as num).toDouble();
    return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
  }

  static String _mods(Map<String, dynamic> i) => [
        for (final m in (i['modifiers'] as List? ?? const [])) m['name'],
        if (i['note'] != null) '“${i['note']}”',
      ].join(', ');

  @override
  Widget build(BuildContext context) {
    if (_loading) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final o = _o;
    if (o == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Order not found')));
    final cs = Theme.of(context).colorScheme;
    final newItems = _items.where((i) => i['status'] == 'new').toList();
    final table = (o['dining_tables'] as Map?)?['name'];
    final track = Orders.webPage('order.html', 'o=${o['track_token']}');
    final delivery = o['fulfilment'] == 'delivery';
    final menu = <(String, String)>[
      if (_editable) ('customer', 'Customer & notes'),
      if (_editable && o['channel'] == 'dine_in') ('move', 'Move table'),
      if (_active && delivery && _s.can('ord.take')) ('rider', 'Assign rider'),
      if (track != null) ('track', 'Copy tracking link'),
      if (_active) ('bill', 'Print bill'),
      if (_active && _s.can('ord.take')) ('cancel', 'Cancel order'),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text('${o['order_no']}${table != null ? ' · $table' : ''}'),
        actions: [
          PopupMenuButton<String>(
            itemBuilder: (_) => [for (final m in menu) PopupMenuItem(value: m.$1, child: Text(m.$2))],
            onSelected: (v) async {
              switch (v) {
                case 'customer':
                  await _editCustomer();
                case 'move':
                  await _moveTable();
                case 'rider':
                  await _assignRider();
                case 'track':
                  await Clipboard.setData(ClipboardData(text: track!));
                  _snack('Tracking link copied');
                case 'bill':
                  await _bill();
                case 'cancel':
                  final r = await _ask('Cancel order', 'Reason');
                  if (r != null) await _rpc('cancel_order', {'p_order': widget.orderId, 'p_reason': r}, 'Order cancelled');
              }
            },
          ),
        ],
        bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator()) : null,
      ),
      floatingActionButton: _editable && _s.can('ord.take')
          ? FloatingActionButton.extended(heroTag: null, onPressed: _busy ? null : _addItems, icon: const Icon(Icons.add), label: const Text('Items'))
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.only(bottom: 160), children: [
          ListTile(
            title: Text('${Orders.channelLabels[o['channel']] ?? o['channel']}'
                '${o['external_provider'] != null ? ' · ${Orders.marketplaces[o['external_provider']] ?? o['external_provider']} ${o['external_ref'] ?? ''}' : ''}'
                '${o['source'] == 'qr' ? ' · ordered by QR' : o['source'] == 'web' ? ' · ordered online' : ''}'),
            subtitle: Text([
              Orders.statusLabels[_status] ?? _status,
              'opened ${Orders.time(o['created_at'])}',
              if (o['guests'] != null) '${o['guests']} guests',
              if (o['customer_name'] != null) '${o['customer_name']}',
              if (o['customer_phone'] != null) '${o['customer_phone']}',
              if (o['scheduled_for'] != null) 'for ${Orders.time(o['scheduled_for'])}',
              if (o['prepaid'] == true) 'PAID ONLINE',
            ].join(' · ')),
          ),
          if (o['notes'] != null) ListTile(dense: true, leading: const Icon(Icons.sticky_note_2_outlined), title: Text('${o['notes']}')),
          if (delivery)
            ListTile(
              dense: true,
              leading: const Icon(Icons.location_on_outlined),
              title: Text('${o['delivery_address'] ?? ''} ${o['delivery_postcode'] ?? ''}'),
              subtitle: Text(o['rider_id'] == null ? 'No rider yet' : 'Rider assigned'),
            ),
          if (_status == 'pending')
            Card(
              color: cs.tertiaryContainer,
              margin: const EdgeInsets.all(12),
              child: ListTile(
                title: const Text('New order waiting'),
                subtitle: const Text('Accept to send it to the kitchen, or cancel with a reason (the customer is told).'),
                trailing: FilledButton(
                  onPressed: _busy ? null : () => _rpc('send_order', {'p_order': widget.orderId}, 'Accepted & sent to kitchen'),
                  child: const Text('Accept'),
                ),
              ),
            ),
          const Divider(),
          for (final i in _items)
            ListTile(
              dense: true,
              leading: _statusIcon(i['status'] as String, cs),
              title: Text('${_qty(i['qty'])}× ${i['name']}',
                  style: i['status'] == 'void' ? TextStyle(decoration: TextDecoration.lineThrough, color: cs.outline) : null),
              subtitle: _mods(i).isEmpty && i['void_reason'] == null
                  ? null
                  : Text([if (_mods(i).isNotEmpty) _mods(i), if (i['void_reason'] != null) 'void: ${i['void_reason']}'].join(' · ')),
              trailing: Text(Orders.money.format((i['qty'] as num) * ((i['unit_price'] as num) + (i['modifiers_total'] as num)))),
              onTap: _active ? () => _itemActions(i) : null,
            ),
          if (_items.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No items yet — tap + Items.', textAlign: TextAlign.center)),
          const Divider(),
          ListTile(
            title: const Text('Items total'),
            trailing: Text(Orders.money.format(o['items_total']), style: Theme.of(context).textTheme.titleMedium),
            subtitle: Text([
              if ((o['service_charge_pct'] as num) > 0) '+ service charge ${o['service_charge_pct']}%',
              if ((o['delivery_fee'] as num) > 0) '+ delivery ${Orders.money.format(o['delivery_fee'])}',
              '+ tax at checkout',
            ].join(' · ')),
          ),
        ]),
      ),
      bottomNavigationBar: !_active
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(children: [
                  if (newItems.isNotEmpty && _status != 'pending')
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _busy ? null : () => _rpc('send_order', {'p_order': widget.orderId}, 'Sent to kitchen'),
                        icon: const Icon(Icons.send),
                        label: Text('Send ${newItems.length}'),
                      ),
                    ),
                  if (delivery && (_status == 'open' || _status == 'ready')) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : () => _rpc('delivery_update', {'p_order': widget.orderId, 'p_status': 'out_for_delivery'}, 'Out for delivery'),
                        child: const Text('Dispatch'),
                      ),
                    ),
                  ],
                  if (_s.can('pos.sale.create') && _status != 'pending') ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy || _items.isEmpty ? null : _checkout,
                        icon: const Icon(Icons.point_of_sale),
                        label: Text(o['prepaid'] == true ? 'Complete' : 'Pay'),
                      ),
                    ),
                  ],
                ]),
              ),
            ),
    );
  }

  Widget _statusIcon(String st, ColorScheme cs) => switch (st) {
        'new' => Tooltip(message: 'Not sent yet', child: Icon(Icons.edit_note, color: cs.primary)),
        'sent' => const Tooltip(message: 'Sent to kitchen', child: Icon(Icons.outbox_outlined)),
        'preparing' => Tooltip(message: 'Preparing', child: Icon(Icons.local_fire_department_outlined, color: Colors.orange.shade800)),
        'ready' => Tooltip(message: 'Ready to serve', child: Icon(Icons.notifications_active_outlined, color: Colors.green.shade700)),
        'served' => Tooltip(message: 'Served', child: Icon(Icons.check, color: cs.outline)),
        _ => Tooltip(message: 'Void', child: Icon(Icons.block, color: cs.outline)),
      };
}

/// Pick menu items with their options; returns the payload for add_order_items.
class MenuPickerScreen extends StatefulWidget {
  const MenuPickerScreen({super.key});
  @override
  State<MenuPickerScreen> createState() => _MenuPickerScreenState();
}

class _MenuPickerScreenState extends State<MenuPickerScreen> {
  List<MenuItem> _menu = [];
  final List<(MenuItem, int, List<(String, String, double)>, String?)> _picked = [];
  String? _cat;
  String _q = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    try {
      _menu = await Orders.menu(refresh: refresh);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Orders.errorText(e))));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pick(MenuItem m) async {
    if (m.soldOut) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${m.name} is sold out')));
      return;
    }
    if (m.groups.isEmpty) {
      setState(() => _picked.add((m, 1, const [], null)));
      return;
    }
    final chosen = <String, Set<String>>{for (final g in m.groups) g.id: {}};
    final note = TextEditingController();
    int qty = 1;
    String? err;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
                Text(m.name, style: Theme.of(context).textTheme.titleLarge),
                for (final g in m.groups) ...[
                  const SizedBox(height: 8),
                  Text('${g.name} ${g.min > 0 ? '(choose ${g.min == g.max ? g.min : '${g.min}–${g.max}'})' : '(optional${g.max > 1 ? ', up to ${g.max}' : ''})'}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final o in g.options)
                      FilterChip(
                        label: Text('${o.$2}${o.$3 > 0 ? ' +${o.$3.toStringAsFixed(2)}' : ''}'),
                        selected: chosen[g.id]!.contains(o.$1),
                        onSelected: (v) => set(() {
                          if (g.max == 1) chosen[g.id]!.clear();
                          v ? chosen[g.id]!.add(o.$1) : chosen[g.id]!.remove(o.$1);
                        }),
                      ),
                  ]),
                ],
                TextField(controller: note, decoration: const InputDecoration(labelText: 'Note for the kitchen')),
                const SizedBox(height: 8),
                Row(children: [
                  IconButton(onPressed: () => set(() => qty = qty > 1 ? qty - 1 : 1), icon: const Icon(Icons.remove_circle_outline)),
                  Text('$qty', style: Theme.of(context).textTheme.titleLarge),
                  IconButton(onPressed: () => set(() => qty++), icon: const Icon(Icons.add_circle_outline)),
                  const Spacer(),
                  FilledButton(
                    onPressed: () {
                      for (final g in m.groups) {
                        final n = chosen[g.id]!.length;
                        if (n < g.min || n > g.max) {
                          set(() => err = 'Choose ${g.name}');
                          return;
                        }
                      }
                      Navigator.pop(context, true);
                    },
                    child: const Text('Add'),
                  ),
                ]),
                if (err != null) Text(err!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ]),
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    final opts = [for (final g in m.groups) for (final o in g.options) if (chosen[g.id]!.contains(o.$1)) o];
    setState(() => _picked.add((m, qty, opts, note.text.trim().isEmpty ? null : note.text.trim())));
  }

  double get _total => _picked.fold(0, (a, p) => a + p.$2 * (p.$1.price + p.$3.fold<double>(0, (b, o) => b + o.$3)));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cats = Orders.categories.where((c) => _menu.any((m) => m.categoryId == c['id'])).toList();
    final shown = _menu
        .where((m) => (_cat == null || m.categoryId == _cat) && (_q.isEmpty || m.name.toLowerCase().contains(_q.toLowerCase())))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Add items'), actions: [
        IconButton(tooltip: 'Refresh menu', onPressed: () => _load(refresh: true), icon: const Icon(Icons.refresh)),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: TextField(
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search', isDense: true),
                  onChanged: (v) => setState(() => _q = v),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(label: const Text('All'), selected: _cat == null, onSelected: (_) => setState(() => _cat = null)),
                  ),
                  for (final c in cats)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(label: Text('${c['name']}'), selected: _cat == c['id'], onSelected: (_) => setState(() => _cat = c['id'] as String)),
                    ),
                ]),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, childAspectRatio: 1.5, mainAxisSpacing: 6, crossAxisSpacing: 6),
                  itemCount: shown.length,
                  itemBuilder: (_, i) {
                    final m = shown[i];
                    final n = _picked.where((p) => p.$1.variantId == m.variantId).fold<int>(0, (a, p) => a + p.$2);
                    return Card(
                      margin: EdgeInsets.zero,
                      color: m.soldOut ? cs.surfaceContainerHighest : null,
                      child: InkWell(
                        onTap: () => _pick(m),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(child: Text(m.name, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                            Row(children: [
                              Text(m.soldOut ? 'Sold out' : Orders.money.format(m.price), style: TextStyle(color: m.soldOut ? cs.error : null, fontSize: 12)),
                              const Spacer(),
                              if (n > 0) CircleAvatar(radius: 11, child: Text('$n', style: const TextStyle(fontSize: 11))),
                            ]),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_picked.isNotEmpty)
                SizedBox(
                  height: 92,
                  child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
                    for (var i = 0; i < _picked.length; i++)
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: InputChip(
                          label: Text('${_picked[i].$2}× ${_picked[i].$1.name}${_picked[i].$3.isNotEmpty ? ' (${_picked[i].$3.map((o) => o.$2).join(', ')})' : ''}'),
                          onDeleted: () => setState(() => _picked.removeAt(i)),
                        ),
                      ),
                  ]),
                ),
            ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: _picked.isEmpty
                ? null
                : () => Navigator.pop(context, [
                      for (final p in _picked)
                        {
                          'variant_id': p.$1.variantId,
                          'qty': p.$2,
                          'modifier_ids': [for (final o in p.$3) o.$1],
                          if (p.$4 != null) 'note': p.$4,
                        }
                    ]),
            child: Text(_picked.isEmpty ? 'Tap items to add' : 'Add ${_picked.length} line(s) · ${Orders.money.format(_total)}'),
          ),
        ),
      ),
    );
  }
}
