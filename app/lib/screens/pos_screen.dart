import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../services/catalog.dart';
import '../services/crm.dart';
import '../services/printing_service.dart';
import '../services/sales_queue.dart';
import '../services/session.dart';
import '../widgets/contact_picker.dart';
import 'scanner_screen.dart';

class CartLine {
  final Variant variant;
  double qty;
  double discount; // amount off the whole line
  CartLine(this.variant, this.qty) : discount = 0;
  double get gross => variant.price * qty;
  double get net => gross - discount;

  // Mirrors the server's complete_sale maths so the screen total matches the receipt.
  TaxRate get tax => AppSession.instance.taxFor(variant.taxCode);
  double get netRounded => (net * 100).roundToDouble() / 100;
  double get taxAmount {
    final t = tax;
    final v = t.inclusive ? netRounded - netRounded / (1 + t.rate) : netRounded * t.rate;
    return (v * 100).roundToDouble() / 100;
  }

  double get lineTotal => tax.inclusive ? netRounded : netRounded + taxAmount;
}

class PosScreen extends StatefulWidget {
  final VoidCallback onSaleDone;
  const PosScreen({super.key, required this.onSaleDone});
  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  final _search = TextEditingController();
  final List<CartLine> _cart = [];
  bool _paying = false;
  Map<String, dynamic>? _customer;

  NumberFormat get _money => NumberFormat.currency(symbol: '${AppSession.instance.currency} ');
  double get _subtotal => _cart.fold<double>(0.0, (a, l) => a + l.gross);
  double get _discount => _cart.fold<double>(0.0, (a, l) => a + l.discount);
  double _round(double v) => (v * 100).roundToDouble() / 100;
  double get _tax => _round(_cart.fold<double>(0.0, (a, l) => a + l.taxAmount));
  double get _total => _round(_cart.fold<double>(0.0, (a, l) => a + l.lineTotal));
  bool get _inclusive => _cart.isNotEmpty && _cart.every((l) => l.tax.inclusive);

  void _add(Variant v, [double qty = 1]) {
    setState(() {
      final existing = _cart.where((l) => l.variant.id == v.id).firstOrNull;
      if (existing != null) {
        existing.qty += qty;
      } else {
        _cart.add(CartLine(v, qty));
      }
    });
  }

  bool _addByCode(String code) {
    final hit = Catalog.instance.findByCode(code);
    if (hit == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No item with code $code')));
      return false;
    }
    _add(hit.variant, hit.qty);
    return true;
  }

