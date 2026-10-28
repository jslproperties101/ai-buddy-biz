import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../services/catalog.dart';
import '../services/printing_service.dart';
import '../services/sales_queue.dart';
import '../services/session.dart';
import 'scanner_screen.dart';

class CartLine {
  final Variant variant;
  double qty;
  double discount; // amount off the whole line
  CartLine(this.variant, this.qty) : discount = 0;
  double get gross => variant.price * qty;
  double get net => gross - discount;

  // Mirrors the server's complete_sale maths so the screen total matches the receipt.
  TaxRate get tax => Session.instance.taxFor(variant.taxCode);
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

  NumberFormat get _money => NumberFormat.currency(symbol: '${Session.instance.currency} ');
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
              helperText: Session.instance.can('pos.sale.discount') ? null : 'Up to 10% without a manager',
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
    final s = Session.instance;
    if (s.outlet == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No outlet selected')));
      return;
    }
    final result = await showModalBottomSheet<(String, double)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PaySheet(total: _total, money: _money),
    );
    if (result == null) return;

    final payload = {
      'client_sale_id': const Uuid().v4(),
      'outlet_id': s.outlet!.id,
      if (s.openShiftId != null) 'shift_id': s.openShiftId,
      'currency': s.currency,
      'sold_at': DateTime.now().toUtc().toIso8601String(),
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
        {'method': result.$1, 'amount': result.$2}
      ],
    };
    final snapshot = List<CartLine>.from(_cart);
    final totals = (_subtotal, _discount, _tax, _total);

    setState(() => _paying = true);
    try {
      final r = await SalesQueue.instance.submit(payload);
      setState(() => _cart.clear());
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
            if (result.$1 == 'cash' && result.$2 > totals.$4)
              Text('Change: ${_money.format(result.$2 - totals.$4)}',
                  style: Theme.of(context).textTheme.headlineSmall),
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
                paidMethod: result.$1,
                paid: result.$2,
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

class _PaySheet extends StatefulWidget {
  final double total;
  final NumberFormat money;
  const _PaySheet({required this.total, required this.money});
  @override
  State<_PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<_PaySheet> {
  String _method = 'cash';
  late final TextEditingController _amount = TextEditingController(text: widget.total.toStringAsFixed(2));

  static const _methods = {
    'cash': ('Cash', Icons.payments_outlined),
    'card': ('Card', Icons.credit_card),
    'qr': ('QR (DuitNow etc.)', Icons.qr_code_2),
    'ewallet': ('E-wallet', Icons.account_balance_wallet_outlined),
    'bank_transfer': ('Bank transfer', Icons.account_balance_outlined),
  };

  @override
  Widget build(BuildContext context) {
    final amount = double.tryParse(_amount.text) ?? 0;
    final quick = <double>{widget.total, ...[5, 10, 20, 50, 100].map((e) => e.toDouble()).where((e) => e > widget.total)}
        .take(4)
        .toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Total ${widget.money.format(widget.total)}',
                style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final m in _methods.entries)
                ChoiceChip(
                  avatar: Icon(m.value.$2, size: 18),
                  label: Text(m.value.$1),
                  selected: _method == m.key,
                  onSelected: (_) => setState(() {
                    _method = m.key;
                    if (m.key != 'cash') _amount.text = widget.total.toStringAsFixed(2);
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
              if (amount > widget.total) Text('Change: ${widget.money.format(amount - widget.total)}'),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: amount + 0.001 < widget.total ? null : () => Navigator.pop(context, (_method, amount)),
              child: const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Text('Complete sale')),
            ),
          ]),
        ),
      ),
    );
  }
}
