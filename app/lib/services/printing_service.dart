import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'catalog.dart';
import 'session.dart';

/// Receipts (58mm/80mm roll) and barcode labels, sent to any Android print service or shared as PDF.
class PrintingService {
  static NumberFormat get _money => NumberFormat.currency(symbol: '${Session.instance.currency} ');

  static Future<void> printReceipt({
    required String receiptNo,
    required List<(String, double, double, double)> lines, // name, qty, unit price, discount
    required double subtotal,
    required double discount,
    required double tax,
    required double total,
    required String paidMethod,
    required double paid,
    double widthMm = 80,
  }) async {
    final s = Session.instance;
    final doc = pw.Document();
    final style = pw.TextStyle(fontSize: 8);
    pw.Widget row(String a, String b, {bool bold = false}) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(a, style: bold ? style.copyWith(fontWeight: pw.FontWeight.bold) : style),
            pw.Text(b, style: bold ? style.copyWith(fontWeight: pw.FontWeight.bold) : style),
          ],
        );

    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(widthMm * PdfPageFormat.mm, double.infinity, marginAll: 4 * PdfPageFormat.mm),
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        pw.Text(s.tenantName, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        if (s.outlet != null) pw.Text(s.outlet!.name, textAlign: pw.TextAlign.center, style: style),
        pw.SizedBox(height: 4),
        row('Receipt', receiptNo),
        row('Date', DateFormat('d MMM yyyy HH:mm').format(DateTime.now())),
        pw.Divider(thickness: 0.5),
        for (final l in lines) ...[
          pw.Text(l.$1, style: style),
          row('  ${_q(l.$2)} × ${_money.format(l.$3)}', _money.format(l.$2 * l.$3 - l.$4)),
          if (l.$4 > 0) row('  discount', '-${_money.format(l.$4)}'),
        ],
        pw.Divider(thickness: 0.5),
        row('Subtotal', _money.format(subtotal)),
        if (discount > 0) row('Discount', '-${_money.format(discount)}'),
        if (tax > 0) row('Tax', _money.format(tax)),
        row('TOTAL', _money.format(total), bold: true),
        row('Paid ($paidMethod)', _money.format(paid)),
        if (paid > total) row('Change', _money.format(paid - total)),
        pw.SizedBox(height: 6),
        pw.Text('Thank you!', textAlign: pw.TextAlign.center, style: style),
      ]),
    ));
    await Printing.layoutPdf(name: 'Receipt $receiptNo', onLayout: (_) async => doc.save());
  }

  /// One label per page, sized for common thermal label rolls (default 40 × 30 mm).
  static Future<void> printLabels({
    required Variant variant,
    required int copies,
    double widthMm = 40,
    double heightMm = 30,
    bool showPrice = true,
  }) async {
    final code = variant.barcodes.isNotEmpty ? variant.barcodes.first.code : variant.sku;
    final barcode = isValidEan13(code) ? pw.Barcode.ean13() : pw.Barcode.code128();
    final doc = pw.Document();
    final format = PdfPageFormat(widthMm * PdfPageFormat.mm, heightMm * PdfPageFormat.mm, marginAll: 1.5 * PdfPageFormat.mm);
    for (var i = 0; i < copies; i++) {
      doc.addPage(pw.Page(
        pageFormat: format,
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          pw.Text(variant.displayName,
              maxLines: 2, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold)),
          if (showPrice) pw.Text(_money.format(variant.price), style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 1),
          pw.Expanded(child: pw.BarcodeWidget(barcode: barcode, data: code, textStyle: const pw.TextStyle(fontSize: 6))),
          pw.Text('SKU ${variant.sku}', style: const pw.TextStyle(fontSize: 5)),
        ]),
      ));
    }
    await Printing.layoutPdf(name: 'Labels ${variant.sku}', onLayout: (_) async => doc.save());
  }

  static String _q(double q) => q == q.roundToDouble() ? q.toInt().toString() : q.toString();
}
