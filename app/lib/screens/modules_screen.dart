import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

/// Owners switch whole areas of the app on or off for their business.
class ModulesScreen extends StatefulWidget {
  const ModulesScreen({super.key});
  @override
  State<ModulesScreen> createState() => _ModulesScreenState();
}

class _ModulesScreenState extends State<ModulesScreen> {
  static const _all = [
    ('POS', 'Point of sale', 'Selling at the counter, shifts, receipts', Icons.point_of_sale),
    ('INV', 'Products & stock', 'Catalog, SKUs, barcodes, labels, stock counts', Icons.inventory_2_outlined),
    ('FIN', 'Invoicing & accounts', 'Invoices, tax, reports, bookkeeping', Icons.receipt_long_outlined),
    ('CRM', 'Customers & leads', 'Pipeline, loyalty, campaigns', Icons.people_alt_outlined),
    ('LOG', 'Shipping & cargo', 'Shipments, air waybills, containers, vessels, customs', Icons.local_shipping_outlined),
  ];
  bool _changed = false;
  bool _busy = false;
  Session get _s => Session.instance;

  Future<void> _toggle(String code, bool on) async {
    if (!on && _s.modules.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Keep at least one module on')));
      return;
    }
    setState(() => _busy = true);
    try {
      await _s.db.from('tenant_modules').upsert({'tenant_id': _s.tenantId, 'module': code, 'enabled': on});
      await _s.reloadModules();
      _changed = true;
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Modules')),
        body: ListView(children: [
          for (final m in _all)
            SwitchListTile(
              secondary: Icon(m.$4),
              title: Text(m.$2),
              subtitle: Text(m.$3),
              value: _s.has(m.$1),
              onChanged: _busy ? null : (v) => _toggle(m.$1, v),
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Turning a module off hides it for everyone in your business. Nothing is deleted — '
                'switch it back on any time.'),
          ),
        ]),
      ),
    );
  }
}
