import 'package:flutter/material.dart';

import '../services/catalog.dart';
import '../services/sales_queue.dart';
import '../services/session.dart';
import 'invoices_screen.dart';
import 'more_screen.dart';
import 'pos_screen.dart';
import 'products_screen.dart';
import 'stock_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  int _pending = 0;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await Catalog.instance.loadCache();
    if (mounted) setState(() {});
    await _sync(silent: true);
  }

  Future<void> _sync({bool silent = false}) async {
    if (_syncing) return;
    setState(() => _syncing = true);
    var online = true;
    try {
      await Catalog.instance.refresh();
      await Session.instance.refreshTaxTable();
      await Session.instance.refreshShift();
    } catch (_) {
      online = false;
    }
    final sent = online ? await SalesQueue.instance.syncAll() : 0;
    _pending = (await SalesQueue.instance.pending()).length;
    if (!mounted) return;
    setState(() => _syncing = false);
    if (!silent || sent > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(!online
            ? 'Offline — using saved products. $_pending sale(s) waiting.'
            : sent > 0
                ? 'Synced $sent offline sale(s).'
                : 'Up to date.'),
      ));
    }
  }

  Future<void> _refreshPending() async {
    _pending = (await SalesQueue.instance.pending()).length;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    final tabs = <(String, IconData, Widget)>[
      if (s.can('pos.sale.create')) ('Sell', Icons.point_of_sale, PosScreen(onSaleDone: _refreshPending)),
      if (s.can('inv.product.view'))
        ('Products', Icons.inventory_2_outlined, ProductsScreen(onChanged: () => _sync(silent: true))),
      if (s.can('inv.product.view')) ('Stock', Icons.warehouse_outlined, const StockScreen()),
      if (s.can('fin.invoice.view')) ('Invoices', Icons.receipt_long_outlined, const InvoicesScreen()),
      ('More', Icons.menu, MoreScreen(onOutletChanged: () => _sync(silent: true))),
    ];
    if (_tab >= tabs.length) _tab = 0;

    final noShift = s.can('pos.shift.manage') && s.openShiftId == null && tabs[_tab].$1 == 'Sell';

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.tenantName, style: const TextStyle(fontSize: 18)),
          Text('${s.outlet?.name ?? '—'} · ${s.roleName}', style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: [
          IconButton(
            tooltip: 'Sync',
            onPressed: _syncing ? null : () => _sync(),
            icon: Badge(
              isLabelVisible: _pending > 0,
              label: Text('$_pending'),
              child: _syncing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
            ),
          ),
        ],
        bottom: noShift
            ? PreferredSize(
                preferredSize: const Size.fromHeight(36),
                child: Material(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  child: InkWell(
                    onTap: () => setState(() => _tab = tabs.length - 1),
                    child: const SizedBox(
                      height: 36,
                      child: Center(child: Text('No shift open — tap More → Shift to open one')),
                    ),
                  ),
                ),
              )
            : null,
      ),
      body: IndexedStack(index: _tab, children: [for (final t in tabs) t.$3]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) async {
          setState(() => _tab = i);
          if (tabs[i].$1 == 'Sell') {
            await Session.instance.refreshShift();
            if (mounted) setState(() {});
          }
        },
        destinations: [for (final t in tabs) NavigationDestination(icon: Icon(t.$2), label: t.$1)],
      ),
    );
  }
}
