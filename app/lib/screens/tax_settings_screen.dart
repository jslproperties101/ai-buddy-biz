import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

/// Shows which tax rates apply at this outlet, lets owners set the outlet's country/region
/// and add their own rates (which override the starter rates).
class TaxSettingsScreen extends StatefulWidget {
  const TaxSettingsScreen({super.key});
  @override
  State<TaxSettingsScreen> createState() => _TaxSettingsScreenState();
}

class _TaxSettingsScreenState extends State<TaxSettingsScreen> {
  List<Map<String, dynamic>> _zones = [];
  bool _loading = true;
  Session get _s => Session.instance;
  bool get _canEdit => _s.can('fin.tax.manage');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final z = await _s.db.from('tax_zones').select('id, country_code, region, name').order('country_code');
      _zones = List<Map<String, dynamic>>.from(z);
      await _s.refreshTaxTable();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _setPlace() async {
    final countries = {for (final z in _zones) z['country_code'] as String: z}.values.toList();
    String cc = _s.outlet?.countryCode ?? _s.countryCode;
    String? region = _s.outlet?.region;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (context, set) {
        final regions = _zones.where((z) => z['country_code'] == cc && z['region'] != null).toList();
        if (region != null && !regions.any((z) => z['region'] == region)) region = null;
        return AlertDialog(
          title: const Text('Where is this outlet?'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: countries.any((z) => z['country_code'] == cc) ? cc : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Country'),
              items: [
                for (final z in countries)
                  DropdownMenuItem(
                      value: z['country_code'] as String,
                      child: Text('${z['country_code']} · ${(z['name'] as String).split(' (').first}')),
              ],
              onChanged: (v) => set(() {
                cc = v!;
                region = null;
              }),
            ),
            if (regions.isNotEmpty)
              DropdownButtonFormField<String?>(
                value: region,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'State / province'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Not listed / country rate')),
                  for (final z in regions)
                    DropdownMenuItem<String?>(value: z['region'] as String, child: Text(z['name'] as String)),
                ],
                onChanged: (v) => set(() => region = v),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        );
      }),
    );
    if (ok != true) return;
    try {
      await _s.db.from('outlets').update({'country_code': cc, 'region': region}).eq('id', _s.outlet!.id);
      await _s.reloadOutlets();
      await _s.refreshTaxTable();
      if (mounted) setState(() {});
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _addRate() async {
    final code = TextEditingController(text: 'standard');
    final name = TextEditingController();
    final pct = TextEditingController();
    final from = TextEditingController(text: DateTime.now().toIso8601String().substring(0, 10));
    var inclusive = _s.taxTable.values.any((t) => t.inclusive);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Add or change a rate'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: code,
                decoration: const InputDecoration(
                    labelText: 'Tax code', helperText: 'standard, reduced, service, service_fnb, exempt, or your own'),
              ),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name on receipts (e.g. SST 10%)')),
              TextField(
                controller: pct,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Rate', suffixText: '%'),
              ),
              TextField(controller: from, decoration: const InputDecoration(labelText: 'Valid from (YYYY-MM-DD)')),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Prices include this tax'),
                value: inclusive,
                onChanged: (v) => set(() => inclusive = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final rate = double.tryParse(pct.text);
    if (rate == null || rate < 0 || rate >= 100 || name.text.trim().isEmpty || code.text.trim().isEmpty) {
      _snack('Enter a code, a name and a rate between 0 and 100');
      return;
    }
    final cc = _s.outlet?.countryCode ?? _s.countryCode;
    final zone = _zones.where((z) => z['country_code'] == cc && z['region'] == _s.outlet?.region).firstOrNull ??
        _zones.where((z) => z['country_code'] == cc && z['region'] == null).firstOrNull;
    if (zone == null) {
      _snack('No tax zone for $cc yet. Ask support to add it.');
      return;
    }
    try {
      await _s.db.from('tax_rates').insert({
        'tenant_id': _s.tenantId,
        'zone_id': zone['id'],
        'tax_code': code.text.trim().toLowerCase(),
        'name': name.text.trim(),
        'rate': rate / 100,
        'inclusive': inclusive,
        'valid_from': from.text.trim(),
        'source': 'manual',
      });
      await _s.refreshTaxTable();
      if (mounted) setState(() {});
      _snack('Saved. New sales use this rate from ${from.text.trim()}.');
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final o = _s.outlet;
    final rates = _s.taxTable.values.toList()..sort((a, b) => a.code.compareTo(b.code));
    return Scaffold(
      appBar: AppBar(title: const Text('Tax')),
      floatingActionButton: _canEdit
          ? FloatingActionButton.extended(heroTag: null, onPressed: _addRate, icon: const Icon(Icons.add), label: const Text('Add rate'))
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(12), children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(o?.name ?? '—'),
                  subtitle: Text('Country ${o?.countryCode ?? _s.countryCode}${o?.region != null ? ' · ${o!.region}' : ''}'),
                  trailing: _canEdit ? const Icon(Icons.edit) : null,
                  onTap: _canEdit ? _setPlace : null,
                ),
              ),
              const SizedBox(height: 8),
              Text('Rates in use here', style: Theme.of(context).textTheme.titleMedium),
              Text('Products without a tax code use "${_s.defaultTaxCode}".', style: Theme.of(context).textTheme.bodySmall),
              for (final r in rates)
                ListTile(
                  title: Text(r.name),
                  subtitle: Text('${r.code}${r.inclusive ? ' · included in price' : ' · added on top'}'),
                  trailing: Text('${(r.rate * 100).toStringAsFixed(r.rate * 100 % 1 == 0 ? 0 : 2)}%'),
                ),
              if (rates.isEmpty) const ListTile(title: Text('No rates found for this place')),
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'Starter rates are provided for convenience and can change. Confirm them with your tax adviser '
                  'or the tax authority, and add your own rate here when a change takes effect.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ]),
    );
  }
}
