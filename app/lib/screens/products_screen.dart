import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/catalog.dart';
import '../services/printing_service.dart';
import '../services/session.dart';
import 'product_edit_screen.dart';

class ProductsScreen extends StatefulWidget {
  final VoidCallback onChanged;
  const ProductsScreen({super.key, required this.onChanged});
  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _products = [];
  Map<String, double> _stock = {};
  bool _loading = true;
  String? _error;

  NumberFormat get _money => NumberFormat.currency(symbol: '${Session.instance.currency} ');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = Session.instance;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await s.db
          .from('products')
          .select('id, name, kind, active, categories(name), product_variants(id, sku, name, price, active, barcodes(code))')
          .eq('tenant_id', s.tenantId!)
          .order('name');
      final stock = s.outlet == null
          ? <dynamic>[]
          : await s.db.from('stock_levels').select('variant_id, qty').eq('outlet_id', s.outlet!.id);
      setState(() {
        _products = List<Map<String, dynamic>>.from(rows);
        _stock = {for (final r in stock) r['variant_id'] as String: (r['qty'] as num).toDouble()};
      });
    } on PostgrestException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Offline. Product management needs a connection; selling still works.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open([String? productId]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ProductEditScreen(productId: productId)),
    );
    if (changed == true) {
      await _load();
      widget.onChanged();
    }
  }

  Future<void> _labels(Map<String, dynamic> product) async {
    final variants = [
      for (final v in (product['product_variants'] as List))
        if (v['active'] == true) v as Map<String, dynamic>
    ];
    if (variants.isEmpty) return;
    var chosen = variants.first;
    final copies = TextEditingController(text: '1');
    var size = '40x30';
    var showPrice = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Print labels'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (variants.length > 1)
              DropdownButtonFormField<Map<String, dynamic>>(
                value: chosen,
                items: [
                  for (final v in variants)
                    DropdownMenuItem(value: v, child: Text('${v['sku']} ${v['name'] ?? ''}')),
                ],
                onChanged: (v) => set(() => chosen = v!),
                decoration: const InputDecoration(labelText: 'Variant'),
              ),
            TextField(
              controller: copies,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'How many labels'),
            ),
            DropdownButtonFormField<String>(
              value: size,
              items: const [
                DropdownMenuItem(value: '40x30', child: Text('40 × 30 mm')),
                DropdownMenuItem(value: '50x25', child: Text('50 × 25 mm')),
                DropdownMenuItem(value: '58x40', child: Text('58 × 40 mm')),
                DropdownMenuItem(value: '100x50', child: Text('100 × 50 mm (carton)')),
              ],
              onChanged: (v) => set(() => size = v!),
              decoration: const InputDecoration(labelText: 'Label size'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show price'),
              value: showPrice,
              onChanged: (v) => set(() => showPrice = v),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Print')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final v = Catalog.instance.variants.where((x) => x.id == chosen['id']).firstOrNull;
    if (v == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sync first, then print')));
      return;
    }
    final dims = size.split('x').map(double.parse).toList();
    await PrintingService.printLabels(
      variant: v,
      copies: (int.tryParse(copies.text) ?? 1).clamp(1, 500),
      widthMm: dims[0],
      heightMm: dims[1],
      showPrice: showPrice,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    final q = _search.text.trim().toLowerCase();
    final list = q.isEmpty
        ? _products
        : _products.where((p) {
            if ((p['name'] as String).toLowerCase().contains(q)) return true;
            return (p['product_variants'] as List).any((v) =>
                (v['sku'] as String).toLowerCase().contains(q) ||
                (v['barcodes'] as List).any((b) => (b['code'] as String).contains(q)));
          }).toList();

    return Scaffold(
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _search,
            decoration: const InputDecoration(
              hintText: 'Search products',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: list.isEmpty
                      ? ListView(children: const [
                          SizedBox(height: 80),
                          Center(child: Text('No products yet. Tap + to add your first one.')),
                        ])
                      : ListView.builder(
                          itemCount: list.length,
                          itemBuilder: (_, i) {
                            final p = list[i];
                            final vs = [for (final v in (p['product_variants'] as List)) if (v['active'] == true) v];
                            final prices = vs.map((v) => (v['price'] as num).toDouble()).toList()..sort();
                            final qty = vs.fold<double>(0.0, (a, v) => a + (_stock[v['id']] ?? 0));
                            return ListTile(
                              enabled: p['active'] == true,
                              title: Text(p['name'] as String),
                              subtitle: Text([
                                if (vs.length == 1) vs.first['sku'] else '${vs.length} variants',
                                if (p['categories'] != null) p['categories']['name'],
                                if (p['kind'] == 'stock') 'Stock ${_fmt(qty)}',
                              ].join(' · ')),
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                if (prices.isNotEmpty)
                                  Text(prices.first == prices.last
                                      ? _money.format(prices.first)
                                      : '${_money.format(prices.first)}+'),
                                if (s.can('inv.label.print'))
                                  IconButton(
                                    icon: const Icon(Icons.label_outline),
                                    tooltip: 'Print labels',
                                    onPressed: () => _labels(p),
                                  ),
                              ]),
                              onTap: s.can('inv.product.manage') ? () => _open(p['id'] as String) : null,
                            );
                          },
                        ),
                ),
        ),
      ]),
      floatingActionButton: s.can('inv.product.manage')
          ? FloatingActionButton(onPressed: () => _open(), child: const Icon(Icons.add))
          : null,
    );
  }

  String _fmt(double q) => q == q.roundToDouble() ? q.toInt().toString() : q.toStringAsFixed(2);
}
