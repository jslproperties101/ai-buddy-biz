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

  /// A4 tax invoice. Shows seller and buyer tax IDs and the e-invoice reference when validated.
  static Future<void> printInvoice({
    required Map<String, dynamic> invoice,
    required Map<String, dynamic>? contact,
    required List<Map<String, dynamic>> lines,
  }) async {
    final s = Session.instance;
    final seller = await s.db
        .from('tenants')
        .select('name, tin, tax_registration_no')
        .eq('id', s.tenantId!)
        .maybeSingle();
    final doc = pw.Document();
    final small = const pw.TextStyle(fontSize: 9);
    final bold = pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold);
    String m(dynamic v) => _money.format((v as num).toDouble());
    final status = invoice['status'] as String;
    final balance = (invoice['total'] as num).toDouble() - (invoice['amount_paid'] as num).toDouble();

    pw.Widget kv(String k, String? v) =>
        v == null || v.isEmpty ? pw.SizedBox() : pw.Text('$k: $v', style: small);

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      build: (_) => [
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text((seller?['name'] ?? s.tenantName) as String, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
            kv('TIN', seller?['tin'] as String?),
            kv('Tax reg. no.', seller?['tax_registration_no'] as String?),
          ]),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text(status == 'void' ? 'VOID INVOICE' : 'TAX INVOICE',
                style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            pw.Text('No. ${invoice['number'] ?? 'DRAFT'}', style: bold),
            kv('Date', invoice['issue_date'] as String?),
            kv('Due', invoice['due_date'] as String?),
          ]),
        ]),
        pw.SizedBox(height: 16),
        pw.Text('Bill to', style: bold),
        if (contact != null) ...[
          pw.Text((contact['company'] ?? contact['name']) as String, style: small),
          if (contact['company'] != null) pw.Text(contact['name'] as String, style: small),
          kv('TIN', contact['tin'] as String?),
          kv('Reg. no.', contact['reg_no'] as String?),
          kv('Email', contact['email'] as String?),
          kv('Phone', contact['phone'] as String?),
        ],
        pw.SizedBox(height: 16),
        pw.TableHelper.fromTextArray(
          headerStyle: bold,
          cellStyle: small,
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          cellAlignments: {
            1: pw.Alignment.centerRight,
            2: pw.Alignment.centerRight,
            3: pw.Alignment.centerRight,
            4: pw.Alignment.centerLeft,
            5: pw.Alignment.centerRight,
          },
          headers: ['Description', 'Qty', 'Unit price', 'Discount', 'Tax', 'Amount'],
          data: [
            for (final l in lines)
              [
                l['description'],
                _q((l['qty'] as num).toDouble()),
                m(l['unit_price']),
                (l['discount'] as num) == 0 ? '' : m(l['discount']),
                '${l['tax_name'] ?? ''}${(l['tax_amount'] as num) > 0 ? ' ${m(l['tax_amount'])}' : ''}',
                m(l['line_total']),
              ]
          ],
        ),
        pw.SizedBox(height: 12),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.SizedBox(
            width: 220,
            child: pw.Column(children: [
              for (final r in [
                ('Subtotal', invoice['subtotal']),
                if ((invoice['discount_total'] as num) > 0) ('Discount', -(invoice['discount_total'] as num)),
                ('Tax', invoice['tax_total']),
                ('Total', invoice['total']),
                if ((invoice['amount_paid'] as num) > 0) ('Paid', -(invoice['amount_paid'] as num)),
                if (status != 'void' && status != 'draft') ('Balance due', balance),
              ])
                pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                  pw.Text(r.$1, style: r.$1 == 'Total' || r.$1 == 'Balance due' ? bold : small),
                  pw.Text(m(r.$2), style: r.$1 == 'Total' || r.$1 == 'Balance due' ? bold : small),
                ]),
            ]),
          ),
        ),
        if (invoice['notes'] != null) ...[
          pw.SizedBox(height: 16),
          pw.Text(invoice['notes'] as String, style: small),
        ],
        if (invoice['einvoice_uuid'] != null) ...[
          pw.SizedBox(height: 16),
          pw.Row(children: [
            pw.SizedBox(
              width: 70,
              height: 70,
              child: pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: invoice['einvoice_uuid'] as String),
            ),
            pw.SizedBox(width: 8),
            pw.Text('e-Invoice validated\nUUID ${invoice['einvoice_uuid']}', style: small),
          ]),
        ],
      ],
    ));
    await Printing.layoutPdf(name: 'Invoice ${invoice['number'] ?? 'draft'}', onLayout: (_) async => doc.save());
  }

  static String _q(double q) => q == q.roundToDouble() ? q.toInt().toString() : q.toString();
}
