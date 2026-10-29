import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/catalog.dart';
import '../services/printing_service.dart';
import '../services/session.dart';
import '../widgets/contact_picker.dart';

class _Line {
  String? variantId;
  final description = TextEditingController();
  final qty = TextEditingController(text: '1');
  final price = TextEditingController();
  final discount = TextEditingController();
  String? taxCode; // null = product's code or business default
  String? productTaxCode;
  double? serverTax; // values the server stored (issued invoices)
  double? serverTotal;
}

class InvoiceEditScreen extends StatefulWidget {
  final String? invoiceId;
  const InvoiceEditScreen({super.key, this.invoiceId});
  @override
  State<InvoiceEditScreen> createState() => _InvoiceEditScreenState();
}

class _InvoiceEditScreenState extends State<InvoiceEditScreen> {
  String? _id;
  Map<String, dynamic>? _inv; // server copy
  Map<String, dynamic>? _contact;
  final List<_Line> _lines = [];
  final _notes = TextEditingController();
  DateTime? _due;
  List<Map<String, dynamic>> _payments = [];
  bool _loading = true;
  bool _busy = false;

  AppSession get _s => AppSession.instance;
  NumberFormat get _money => NumberFormat.currency(symbol: '${_s.currency} ');
  bool get _draft => _inv == null || _inv!['status'] == 'draft';
  bool get _canManage => _s.can('fin.invoice.manage');

  @override
  void initState() {
    super.initState();
    _id = widget.invoiceId;
    _load();
  }

