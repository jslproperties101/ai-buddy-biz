import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

const activityIcons = <String, IconData>{
  'note': Icons.sticky_note_2_outlined,
  'call': Icons.call_outlined,
  'whatsapp': Icons.chat_outlined,
  'email': Icons.email_outlined,
  'meeting': Icons.groups_outlined,
  'task': Icons.task_alt,
  'visit': Icons.storefront_outlined,
  'system': Icons.info_outline,
};

/// Notes, calls, tasks and system events for a customer or a lead, with a box to add more.
class Timeline extends StatefulWidget {
  final String? contactId;
  final String? dealId;
  final String? supplierId;
  final String? shipmentId;
  final VoidCallback? onChanged;
  const Timeline({super.key, this.contactId, this.dealId, this.supplierId, this.shipmentId, this.onChanged})
      : assert(contactId != null || dealId != null || supplierId != null || shipmentId != null);

  @override
  State<Timeline> createState() => TimelineState();
}

class TimelineState extends State<Timeline> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  Session get _s => Session.instance;
  bool get _canWrite => widget.shipmentId != null
      ? _s.can('log.shipment.manage')
      : widget.supplierId != null
          ? _s.can('inv.supplier.manage')
          : _s.can('crm.deal.manage') || _s.can('crm.contact.manage');

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      var q = _s.db.from('activities').select().eq('tenant_id', _s.tenantId!);
      if (widget.shipmentId != null) {
        q = q.eq('shipment_id', widget.shipmentId!);
      } else if (widget.supplierId != null) {
        q = q.eq('supplier_id', widget.supplierId!);
      } else if (widget.dealId != null) {
        q = q.eq('deal_id', widget.dealId!);
      } else {
        q = q.eq('contact_id', widget.contactId!);
      }
      final rows = await q.order('created_at', ascending: false).limit(100);
      _rows = List<Map<String, dynamic>>.from(rows);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add() async {
    var kind = 'note';
    final body = TextEditingController();
    DateTime? due;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final k in const ['note', 'call', 'whatsapp', 'email', 'meeting', 'visit', 'task'])
                    ChoiceChip(
                      avatar: Icon(activityIcons[k], size: 18),
                      label: Text(k == 'whatsapp' ? 'WhatsApp' : '${k[0].toUpperCase()}${k.substring(1)}'),
                      selected: kind == k,
                      onSelected: (_) => set(() => kind = k),
                    ),
                ]),
                const SizedBox(height: 12),
                TextField(
                  controller: body,
                  autofocus: true,
                  maxLines: 4,
                  minLines: 2,
                  decoration: InputDecoration(
                    labelText: kind == 'task' ? 'What needs doing?' : 'What happened?',
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (kind == 'task' || kind == 'meeting')
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event),
                    title: Text(due == null ? 'Set due date' : DateFormat('EEE d MMM, HH:mm').format(due!)),
                    onTap: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: DateTime.now().add(const Duration(days: 1)),
                        firstDate: DateTime.now().subtract(const Duration(days: 1)),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (d == null || !context.mounted) return;
                      final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 10, minute: 0));
                      set(() => due = DateTime(d.year, d.month, d.day, t?.hour ?? 10, t?.minute ?? 0));
                    },
                  ),
                const SizedBox(height: 8),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
              ]),
            ),
          ),
        ),
      ),
    );
    if (ok != true || body.text.trim().isEmpty) return;
    try {
      await _s.db.from('activities').insert({
        'tenant_id': _s.tenantId,
        'contact_id': widget.contactId,
        'deal_id': widget.dealId,
        'supplier_id': widget.supplierId,
        'shipment_id': widget.shipmentId,
        'kind': kind,
        'body': body.text.trim(),
        if (due != null) 'due_at': due!.toUtc().toIso8601String(),
      });
      await reload();
      widget.onChanged?.call();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _toggleDone(Map<String, dynamic> a) async {
    try {
      await _s.db.from('activities').update({
        'done_at': a['done_at'] == null ? DateTime.now().toUtc().toIso8601String() : null,
      }).eq('id', a['id']);
      await reload();
      widget.onChanged?.call();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM yyyy, HH:mm');
    final err = Theme.of(context).colorScheme.error;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text('Activity', style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        if (_canWrite) TextButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Log / task')),
      ]),
      if (_loading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
      if (!_loading && _rows.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Nothing yet')),
      for (final a in _rows)
        Builder(builder: (_) {
          final isTask = a['kind'] == 'task' || a['kind'] == 'meeting';
          final done = a['done_at'] != null;
          final due = a['due_at'] == null ? null : DateTime.parse(a['due_at'] as String).toLocal();
          final overdue = isTask && !done && due != null && due.isBefore(DateTime.now());
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: isTask
                ? Checkbox(value: done, onChanged: _canWrite ? (_) => _toggleDone(a) : null)
                : Icon(activityIcons[a['kind']] ?? Icons.circle_outlined),
            title: Text(a['body'] as String? ?? '',
                style: TextStyle(decoration: done ? TextDecoration.lineThrough : null,
                    color: a['kind'] == 'system' ? Theme.of(context).colorScheme.outline : null)),
            subtitle: Text(
              [
                fmt.format(DateTime.parse(a['created_at'] as String).toLocal()),
                if (due != null) 'due ${fmt.format(due)}',
              ].join(' · '),
              style: TextStyle(color: overdue ? err : null),
            ),
          );
        }),
    ]);
  }
}
