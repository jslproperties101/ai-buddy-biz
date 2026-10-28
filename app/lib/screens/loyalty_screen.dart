import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

class LoyaltyScreen extends StatefulWidget {
  const LoyaltyScreen({super.key});
  @override
  State<LoyaltyScreen> createState() => _LoyaltyScreenState();
}

class _LoyaltyScreenState extends State<LoyaltyScreen> {
  bool _enabled = false;
  final _earn = TextEditingController(text: '1');
  final _value = TextEditingController(text: '0.01');
  final _min = TextEditingController(text: '100');
  bool _saving = false;
  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    final l = _s.loyalty;
    if (l != null) {
      _enabled = l.enabled;
      _earn.text = _trim(l.pointsPerUnit);
      _value.text = _trim(l.redeemValue);
      _min.text = '${l.minRedeem}';
    }
  }

  String _trim(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _s.db.from('loyalty_settings').upsert({
        'tenant_id': _s.tenantId,
        'enabled': _enabled,
        'points_per_unit': double.tryParse(_earn.text) ?? 1,
        'redeem_value': double.tryParse(_value.text) ?? 0.01,
        'min_redeem': int.tryParse(_min.text) ?? 100,
      });
      await _s.loadLoyalty();
      if (mounted) Navigator.of(context).pop();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final earn = double.tryParse(_earn.text) ?? 0;
    final value = double.tryParse(_value.text) ?? 0;
    final cur = _s.currency;
    final back = earn * value * 100;
    final canEdit = _s.can('crm.loyalty.manage');
    return Scaffold(
      appBar: AppBar(
        title: const Text('Loyalty points'),
        actions: [if (canEdit) TextButton(onPressed: _saving ? null : _save, child: const Text('Save'))],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Turn on loyalty points'),
          subtitle: const Text('Customers earn points when a sale is linked to them at the POS'),
          value: _enabled,
          onChanged: canEdit ? (v) => setState(() => _enabled = v) : null,
        ),
        TextField(
          controller: _earn,
          enabled: canEdit,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Points earned per $cur 1 spent'),
          onChanged: (_) => setState(() {}),
        ),
        TextField(
          controller: _value,
          enabled: canEdit,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Value of 1 point ($cur)'),
          onChanged: (_) => setState(() {}),
        ),
        TextField(
          controller: _min,
          enabled: canEdit,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Minimum points to redeem'),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'A customer spending $cur 100 earns ${(earn * 100).floor()} points, worth $cur ${(earn * 100 * value).toStringAsFixed(2)} '
              '— that is ${back.toStringAsFixed(1)}% back. Rewards are booked to "Loyalty rewards" in your accounts when redeemed.',
            ),
          ),
        ),
      ]),
    );
  }
}
