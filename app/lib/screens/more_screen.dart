import 'package:flutter/material.dart';

import '../services/crm.dart';
import '../services/session.dart';
import 'crm_settings_screen.dart';
import 'modules_screen.dart';
import 'my_work_screen.dart';
import 'reports_screen.dart';
import 'sales_history_screen.dart';
import 'shift_screen.dart';
import 'suppliers_screen.dart';
import 'tax_settings_screen.dart';
import 'team_access_screen.dart';

class MoreScreen extends StatefulWidget {
  final VoidCallback onOutletChanged;
  final VoidCallback? onModulesChanged;
  final List<(String, IconData, Widget)> extra; // features that didn't fit in the bottom bar
  const MoreScreen({super.key, required this.onOutletChanged, this.onModulesChanged, this.extra = const []});
  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  Future<void> _go(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    if (mounted) setState(() {});
  }

  Future<void> _pickOutlet() async {
    final s = AppSession.instance;
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

  Future<void> _pickBusiness() async {
    final s = AppSession.instance;
    final id = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final b in s.businesses)
            ListTile(
              title: Text(b.$2),
              subtitle: Text(b.$3),
              trailing: b.$1 == s.tenantId ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, b.$1),
            ),
        ]),
      ),
    );
    if (id == null || id == s.tenantId) return;
    await s.switchBusiness(id);
    await Crm.instance.load();
    widget.onOutletChanged();
    widget.onModulesChanged?.call();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = AppSession.instance;
    return ListView(children: [
      for (final e in widget.extra)
        ListTile(
          leading: Icon(e.$2),
          title: Text(e.$1),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _go(Scaffold(appBar: AppBar(title: Text(e.$1)), body: e.$3)),
        ),
      if (widget.extra.isNotEmpty) const Divider(),
      if (s.has('HR') && s.can('hr.self'))
        ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: const Text('My work'),
          subtitle: const Text('Clock in/out, leave, claims, payslips'),
          onTap: () => _go(const MyWorkScreen()),
        ),
      if (s.can('inv.supplier.manage'))
        ListTile(
          leading: const Icon(Icons.factory_outlined),
          title: const Text('Suppliers & purchasing'),
          subtitle: const Text('Supplier scorecards, documents, purchase orders'),
          onTap: () => _go(const SuppliersScreen()),
        ),
      if (s.can('pos.shift.manage') && s.has('POS'))
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
      if (s.can('crm.settings.manage') || s.can('crm.campaign.manage'))
        ListTile(
          leading: const Icon(Icons.loyalty_outlined),
          title: const Text('CRM settings'),
          subtitle: const Text('Loyalty points, website form, WhatsApp & email'),
          onTap: () => _go(const CrmSettingsScreen()),
        ),
      if (s.can('fin.tax.manage') || s.can('pos.sale.create') || s.can('fin.invoice.view'))
        ListTile(
          leading: const Icon(Icons.percent),
          title: const Text('Tax'),
          subtitle: Text('Rates for ${s.outlet?.name ?? 'this outlet'}'),
          onTap: () => _go(const TaxSettingsScreen()),
        ),
      if (s.can('core.user.manage'))
        ListTile(
          leading: const Icon(Icons.manage_accounts_outlined),
          title: const Text('Team & access'),
          subtitle: const Text('Invite staff by email, roles, remove access'),
          onTap: () => _go(const TeamAccessScreen()),
        ),
      if (s.can('core.module.manage'))
        ListTile(
          leading: const Icon(Icons.widgets_outlined),
          title: const Text('Modules'),
          subtitle: const Text('Turn features on or off for your business'),
          onTap: () async {
            final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const ModulesScreen()));
            if (changed == true) widget.onModulesChanged?.call();
            if (mounted) setState(() {});
          },
        ),
      const Divider(),
      if (s.businesses.length > 1)
        ListTile(
          leading: const Icon(Icons.swap_horiz),
          title: const Text('Switch business'),
          subtitle: Text(s.tenantName),
          onTap: _pickBusiness,
        ),
      if (!s.parentOnly && s.outlets.length > 1)
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