  Future<void> _scan() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ScannerScreen(continuous: true, onCode: _addByCode),
    ));
  }

  Future<void> _editLine(CartLine l) async {
    final qty = TextEditingController(text: _fmtQty(l.qty));
    final disc = TextEditingController(text: l.discount == 0 ? '' : l.discount.toStringAsFixed(2));
    final res = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.variant.displayName),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: qty,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Quantity'),
          ),
          TextField(
            controller: disc,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Discount (amount)',
              helperText: AppSession.instance.can('pos.sale.discount') ? null : 'Up to 10% without a manager',
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'remove'), child: const Text('Remove')),
          FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
        ],
      ),
    );
    setState(() {
      if (res == 'remove') _cart.remove(l);
      if (res == 'save') {
        final q = double.tryParse(qty.text) ?? l.qty;
        if (q <= 0) {
          _cart.remove(l);
        } else {
          l.qty = q;
          l.discount = (double.tryParse(disc.text) ?? 0).clamp(0, l.gross).toDouble();
        }
      }
    });
  }

  String _fmtQty(double q) => q == q.roundToDouble() ? q.toInt().toString() : q.toString();

  Future<void> _pay() async {
    if (_cart.isEmpty) return;
    final s = AppSession.instance;
    if (s.outlet == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No outlet selected')));
      return;
    }
    // Points need a live balance; offline sales can't redeem
    double points = 0;
    if (_customer != null && Crm.instance.loyalty.enabled) {
      try {
        final c = await s.db.from('contacts').select('loyalty_points').eq('id', _customer!['id']).single();
        points = ((c['loyalty_points'] ?? 0) as num).toDouble();
        _customer!['loyalty_points'] = points;
      } catch (_) {}
    }
    if (!mounted) return;
    final result = await showModalBottomSheet<PayResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => PaySheet(
        total: _total,
        money: _money,
        maxPoints: Crm.instance.loyalty.redeemable(points, _total),
        pointsBalance: points,
      ),
    );
    if (result == null) return;

    final payload = {
      'client_sale_id': const Uuid().v4(),
      'outlet_id': s.outlet!.id,
      if (s.openShiftId != null) 'shift_id': s.openShiftId,
      'currency': s.currency,
      'sold_at': DateTime.now().toUtc().toIso8601String(),
      if (_customer != null) 'customer_id': _customer!['id'],
      'lines': [
        for (final l in _cart)
          {
            'variant_id': l.variant.id,
            'qty': l.qty,
            'unit_price': l.variant.price,
            'discount': l.discount,
          }
      ],
      'payments': [
        if (result.pointsAmount > 0) {'method': 'loyalty', 'amount': result.pointsAmount},
        if (result.amount > 0) {'method': result.method, 'amount': result.amount},
      ],
    };
    final snapshot = List<CartLine>.from(_cart);
    final totals = (_subtotal, _discount, _tax, _total);
    final customer = _customer;
    final rules = Crm.instance.loyalty;

    setState(() => _paying = true);
    try {
      final r = await SalesQueue.instance.submit(payload);
      setState(() {
        _cart.clear();
        _customer = null;
      });
      widget.onSaleDone();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          icon: Icon(r.outcome == SaleOutcome.synced ? Icons.check_circle : Icons.cloud_off, size: 40),
          title: Text(r.outcome == SaleOutcome.synced ? 'Sale complete' : 'Saved offline'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (r.receiptNo != null) Text('Receipt ${r.receiptNo}'),
            if (r.outcome == SaleOutcome.queued) const Text('It will sync when you are back online.'),
            const SizedBox(height: 8),
            if (result.change > 0)
              Text('Change: ${_money.format(result.change)}', style: Theme.of(context).textTheme.headlineSmall),
            if (customer != null && rules.enabled && r.outcome == SaleOutcome.synced)
              Text('${customer['name']} earned ~${((totals.$4 - result.pointsAmount) * rules.pointsPerUnit).floor()} points'),
          ]),
          actions: [
            TextButton(
              onPressed: () => PrintingService.printReceipt(
                receiptNo: r.receiptNo ?? 'PENDING',
                lines: [for (final l in snapshot) (l.variant.displayName, l.qty, l.variant.price, l.discount)],
                subtotal: totals.$1,
                discount: totals.$2,
                tax: totals.$3,
                total: totals.$4,
                paidMethod: result.pointsAmount > 0 ? 'points+${result.method}' : result.method,
                paid: result.pointsAmount + result.amount,
              ),
              child: const Text('Print receipt'),
            ),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Next sale')),
          ],
        ),
      );
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  Widget _customerBar() {
    final c = _customer;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: c == null
            ? ActionChip(
                avatar: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('Add customer'),
                onPressed: () async {
                  final picked = await ContactPicker.show(context);
                  if (picked != null) setState(() => _customer = picked);
                },
              )
            : InputChip(
                avatar: const Icon(Icons.person, size: 18),
                label: Text('${c['name']}'
                    '${Crm.instance.loyalty.enabled ? ' · ${((c['loyalty_points'] ?? 0) as num).toInt()} pts' : ''}'),
                onDeleted: () => setState(() => _customer = null),
                onPressed: () async {
                  final picked = await ContactPicker.show(context);
                  if (picked != null) setState(() => _customer = picked);
                },
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = _search.text.isEmpty ? <Variant>[] : Catalog.instance.search(_search.text).take(20).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: 'Search name, SKU or type barcode',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(_search.clear)),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (v) {
                // USB/Bluetooth scanners type the code and press Enter
                if (_addByCode(v)) setState(_search.clear);
              },
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), tooltip: 'Scan'),
        ]),
      ),
      _customerBar(),
      if (results.isNotEmpty)
        Expanded(
          child: ListView(children: [
            for (final v in results)
              ListTile(
                title: Text(v.displayName),
                subtitle: Text(v.sku),
                trailing: Text(_money.format(v.price)),
                onTap: () {
                  _add(v);
                  setState(_search.clear);
                },
              ),
          ]),
        )
      else
        Expanded(
          child: _cart.isEmpty
              ? Center(
                  child: Text(
                    Catalog.instance.variants.isEmpty
                        ? 'No products yet. Add them in the Products tab.'
                        : 'Scan or search to add items',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                )
              : ListView.separated(
                  itemCount: _cart.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final l = _cart[i];
                    return ListTile(
                      onTap: () => _editLine(l),
                      title: Text(l.variant.displayName),
                      subtitle: Text(
                          '${_fmtQty(l.qty)} × ${_money.format(l.variant.price)}${l.discount > 0 ? ' − ${_money.format(l.discount)}' : ''}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () => setState(() {
                            l.qty -= 1;
                            if (l.qty <= 0) _cart.remove(l);
                          }),
                        ),
                        Text(_money.format(l.net)),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: () => setState(() => l.qty += 1),
                        ),
                      ]),
                    );
                  },
                ),
        ),
      Material(
        elevation: 8,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              _row('Subtotal', _subtotal),
              if (_discount > 0) _row('Discount', -_discount),
              if (_tax > 0) _row(_inclusive ? 'Includes tax' : 'Tax', _tax),
              const SizedBox(height: 8),
              Row(children: [
                if (_cart.isNotEmpty)
                  TextButton(onPressed: () => setState(_cart.clear), child: const Text('Clear')),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: _cart.isEmpty || _paying ? null : _pay,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Text(_paying ? 'Saving…' : 'Charge ${_money.format(_total)}',
                          style: const TextStyle(fontSize: 18)),
                    ),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _row(String label, double v) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(label), Text(_money.format(v))],
      );
}