  Future<void> _load() async {
    if (_id == null) {
      _lines.add(_Line());
      setState(() => _loading = false);
      return;
    }
    try {
      final inv = await _s.db
          .from('invoices')
          .select('*, contacts(*), invoice_lines(*), invoice_payments(*)')
          .eq('id', _id!)
          .single();
      _inv = inv;
      _contact = inv['contacts'] as Map<String, dynamic>?;
      _notes.text = (inv['notes'] ?? '') as String;
      _due = inv['due_date'] == null ? null : DateTime.parse(inv['due_date'] as String);
      final ls = List<Map<String, dynamic>>.from(inv['invoice_lines'] as List)
        ..sort((a, b) => (a['sort_order'] as int).compareTo(b['sort_order'] as int));
      _lines.clear();
      for (final l in ls) {
        final x = _Line()
          ..variantId = l['variant_id'] as String?
          ..taxCode = l['tax_code'] as String?
          ..serverTax = (l['tax_amount'] as num).toDouble()
          ..serverTotal = (l['line_total'] as num).toDouble();
        x.description.text = l['description'] as String;
        x.qty.text = _n(l['qty']);
        x.price.text = (l['unit_price'] as num).toStringAsFixed(2);
        if ((l['discount'] as num) > 0) x.discount.text = (l['discount'] as num).toStringAsFixed(2);
        x.productTaxCode = Catalog.instance.variants.where((v) => v.id == x.variantId).firstOrNull?.taxCode;
        _lines.add(x);
      }
      _payments = List<Map<String, dynamic>>.from(inv['invoice_payments'] as List);
    } catch (e) {
      _snack('Could not load: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  String _n(dynamic v) {
    final d = (v as num).toDouble();
    return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // ---- totals preview (server recalculates on save) ----
  (double, double, double) _lineMath(_Line l) {
    final q = double.tryParse(l.qty.text) ?? 0;
    final p = double.tryParse(l.price.text) ?? 0;
    final d = double.tryParse(l.discount.text) ?? 0;
    final net = ((q * p - d) * 100).roundToDouble() / 100;
    final t = _s.taxFor(l.taxCode ?? l.productTaxCode);
    final tax = (((t.inclusive ? net - net / (1 + t.rate) : net * t.rate)) * 100).roundToDouble() / 100;
    return (net, tax, t.inclusive ? net : net + tax);
  }

  double get _taxPreview => _lines.fold<double>(0.0, (a, l) => a + _lineMath(l).$2);
  double get _totalPreview => _lines.fold<double>(0.0, (a, l) => a + _lineMath(l).$3);

  // ---- customer ----
  Future<void> _pickContact() async {
    final picked = await ContactPicker.show(context);
    if (picked != null) setState(() => _contact = picked);
  }

  // ---- lines ----
  Future<void> _addProductLine() async {
    final v = await showModalBottomSheet<Variant>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ProductPicker(),
    );
    if (v == null) return;
    setState(() {
      if (_lines.length == 1 && _lines.first.description.text.isEmpty && _lines.first.price.text.isEmpty) _lines.clear();
      final l = _Line()
        ..variantId = v.id
        ..productTaxCode = v.taxCode;
      l.description.text = v.displayName;
      l.price.text = v.price.toStringAsFixed(2);
      _lines.add(l);
    });
  }

  // ---- save / actions ----
  Future<bool> _saveDraft() async {
    if (_contact == null) {
      _snack('Choose a customer');
      return false;
    }
    final valid = _lines.where((l) => l.description.text.trim().isNotEmpty).toList();
    if (valid.isEmpty) {
      _snack('Add at least one line');
      return false;
    }
    for (final l in valid) {
      if ((double.tryParse(l.qty.text) ?? 0) <= 0) {
        _snack('Quantity must be more than 0 for "${l.description.text}"');
        return false;
      }
      if (double.tryParse(l.price.text) == null) {
        _snack('Enter a price for "${l.description.text}"');
        return false;
      }
    }
    setState(() => _busy = true);
    try {
      final header = {
        'tenant_id': _s.tenantId,
        'outlet_id': _s.outlet?.id,
        'contact_id': _contact!['id'],
        'currency': _s.currency,
        'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        'due_date': _due == null ? null : DateFormat('yyyy-MM-dd').format(_due!),
      };
      if (_id == null) {
        final r = await _s.db.from('invoices').insert(header).select('id').single();
        _id = r['id'] as String;
      } else {
        header.remove('outlet_id');
        await _s.db.from('invoices').update(header).eq('id', _id!);
        await _s.db.from('invoice_lines').delete().eq('invoice_id', _id!);
      }
      await _s.db.from('invoice_lines').insert([
        for (var i = 0; i < valid.length; i++)
          {
            'invoice_id': _id,
            'tenant_id': _s.tenantId,
            'variant_id': valid[i].variantId,
            'description': valid[i].description.text.trim(),
            'qty': double.parse(valid[i].qty.text),
            'unit_price': double.parse(valid[i].price.text),
            'discount': double.tryParse(valid[i].discount.text) ?? 0,
            'tax_code': valid[i].taxCode,
            'sort_order': i,
          }
      ]);
      return true;
    } on PostgrestException catch (e) {
      _snack(e.message);
      return false;
    } catch (e) {
      _snack('Could not save: $e');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (await _saveDraft()) {
      _snack('Draft saved');
      setState(() => _loading = true);
      await _load();
    }
  }

  Future<void> _issue() async {
    if (!await _saveDraft()) return;
    final ok = await _confirm('Issue invoice?', 'It gets a number, stock is taken and it is posted to your accounts. '
        'After this it can only be paid or voided.');
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final r = await _s.db.rpc('issue_invoice', params: {'p_invoice': _id});
      _snack('Issued ${r['number']}');
      setState(() => _loading = true);
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteDraft() async {
    if (_id == null) {
      Navigator.of(context).pop();
      return;
    }
    if (!await _confirm('Delete draft?', 'This draft will be removed.')) return;
    try {
      await _s.db.from('invoices').delete().eq('id', _id!);
      if (mounted) Navigator.of(context).pop();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _recordPayment() async {
    final balance = (_inv!['total'] as num).toDouble() - (_inv!['amount_paid'] as num).toDouble();
    final amount = TextEditingController(text: balance.toStringAsFixed(2));
    final ref = TextEditingController();
    var method = 'bank_transfer';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Record payment'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Balance ${_money.format(balance)}'),
            TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Amount'),
            ),
            DropdownButtonFormField<String>(
              value: method,
              decoration: const InputDecoration(labelText: 'Method'),
              items: const [
                DropdownMenuItem(value: 'bank_transfer', child: Text('Bank transfer')),
                DropdownMenuItem(value: 'cash', child: Text('Cash')),
                DropdownMenuItem(value: 'card', child: Text('Card')),
                DropdownMenuItem(value: 'qr', child: Text('QR')),
                DropdownMenuItem(value: 'ewallet', child: Text('E-wallet')),
                DropdownMenuItem(value: 'cheque', child: Text('Cheque')),
              ],
              onChanged: (v) => set(() => method = v!),
            ),
            TextField(controller: ref, decoration: const InputDecoration(labelText: 'Reference (optional)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Record')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await _s.db.rpc('record_invoice_payment', params: {
        'p_invoice': _id,
        'p_amount': double.tryParse(amount.text) ?? 0,
        'p_method': method,
        'p_reference': ref.text.trim().isEmpty ? null : ref.text.trim(),
      });
      setState(() => _loading = true);
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _void() async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Void ${_inv!['number']}?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Stock goes back and the invoice is reversed in your accounts.'),
          TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason (required)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Void')),
        ],
      ),
    );
    if (ok != true || reason.text.trim().isEmpty) return;
    try {
      await _s.db.rpc('void_invoice', params: {'p_invoice': _id, 'p_reason': reason.text.trim()});
      setState(() => _loading = true);
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _print() async {
    if (_inv == null) return;
    await PrintingService.printInvoice(
      invoice: _inv!,
      contact: _contact,
      lines: List<Map<String, dynamic>>.from(_inv!['invoice_lines'] as List)
        ..sort((a, b) => (a['sort_order'] as int).compareTo(b['sort_order'] as int)),
    );
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final status = (_inv?['status'] ?? 'draft') as String;
    final title = _inv?['number'] as String? ?? (_id == null ? 'New invoice' : 'Draft invoice');
    final editable = _draft && _canManage;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (!_draft) IconButton(onPressed: _print, icon: const Icon(Icons.print_outlined), tooltip: 'Print / share PDF'),
          if (editable) TextButton(onPressed: _busy ? null : _save, child: const Text('Save')),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (!_draft) _statusCard(status),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(_contact?['company'] as String? ?? _contact?['name'] as String? ?? 'Choose customer'),
                  subtitle: _contact == null
                      ? null
                      : Text([
                          if (_contact!['company'] != null) _contact!['name'],
                          if (_contact!['tin'] != null) 'TIN ${_contact!['tin']}',
                          if (_contact!['email'] != null) _contact!['email'],
                        ].join(' · ')),
                  trailing: editable ? const Icon(Icons.chevron_right) : null,
                  onTap: editable ? _pickContact : null,
                ),
              ),
              if (editable)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_outlined),
                  title: Text(_due == null ? 'Due date: default terms' : 'Due ${DateFormat('d MMM yyyy').format(_due!)}'),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _due ?? DateTime.now().add(const Duration(days: 30)),
                      firstDate: DateTime.now().subtract(const Duration(days: 365)),
                      lastDate: DateTime.now().add(const Duration(days: 730)),
                    );
                    if (d != null) setState(() => _due = d);
                  },
                ),
              const SizedBox(height: 8),
              Text('Items', style: Theme.of(context).textTheme.titleMedium),
              for (var i = 0; i < _lines.length; i++) editable ? _lineEditor(i) : _lineView(_lines[i]),
              if (editable)
                Wrap(spacing: 8, children: [
                  OutlinedButton.icon(
                      onPressed: _addProductLine, icon: const Icon(Icons.inventory_2_outlined), label: const Text('Add product')),
                  OutlinedButton.icon(
                      onPressed: () => setState(() => _lines.add(_Line())),
                      icon: const Icon(Icons.edit_note),
                      label: const Text('Add custom line')),
                ]),
              const Divider(height: 32),
              _totals(),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                enabled: editable,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Notes for the customer', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              if (editable) ...[
                FilledButton(onPressed: _busy ? null : _issue, child: const Text('Issue invoice')),
                TextButton(onPressed: _busy ? null : _deleteDraft, child: const Text('Delete draft')),
              ],
              if ((status == 'issued' || status == 'partial') && _s.can('fin.payment.record'))
                FilledButton.icon(onPressed: _recordPayment, icon: const Icon(Icons.payments_outlined), label: const Text('Record payment')),
              if (status != 'draft' && status != 'void' && _canManage && (_inv!['amount_paid'] as num) == 0)
                TextButton(onPressed: _void, child: const Text('Void invoice')),
              if (_payments.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Payments', style: Theme.of(context).textTheme.titleMedium),
                for (final p in _payments)
                  ListTile(
                    dense: true,
                    title: Text('${p['paid_on']} · ${p['method']}'),
                    subtitle: p['reference'] == null ? null : Text(p['reference'] as String),
                    trailing: Text(_money.format(p['amount'])),
                  ),
              ],
              const SizedBox(height: 40),
            ]),
    );
  }

  Widget _statusCard(String status) {
    final inv = _inv!;
    final balance = (inv['total'] as num).toDouble() - (inv['amount_paid'] as num).toDouble();
    final c = Theme.of(context).colorScheme;
    return Card(
      color: status == 'paid' ? c.primaryContainer : (status == 'void' ? c.surfaceContainerHighest : c.secondaryContainer),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(status.toUpperCase(), style: Theme.of(context).textTheme.titleMedium),
          Text('Issued ${inv['issue_date']} · due ${inv['due_date']}'),
          if (status != 'void') Text('Balance ${_money.format(balance)}'),
          if (inv['einvoice_status'] != 'not_required') Text('e-Invoice: ${inv['einvoice_status']}'),
        ]),
      ),
    );
  }

  Widget _lineView(_Line l) {
    final m = _lineMath(l);
    final tax = l.serverTax ?? m.$2;
    final total = l.serverTotal ?? m.$3;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(l.description.text),
      subtitle: Text('${l.qty.text} × ${l.price.text}${l.discount.text.isNotEmpty ? ' − ${l.discount.text}' : ''}'
          '${tax > 0 ? ' · tax ${_money.format(tax)}' : ''}'),
      trailing: Text(_money.format(total)),
    );
  }

  Widget _lineEditor(int i) {
    final l = _lines[i];
    final codes = _s.taxTable.keys.toList()..sort();
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: l.description,
                decoration: const InputDecoration(labelText: 'Description', isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => setState(() => _lines.removeAt(i))),
          ]),
          Row(children: [
            Expanded(
              child: TextField(
                controller: l.qty,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Qty', isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextField(
                controller: l.price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Unit price', isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: l.discount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Disc.', isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
          DropdownButtonFormField<String?>(
            value: codes.contains(l.taxCode) ? l.taxCode : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Tax', isDense: true),
            items: [
              DropdownMenuItem<String?>(
                  value: null, child: Text('Default (${_s.taxFor(l.productTaxCode).name})')),
              for (final c in codes) DropdownMenuItem<String?>(value: c, child: Text(_s.taxTable[c]!.name)),
            ],
            onChanged: (v) => setState(() => l.taxCode = v),
          ),
          Align(alignment: Alignment.centerRight, child: Text(_money.format(_lineMath(l).$3))),
        ]),
      ),
    );
  }

  Widget _totals() {
    final useServer = !_draft && _inv != null;
    final tax = useServer ? (_inv!['tax_total'] as num).toDouble() : _taxPreview;
    final total = useServer ? (_inv!['total'] as num).toDouble() : _totalPreview;
    Widget row(String a, double v, {bool bold = false}) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(a, style: bold ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 18) : null),
            Text(_money.format(v), style: bold ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 18) : null),
          ],
        );
    return Column(children: [
      row('Tax', tax),
      row('Total', total, bold: true),
      if (!useServer) Text('Final tax is checked when saved', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

class _ProductPicker extends StatefulWidget {
  const _ProductPicker();
  @override
  State<_ProductPicker> createState() => _ProductPickerState();
}

class _ProductPickerState extends State<_ProductPicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final list = Catalog.instance.search(_q).take(50).toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Search products', prefixIcon: Icon(Icons.search)),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: ListView(children: [
              for (final v in list)
                ListTile(
                  title: Text(v.displayName),
                  subtitle: Text(v.sku),
                  trailing: Text(v.price.toStringAsFixed(2)),
                  onTap: () => Navigator.pop(context, v),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
