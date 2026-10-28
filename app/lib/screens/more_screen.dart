import 'package:flutter/material.dart';

import '../services/session.dart';
import 'reports_screen.dart';
import 'sales_history_screen.dart';
import 'shift_screen.dart';
import 'tax_settings_screen.dart';

class MoreScreen extends StatefulWidget {
  final VoidCallback onOutletChanged;
  const MoreScreen({super.key, required this.onOutletChanged});
  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  Future<void> _go(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
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
              subtitle: Text([o.kind, if (o.countryCode != null) o.countryCode!, if (o.region != null) o.region!].join(' · ')),
              trailing: o.id == s.outlet?.id ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, o),
            ),
        ]),
      ),
    );
    if (o != null) {
      await s.selectOutlet(o);
      widget.onOutletChanged();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    return ListView(children: [
      if (s.can('pos.shift.manage'))
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Shift & cash drawer'),
          subtitle: Text(s.openShiftId == null ? 'No shift open' : 'Shift open'),
          onTap: () => _go(const ShiftScreen()),
        ),
      if (s.can('pos.sale.create') || s.can('pos.report.view'))
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Sales history'),
          subtitle: Text(s.can('pos.sale.void') ? 'View receipts, void sales' : 'Your receipts'),
          onTap: () => _go(const SalesHistoryScreen()),
        ),
      if (s.can('pos.report.view') || s.can('fin.report.view'))
        ListTile(
          leading: const Icon(Icons.bar_chart),
          title: const Text('Reports'),
          subtitle: const Text('Sales, profit & loss, tax, trial balance'),
          onTap: () => _go(const ReportsScreen()),
        ),
      ListTile(
        leading: const Icon(Icons.percent),
        title: const Text('Tax'),
        subtitle: Text('Rates for ${s.outlet?.name ?? 'this outlet'}'),
        onTap: () => _go(const TaxSettingsScreen()),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.store_outlined),
        title: const Text('Switch outlet'),
        subtitle: Text(s.outlet?.name ?? '—'),
        onTap: _pickOutlet,
      ),
      ListTile(
        leading: const Icon(Icons.logout),
        title: const Text('Sign out'),
        onTap: s.signOut,
      ),
    ]);
  }
}