class PayResult {
  final String method; // payment for the part not covered by points
  final double amount; // what was handed over for that part (cash may be more than due)
  final double pointsAmount; // value paid with loyalty points
  final double change;
  PayResult(this.method, this.amount, this.pointsAmount, this.change);
}

class PaySheet extends StatefulWidget {
  final double total;
  final NumberFormat money;
  final double maxPoints; // money value of points that can be used (0 = none)
  final double pointsBalance;
  const PaySheet({super.key, required this.total, required this.money, this.maxPoints = 0, this.pointsBalance = 0});
  @override
  State<PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<PaySheet> {
  String _method = 'cash';
  bool _usePoints = false;
  late final TextEditingController _amount = TextEditingController(text: widget.total.toStringAsFixed(2));

  static const _methods = {
    'cash': ('Cash', Icons.payments_outlined),
    'card': ('Card', Icons.credit_card),
    'qr': ('QR (DuitNow etc.)', Icons.qr_code_2),
    'ewallet': ('E-wallet', Icons.account_balance_wallet_outlined),
    'bank_transfer': ('Bank transfer', Icons.account_balance_outlined),
  };

  double get _points => _usePoints ? widget.maxPoints : 0;
  double get _due => ((widget.total - _points) * 100).roundToDouble() / 100;

  void _resetAmount() => _amount.text = _due.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final amount = double.tryParse(_amount.text) ?? 0;
    final quick = <double>{_due, ...[5, 10, 20, 50, 100].map((e) => e.toDouble()).where((e) => e > _due)}.take(4).toList();
    final ok = _due <= 0 || amount + 0.001 >= _due;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Total ${widget.money.format(widget.total)}',
                style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
            if (widget.maxPoints > 0)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _usePoints,
                onChanged: (v) => setState(() {
                  _usePoints = v;
                  _resetAmount();
                }),
                title: Text('Use points (${widget.money.format(widget.maxPoints)})'),
                subtitle: Text('Balance ${widget.pointsBalance.toInt()} points'),
              ),
            if (_usePoints) Text('Still to pay ${widget.money.format(_due)}', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            if (_due > 0) ...[
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in _methods.entries)
                  ChoiceChip(
                    avatar: Icon(m.value.$2, size: 18),
                    label: Text(m.value.$1),
                    selected: _method == m.key,
                    onSelected: (_) => setState(() {
                      _method = m.key;
                      if (m.key != 'cash') _resetAmount();
                    }),
                  ),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: _amount,
                enabled: _method == 'cash',
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount received', border: OutlineInputBorder()),
                onChanged: (_) => setState(() {}),
              ),
              if (_method == 'cash') ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  for (final q in quick)
                    ActionChip(
                      label: Text(widget.money.format(q)),
                      onPressed: () => setState(() => _amount.text = q.toStringAsFixed(2)),
                    ),
                ]),
                if (amount > _due) Text('Change: ${widget.money.format(amount - _due)}'),
              ],
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: !ok
                  ? null
                  : () => Navigator.pop(
                        context,
                        PayResult(
                          _method,
                          _due <= 0 ? 0 : (_method == 'cash' ? amount : _due),
                          _points,
                          _due > 0 && _method == 'cash' && amount > _due ? amount - _due : 0,
                        ),
                      ),
              child: const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Text('Complete sale')),
            ),
          ]),
        ),
      ),
    );
  }
}
