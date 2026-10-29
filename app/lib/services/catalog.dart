import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'session.dart';

class Variant {
  final String id;
  final String productId;
  final String productName;
  final String? name;
  final String sku;
  final double price;
  final double cost;
  final bool trackStock;
  final String? taxCode;
  final List<BarcodeEntry> barcodes;

  Variant({
    required this.id,
    required this.productId,
    required this.productName,
    required this.name,
    required this.sku,
    required this.price,
    required this.cost,
    required this.trackStock,
    this.taxCode,
    required this.barcodes,
  });

  String get displayName => name == null || name!.isEmpty ? productName : '$productName — $name';

  Map<String, dynamic> toJson() => {
        'id': id,
        'product_id': productId,
        'product_name': productName,
        'name': name,
        'sku': sku,
        'price': price,
        'cost': cost,
        'track_stock': trackStock,
        'tax_code': taxCode,
        'barcodes': [for (final b in barcodes) b.toJson()],
      };

  static Variant fromJson(Map<String, dynamic> j) => Variant(
        id: j['id'] as String,
        productId: j['product_id'] as String,
        productName: j['product_name'] as String,
        name: j['name'] as String?,
        sku: j['sku'] as String,
        price: (j['price'] as num).toDouble(),
        cost: (j['cost'] as num).toDouble(),
        trackStock: j['track_stock'] as bool? ?? true,
        taxCode: j['tax_code'] as String?,
        barcodes: [for (final b in (j['barcodes'] as List? ?? [])) BarcodeEntry.fromJson(b as Map<String, dynamic>)],
      );
}

class BarcodeEntry {
  final String code;
  final String symbology;
  final double packQty;
  BarcodeEntry(this.code, this.symbology, this.packQty);
  Map<String, dynamic> toJson() => {'code': code, 'symbology': symbology, 'pack_qty': packQty};
  static BarcodeEntry fromJson(Map<String, dynamic> j) => BarcodeEntry(
      j['code'] as String, (j['symbology'] ?? 'EAN13') as String, ((j['pack_qty'] ?? 1) as num).toDouble());
}

/// Result of scanning: which item, and how many units the code represents (carton = 24, etc.).
class ScanHit {
  final Variant variant;
  final double qty;
  ScanHit(this.variant, this.qty);
}

/// Product catalogue with an on-device copy so the POS works offline.
class Catalog {
  Catalog._();
  static final Catalog instance = Catalog._();

  List<Variant> variants = [];
  DateTime? lastSync;

  String get _key => 'catalog_${AppSession.instance.tenantId}';

  Future<void> loadCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    variants = [for (final v in (j['variants'] as List)) Variant.fromJson(v as Map<String, dynamic>)];
    lastSync = DateTime.tryParse(j['synced'] as String? ?? '');
  }

  /// Pulls the latest catalogue. Throws when offline; the cached copy stays in place.
  Future<void> refresh() async {
    final s = AppSession.instance;
    final rows = await s.db
        .from('product_variants')
        .select('id, product_id, name, sku, price, cost, track_stock, active, products!inner(name, active, tax_code), barcodes(code, symbology, pack_qty)')
        .eq('tenant_id', s.tenantId!)
        .eq('active', true)
        .eq('products.active', true)
        .order('sku');
    variants = [
      for (final r in rows)
        Variant(
          id: r['id'] as String,
          productId: r['product_id'] as String,
          productName: r['products']['name'] as String,
          name: r['name'] as String?,
          sku: r['sku'] as String,
          price: (r['price'] as num).toDouble(),
          cost: (r['cost'] as num).toDouble(),
          trackStock: r['track_stock'] as bool,
          taxCode: r['products']['tax_code'] as String?,
          barcodes: [for (final b in (r['barcodes'] as List)) BarcodeEntry.fromJson(b as Map<String, dynamic>)],
        )
    ];
    lastSync = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode({'synced': lastSync!.toIso8601String(), 'variants': [for (final v in variants) v.toJson()]}));
  }

  /// Matches a scanned code against barcodes first, then SKUs. Works offline.
  ScanHit? findByCode(String code) {
    final c = code.trim();
    for (final v in variants) {
      for (final b in v.barcodes) {
        if (b.code == c) return ScanHit(v, b.packQty);
      }
    }
    for (final v in variants) {
      if (v.sku.toLowerCase() == c.toLowerCase()) return ScanHit(v, 1);
    }
    return null;
  }

  List<Variant> search(String q) {
    final t = q.trim().toLowerCase();
    if (t.isEmpty) return variants;
    return variants
        .where((v) =>
            v.displayName.toLowerCase().contains(t) ||
            v.sku.toLowerCase().contains(t) ||
            v.barcodes.any((b) => b.code.contains(t)))
        .toList();
  }
}

/// In-store EAN-13 codes (prefix 2) for items that don't come with a barcode.
String generateInStoreEan13() {
  final now = DateTime.now().microsecondsSinceEpoch.toString();
  final body = '2${now.substring(now.length - 11)}';
  return body + ean13CheckDigit(body).toString();
}

int ean13CheckDigit(String twelve) {
  var sum = 0;
  for (var i = 0; i < 12; i++) {
    final d = int.parse(twelve[i]);
    sum += i.isEven ? d : d * 3;
  }
  return (10 - sum % 10) % 10;
}

bool isValidEan13(String code) =>
    RegExp(r'^\d{13}$').hasMatch(code) && ean13CheckDigit(code.substring(0, 12)) == int.parse(code[12]);
