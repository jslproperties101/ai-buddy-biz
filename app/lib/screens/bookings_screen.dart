import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../services/orders.dart';
import '../services/session.dart';
import 'order_screen.dart';
import 'pos_screen.dart' show PayResult, PaySheet;

/// Day view of table and service bookings, with new booking, seat/arrive, checkout, no-show and cancel.
class BookingsTab extends StatefulWidget {
  const BookingsTab({super.key});
  @override
  State<BookingsTab> createState() => _BookingsTabState();
}

class _BookingsTabState extends State<BookingsTab> with AutomaticKeepAliveClientMixin {
  DateTime _day = DateTime.now();
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  AppSession get _s => AppSession.instance;
  static final _dayFmt = DateFormat('EEE d MMM');

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final start = DateTime(_day.year, _day.month, _day.day);
    try {
      var q = _s.db
          .from('bookings')
          .select('*, booking_services(name, price), booking_resources(name), dining_tables(name)')
          .eq('tenant_id', _s.tenantId!)
          .gte('start_at', start.toUtc().toIso8601String())
          .lt('start_at', start.add(const Duration(days: 1)).toUtc().toIso8601String());
      if (_s.outlet != null) q = q.eq('outlet_id', _s.outlet!.id);
      _rows = List<Map<String, dynamic>>.from(await q.order('start_at'));
    } catch (e) {
      _snack(Orders.errorText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _actions(Map<String, dynamic> b) async {
    if (!_s.can('book.manage')) return;
    final st = b['status'] as String;
    final service = b['kind'] == 'service';
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text('${b['name']} · ${Orders.time(b['start_at'])}'),
            subtitle: Text([if (b['phone'] != null) b['phone'], if (b['notes'] != null) b['notes']].join('\n')),
          ),
          if (st == 'pending') ListTile(leading: const Icon(Icons.check), title: const Text('Confirm'), onTap: () => Navigator.pop(context, 'confirmed')),
          if (st == 'confirmed' || st == 'pending')
            ListTile(
              leading: const Icon(Icons.how_to_reg_outlined),
              title: Text(service ? 'Arrived' : 'Seat now (opens the table\'s order)'),
              onTap: () => Navigator.pop(context, 'arrived'),
            ),
          if (st == 'arrived' && service) ListTile(leading: const Icon(Icons.point_of_sale), title: const Text('Check out & pay'), onTap: () => Navigator.pop(context, 'pay')),
          if (st == 'arrived' && !service && b['order_id'] != null)
            ListTile(leading: const Icon(Icons.receipt_long_outlined), title: const Text('Open the table\'s order'), onTap: () => Navigator.pop(context, 'order')),
          if (st == 'arrived' && !service) ListTile(leading: const Icon(Icons.done_all), title: const Text('Mark completed'), onTap: () => Navigator.pop(context, 'completed')),
          if (st == 'confirmed' || st == 'pending')
            ListTile(leading: const Icon(Icons.person_off_outlined), title: const Text('No-show'), onTap: () => Navigator.pop(context, 'no_show')),
          if (st == 'confirmed' || st == 'pending' || st == 'arrived')
            ListTile(leading: const Icon(Icons.close), title: const Text('Cancel booking'), onTap: () => Navigator.pop(context, 'cancelled')),
        ]),
      ),
    );
    if (a == null || !mounted) return;
    if (a == 'pay') return _pay(b);
    if (a == 'order') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: b['order_id'] as String)));
      return _load();
    }
    try {
      final orderId = await _s.db.rpc('set_booking_status', params: {'p_booking': b['id'], 'p_status': a});
      if (a == 'arrived' && orderId is String && mounted) {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: orderId)));
      }
    } catch (e) {
      _snack(Orders.errorText(e));
    }
    _load();
  }

  Future<void> _pay(Map<String, dynamic> b) async {
    try {
      final q = Map<String, dynamic>.from(await _s.db.rpc('booking_quote', params: {'p_booking': b['id']}) as Map);
      if (!mounted) return;
      final r = await showModalBottomSheet<PayResult>(
        context: context,
        isScrollControlled: true,
        builder: (_) => PaySheet(total: (q['total'] as num).toDouble(), money: Orders.money),
      );
      if (r == null) return;
      final res = await _s.db.rpc('checkout_booking', params: {
        'p_booking': b['id'],
        'p_payments': [{'method': r.method, 'amount': r.amount}],
        'p_shift': _s.openShiftId,
        'p_client_sale_id': const Uuid().v4(),
      }) as Map;
      _snack('Paid · receipt ${res['receipt_no']}${r.change > 0 ? ' · change ${Orders.money.format(r.change)}' : ''}');
    } catch (e) {
      _snack(Orders.errorText(e));
    }
    _load();
  }

  Future<void> _new() async {
    final services = List<Map<String, dynamic>>.from(await _s.db.from('booking_services').select().eq('tenant_id', _s.tenantId!).eq('active', true).order('name'));
    if (!mounted) return;
    String kind = services.isEmpty ? 'table' : 'service';
    String? service = services.isEmpty ? null : services.first['id'] as String;
    DateTime day = _day;
    int party = 2;
    List<Map<String, dynamic>> slots = [];
    Map<String, dynamic>? slot;
    bool loadingSlots = false;
    bool started = false;
    final name = TextEditingController();
    final phone = TextEditingController();
    final notes = TextEditingController();

    Future<void> loadSlots(void Function(void Function()) set) async {
      set(() {
        loadingSlots = true;
        slot = null;
      });
      try {
        slots = List<Map<String, dynamic>>.from(await _s.db.rpc('booking_slots', params: {
          'p_outlet': _s.outlet!.id,
          'p_date': DateFormat('yyyy-MM-dd').format(day),
          'p_service': kind == 'service' ? service : null,
          'p_party': party,
        }) as List);
      } catch (e) {
        slots = [];
        _snack(Orders.errorText(e));
      }
      set(() => loadingSlots = false);
    }

    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => StatefulBuilder(builder: (context, set) {
        if (!started) {
          // first build: fetch the free times once
          started = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => loadSlots(set));
        }
        return Scaffold(
          appBar: AppBar(title: const Text('New booking'), actions: [
            TextButton(onPressed: slot == null ? null : () => Navigator.pop(context, true), child: const Text('Book')),
          ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            SegmentedButton<String>(
              segments: [
                if (services.isNotEmpty) const ButtonSegment(value: 'service', label: Text('Service / appointment')),
                const ButtonSegment(value: 'table', label: Text('Table')),
              ],
              selected: {kind},
              onSelectionChanged: (v) {
                set(() => kind = v.first);
                loadSlots(set);
              },
            ),
            if (kind == 'service')
              DropdownButtonFormField<String>(
                value: service,
                decoration: const InputDecoration(labelText: 'Service'),
                items: [for (final s in services) DropdownMenuItem(value: s['id'] as String, child: Text('${s['name']} · ${s['duration_minutes']} min'))],
                onChanged: (v) {
                  set(() => service = v);
                  loadSlots(set);
                },
              ),
            if (kind == 'table')
              Row(children: [
                const Text('Party size'),
                IconButton(
                    onPressed: () {
                      set(() => party = party > 1 ? party - 1 : 1);
                      loadSlots(set);
                    },
                    icon: const Icon(Icons.remove_circle_outline)),
                Text('$party', style: Theme.of(context).textTheme.titleLarge),
                IconButton(
                    onPressed: () {
                      set(() => party++);
                      loadSlots(set);
                    },
                    icon: const Icon(Icons.add_circle_outline)),
              ]),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_dayFmt.format(day)),
              trailing: const Icon(Icons.event),
              onTap: () async {
                final d = await showDatePicker(context: context, initialDate: day, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 365)));
                if (d != null) {
                  set(() => day = d);
                  loadSlots(set);
                }
              },
            ),
            if (loadingSlots) const LinearProgressIndicator(),
            if (!loadingSlots && slots.isEmpty) const Text('No free times — check opening hours, staff/rooms for this service, or tables (Settings).'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in slots)
                ChoiceChip(
                  label: Text(Orders.time(s['slot'])),
                  selected: slot == s,
                  onSelected: (_) => set(() => slot = s),
                ),
            ]),
            const SizedBox(height: 12),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone (gets a confirmation)')),
            TextField(controller: notes, decoration: const InputDecoration(labelText: 'Notes')),
          ]),
        );
      }),
    ));
    if (ok != true || slot == null) return;
    try {
      await _s.db.rpc('create_booking', params: {
        'p_outlet': _s.outlet!.id,
        'p_kind': kind,
        'p_start': slot!['slot'],
        'p_party': kind == 'table' ? party : 1,
        'p_name': name.text,
        'p_phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
        'p_service': kind == 'service' ? service : null,
        'p_resource': slot!['resource_id'],
        'p_table': slot!['table_id'],
        'p_notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
      });
      _snack('Booked');
      _day = day;
    } catch (e) {
      _snack(Orders.errorText(e));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: _s.can('book.manage') && _s.outlet != null
          ? FloatingActionButton.extended(heroTag: null, onPressed: _new, icon: const Icon(Icons.add), label: const Text('Booking'))
          : null,
      body: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () {
                _day = _day.subtract(const Duration(days: 1));
                _load();
              }),
          TextButton(
            onPressed: () {
              _day = DateTime.now();
              _load();
            },
            child: Text(_dayFmt.format(_day)),
          ),
          IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () {
                _day = _day.add(const Duration(days: 1));
                _load();
              }),
        ]),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _rows.isEmpty
                      ? ListView(children: const [Padding(padding: EdgeInsets.all(32), child: Text('No bookings this day.', textAlign: TextAlign.center))])
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 88),
                          itemCount: _rows.length,
                          itemBuilder: (_, i) {
                            final b = _rows[i];
                            final st = b['status'] as String;
                            final what = b['kind'] == 'service'
                                ? '${(b['booking_services'] as Map?)?['name'] ?? ''} · ${(b['booking_resources'] as Map?)?['name'] ?? ''}'
                                : 'Table ${(b['dining_tables'] as Map?)?['name'] ?? '(not set)'} · ${b['party_size']} people';
                            return ListTile(
                              leading: SizedBox(
                                width: 52,
                                child: Text(Orders.time(b['start_at']), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                              ),
                              title: Text('${b['name']}${b['source'] == 'web' ? ' 🌐' : ''}',
                                  style: st == 'cancelled' || st == 'no_show' ? TextStyle(decoration: TextDecoration.lineThrough, color: cs.outline) : null),
                              subtitle: Text('$what · until ${Orders.time(b['end_at'])}'),
                              trailing: Chip(
                                label: Text(const {
                                      'pending': 'Requested',
                                      'confirmed': 'Booked',
                                      'arrived': 'Here',
                                      'completed': 'Done',
                                      'no_show': 'No-show',
                                      'cancelled': 'Cancelled'
                                    }[st] ??
                                    st),
                                visualDensity: VisualDensity.compact,
                              ),
                              onTap: () => _actions(b),
                            );
                          },
                        ),
                ),
        ),
      ]),
    );
  }
}
