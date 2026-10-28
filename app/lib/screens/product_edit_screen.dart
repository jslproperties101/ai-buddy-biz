import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/catalog.dart';
import '../services/session.dart';
import 'scanner_screen.dart';

class _VariantForm {
  String? id;
  final name = TextEditingController();
  final sku = TextEditingController();
  final price = TextEditingController();
  final cost = TextEditingController();
  final barcode = TextEditingController();
  final cartonBarcode = TextEditingController();
  final cartonQty = TextEditingController();
  final openingStock = TextEditingController();
  final reorderPoint = TextEditingController();
  bool trackStock = true;
}

class ProductEditScreen extends StatefulWidget {
  final String? productId;
  const ProductEditScreen({super.key, this.productId});
  @override
  State<ProductEditScreen> createState() => _ProductEditScreenState();
}

class _ProductEditScreenState extends State<ProductEditScreen> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  String _kind = 'stock';
  String _unit = 'pcs';
  String? _categoryId;
  List<Map<String, dynamic>> _categories = [];
  final List<_VariantForm> _variants = [];
  final List<String> _removed = [];
  bool _loading = true;
  bool _saving = false;
  bool _active = true;

  bool get _isNew => widget.productId == null;
  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cats = await _s.db.from('categories').select('id, name').eq('tenant_id', _s.tenantId!).order('name');
      _categories = List<Map<String, dynamic>>.from(cats);
      if (_isNew) {
        _variants.add(_VariantForm()..sku.text = _suggestSku());
      } else {
        final p = await _s.db
            .from('products')
            .select('*, product_variants(*, barcodes(*))')
            .eq('id', widget.productId!)
            .single();
        _name.text = p['name'] as String;
        _description.text = (p['description'] ?? '') as String;
        _kind = p['kind'] as String;
        _unit = p['unit'] as String;
        _categoryId = p['category_id'] as String?;
        _active = p['active'] as bool;
        final stock = _s.outlet == null
            ? <dynamic>[]
            : await _s.db.from('stock_levels').select('variant_id, reorder_point').eq('outlet_id', _s.outlet!.id);
        final reorder = {for (final r in stock) r['variant_id']: r['reorder_point']};
        for (final v in (p['product_variants'] as List)) {
          if (v['active'] != true) continue;
          final f = _VariantForm()
            ..id = v['id'] as String
            ..trackStock = v['track_stock'] as bool;
          f.name.text = (v['name'] ?? '') as String;
          f.sku.text = v['sku'] as String;
          f.price.text = (v['price'] as num).toStringAsFixed(2);
          f.cost.text = (v['cost'] as num).toString();
          for (final b in (v['barcodes'] as List)) {
            if ((b['pack_qty'] as num) == 1 && f.barcode.text.isEmpty) {
              f.barcode.text = b['code'] as String;
            } else if ((b['pack_qty'] as num) > 1 && f.cartonBarcode.text.isEmpty) {
              f.cartonBarcode.text = b['code'] as String;
              f.cartonQty.text = (b['pack_qty'] as num).toString();
            }
          }
          final rp = reorder[v['id']];
          if (rp != null) f.reorderPoint.text = (rp as num).toString();
          _variants.add(f);
        }
        if (_variants.isEmpty) _variants.add(_VariantForm()..sku.text = _suggestSku());
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _suggestSku() {
    final base = _name.text.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final prefix = base.isEmpty ? 'ITEM' : base.substring(0, base.length.clamp(0, 6));
    final n = DateTime.now().millisecondsSinceEpoch % 100000;
    return '$prefix-${n.toString().padLeft(5, '0')}-${_variants.length + 1}';
  }

  Future<void> _addCategory() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New category'),
        content: TextField(controller: c, autofocus: true),
        actions: [FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Add'))],
      ),
    );
    if (name == null || name.isEmpty) return;
    final row = await _s.db.from('categories').insert({'tenant_id': _s.tenantId, 'name': name}).select().single();
    setState(() {
      _categories.add(row);
      _categoryId = row['id'] as String;
    });
  }

  String? _validate() {
    if (_name.text.trim().isEmpty) return 'Product name is required';
    final skus = <String>{};
    for (final v in _variants) {
      final sku = v.sku.text.trim();
      if (sku.isEmpty) return 'Every variant needs a SKU';
      if (!skus.add(sku.toLowerCase())) return 'SKU $sku is used twice';
      if (double.tryParse(v.price.text) == null) return 'Enter a price for $sku';
      if (v.cartonBarcode.text.trim().isNotEmpty && (double.tryParse(v.cartonQty.text) ?? 0) <= 1) {
        return 'Carton quantity for $sku must be more than 1';
      }
    }
    if (_variants.length > 1 && _variants.any((v) => v.name.text.trim().isEmpty)) {
      return 'Name each variant (e.g. Red / XL)';
    }
    return null;
  }

  Future<void> _save() async {
    final err = _validate();
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    setState(() => _saving = true);
    final t = _s.tenantId!;
    try {
      final productData = {
        'tenant_id': t,
        'name': _name.text.trim(),
        'description': _description.text.trim().isEmpty ? null : _description.text.trim(),
        'kind': _kind,
        'unit': _unit,
        'category_id': _categoryId,
        'active': _active,
      };
      final String pid;
      if (_isNew) {
        final p = await _s.db.from('products').insert(productData).select('id').single();
        pid = p['id'] as String;
      } else {
        await _s.db.from('products').update(productData).eq('id', widget.productId!);
        pid = widget.productId!;
      }

      for (final id in _removed) {
        await _s.db.from('product_variants').update({'active': false}).eq('id', id);
      }

      for (final v in _variants) {
        final data = {
          'tenant_id': t,
          'product_id': pid,
          'sku': v.sku.text.trim(),
          'name': v.name.text.trim().isEmpty ? null : v.name.text.trim(),
          'price': double.parse(v.price.text),
          'cost': double.tryParse(v.cost.text) ?? 0,
          'track_stock': _kind == 'stock' && v.trackStock,
        };
        final bool created = v.id == null;
        if (created) {
          final row = await _s.db.from('product_variants').insert(data).select('id').single();
          v.id = row['id'] as String;
        } else {
          await _s.db.from('product_variants').update(data).eq('id', v.id!);
        }

        // Barcodes: replace this variant's set with what's on the form
        await _s.db.from('barcodes').delete().eq('variant_id', v.id!);
        final codes = <Map<String, dynamic>>[];
        final unit = v.barcode.text.trim();
        if (unit.isNotEmpty) {
          codes.add({
            'tenant_id': t,
            'variant_id': v.id,
            'code': unit,
            'symbology': isValidEan13(unit) ? 'EAN13' : 'CODE128',
            'pack_qty': 1,
          });
        }
        final carton = v.cartonBarcode.text.trim();
        if (carton.isNotEmpty) {
          codes.add({
            'tenant_id': t,
            'variant_id': v.id,
            'code': carton,
            'symbology': carton.length == 14 ? 'ITF14' : 'CODE128',
            'pack_qty': double.parse(v.cartonQty.text),
          });
        }
        if (codes.isNotEmpty) await _s.db.from('barcodes').insert(codes);

        if (_s.outlet != null && data['track_stock'] == true) {
          final opening = double.tryParse(v.openingStock.text) ?? 0;
          if (created || opening != 0) {
            if (_s.can('inv.stock.adjust')) {
              await _s.db.rpc('adjust_stock', params: {
                'p_outlet': _s.outlet!.id,
                'p_variant': v.id,
                'p_qty_change': opening,
                'p_reason': 'opening',
                'p_unit_cost': double.tryParse(v.cost.text),
              });
            }
          }
          final rp = double.tryParse(v.reorderPoint.text);
          await _s.db
              .from('stock_levels')
              .update({'reorder_point': rp})
              .eq('outlet_id', _s.outlet!.id)
              .eq('variant_id', v.id!);
        }
      }
      if (mounted) Navigator.of(context).pop(true);
    } on PostgrestException catch (e) {
      final msg = e.code == '23505' ? 'That SKU or barcode is already used by another product.' : e.message;
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _scanInto(TextEditingController c) async {
    final code = await ScannerScreen.scanOnce(context);
    if (code != null) setState(() => c.text = code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New product' : 'Edit product'),
        actions: [
          TextButton(onPressed: _saving || _loading ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Product name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    value: _categoryId,
                    decoration: const InputDecoration(labelText: 'Category', border: OutlineInputBorder()),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('None')),
                      for (final c in _categories)
                        DropdownMenuItem<String?>(value: c['id'] as String, child: Text(c['name'] as String)),
                    ],
                    onChanged: (v) => setState(() => _categoryId = v),
                  ),
                ),
                IconButton(onPressed: _addCategory, icon: const Icon(Icons.add)),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _kind,
                    decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'stock', child: Text('Stock item')),
                      DropdownMenuItem(value: 'service', child: Text('Service')),
                      DropdownMenuItem(value: 'non_stock', child: Text('Non-stock item')),
                    ],
                    onChanged: (v) => setState(() => _kind = v!),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _unit,
                    decoration: const InputDecoration(labelText: 'Unit', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'pcs', child: Text('pcs')),
                      DropdownMenuItem(value: 'kg', child: Text('kg')),
                      DropdownMenuItem(value: 'g', child: Text('g')),
                      DropdownMenuItem(value: 'l', child: Text('litre')),
                      DropdownMenuItem(value: 'm', child: Text('metre')),
                      DropdownMenuItem(value: 'box', child: Text('box')),
                      DropdownMenuItem(value: 'hour', child: Text('hour')),
                    ],
                    onChanged: (v) => setState(() => _unit = v!),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: _description,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Description (optional)', border: OutlineInputBorder()),
              ),
              if (!_isNew)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active (shown at POS)'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
              const SizedBox(height: 16),
              Text(_variants.length > 1 ? 'Variants' : 'Price, SKU and barcode',
                  style: Theme.of(context).textTheme.titleMedium),
              for (var i = 0; i < _variants.length; i++) _variantCard(i),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => setState(() => _variants.add(_VariantForm()..sku.text = _suggestSku())),
                icon: const Icon(Icons.add),
                label: const Text('Add variant (size, colour…)'),
              ),
              const SizedBox(height: 40),
            ]),
    );
  }

  Widget _variantCard(int i) {
    final v = _variants[i];
    final stock = _kind == 'stock';
    InputDecoration d(String label, {Widget? suffix, String? helper}) =>
        InputDecoration(labelText: label, isDense: true, suffixIcon: suffix, helperText: helper);
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          if (_variants.length > 1)
            Row(children: [
              Expanded(child: TextField(controller: v.name, decoration: d('Variant name (e.g. Red / XL)'))),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => setState(() {
                  if (v.id != null) _removed.add(v.id!);
                  _variants.removeAt(i);
                }),
              ),
            ]),
          Row(children: [
            Expanded(
              child: TextField(
                controller: v.price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: d('Selling price'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: v.cost,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: d('Cost price'),
              ),
            ),
          ]),
          TextField(controller: v.sku, decoration: d('SKU')),
          TextField(
            controller: v.barcode,
            decoration: d(
              'Barcode',
              suffix: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Generate in-store barcode',
                  icon: const Icon(Icons.auto_awesome_outlined),
                  onPressed: () => setState(() => v.barcode.text = generateInStoreEan13()),
                ),
                IconButton(
                  tooltip: 'Scan',
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed: () => _scanInto(v.barcode),
                ),
              ]),
            ),
          ),
          if (stock)
            Row(children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: v.cartonBarcode,
                  decoration: d('Carton barcode',
                      suffix: IconButton(
                          icon: const Icon(Icons.qr_code_scanner), onPressed: () => _scanInto(v.cartonBarcode))),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: v.cartonQty,
                  keyboardType: TextInputType.number,
                  decoration: d('Units/carton'),
                ),
              ),
            ]),
          if (stock && _s.outlet != null)
            Row(children: [
              if (_s.can('inv.stock.adjust'))
                Expanded(
                  child: TextField(
                    controller: v.openingStock,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: d(v.id == null ? 'Opening stock' : 'Add stock', helper: _s.outlet!.name),
                  ),
                ),
              if (_s.can('inv.stock.adjust')) const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: v.reorderPoint,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: d('Reorder at', helper: 'Low-stock alert'),
                ),
              ),
            ]),
        ]),
      ),
    );
  }
}
