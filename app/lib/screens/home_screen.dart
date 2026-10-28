import 'package:flutter/material.dart';

import '../services/catalog.dart';
import '../services/sales_queue.dart';
import '../services/session.dart';
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

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    final tabs = <(String, IconData, Widget)>[
      if (s.can('pos.sale.create')) ('Sell', Icons.point_of_sale, PosScreen(onSaleDone: () => _refreshPending())),
      if (s.can('inv.product.view')) ('Products', Icons.inventory_2_outlined, ProductsScreen(onChanged: () => _sync(silent: true))),
      if (s.can('inv.product.view')) ('Stock', Icons.warehouse_outlined, const StockScreen()),
    ];
    if (tabs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(s.tenantName)),
        body: const Center(child: Text('Your role has no POS or stock access yet. Ask the owner.')),
      );
    }
    if (_tab >= tabs.length) _tab = 0;

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
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'outlet') await _pickOutlet();
              if (v == 'tax') await _editTax();
              if (v == 'logout') await s.signOut();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'outlet', child: Text('Switch outlet')),
              if (s.can('core.module.manage')) const PopupMenuItem(value: 'tax', child: Text('Default tax rate')),
              const PopupMenuItem(value: 'logout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: IndexedStack(index: _tab, children: [for (final t in tabs) t.$3]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [for (final t in tabs) NavigationDestination(icon: Icon(t.$2), label: t.$1)],
      ),
    );
  }

  Future<void> _refreshPending() async {
    _pending = (await SalesQueue.instance.pending()).length;
    if (mounted) setState(() {});
  }

  Future<void> _pickOutlet() async {
    final s = Session.instance;
    final o = await showModalBottomSheet<Outlet>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final o in s.outlets)
            ListTile(
              title: Text(o.name),
              subtitle: Text(o.kind),
              trailing: o.id == s.outlet?.id ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, o),
            ),
        ]),
      ),
    );
    if (o != null) {
      await s.selectOutlet(o);
      setState(() {});
    }
  }

  Future<void> _editTax() async {
    final s = Session.instance;
    final c = TextEditingController(text: (s.defaultTaxRate * 100).toStringAsFixed(2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Default tax rate'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: c,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(suffixText: '%', labelText: 'e.g. 6 for SST'),
          ),
          const SizedBox(height: 8),
          const Text('Zone-based tax rules come in the accounting & tax update.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      final v = double.tryParse(c.text) ?? 0;
      try {
        await s.saveTaxRate(v / 100);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tax rate saved')));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }
}
