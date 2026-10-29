import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session.dart';

/// Search seaports / airports by code, name or country; staff with fleet rights can add their own.
class PortPicker extends StatefulWidget {
  final String? kind; // 'sea' | 'air' | null for all
  const PortPicker({super.key, this.kind});

  static Future<Map<String, dynamic>?> show(BuildContext context, {String? kind}) =>
      showModalBottomSheet<Map<String, dynamic>>(context: context, isScrollControlled: true, builder: (_) => PortPicker(kind: kind));

  @override
  State<PortPicker> createState() => _PortPickerState();
}

class _PortPickerState extends State<PortPicker> {
  List<Map<String, dynamic>> _rows = [];
  String _q = '';
  AppSession get _s => AppSession.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var q = _s.db.from('ports').select('id, code, name, country_code, kind');
      if (widget.kind != null) q = q.eq('kind', widget.kind!);
      final t = _q.replaceAll(RegExp(r'[,()%]'), ' ').trim();
      if (t.isNotEmpty) q = q.or('code.ilike.%$t%,name.ilike.%$t%,country_code.ilike.$t');
      final rows = await q.order('country_code').order('name').limit(80);
      if (mounted) setState(() => _rows = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  Future<void> _add() async {
    final code = TextEditingController(text: _q.toUpperCase());
    final name = TextEditingController();
    final cc = TextEditingController();
    var kind = widget.kind ?? 'sea';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Add place'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'sea', label: Text('Sea')),
                ButtonSegment(value: 'air', label: Text('Air')),
                ButtonSegment(value: 'inland', label: Text('Inland')),
              ],
              selected: {kind},
              onSelectionChanged: (v) => set(() => kind = v.first),
            ),
            TextField(controller: code, decoration: const InputDecoration(labelText: 'Code (UN/LOCODE or IATA)')),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: cc, maxLength: 2, decoration: const InputDecoration(labelText: 'Country code (e.g. MY)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || code.text.trim().isEmpty || name.text.trim().isEmpty || cc.text.trim().length != 2) return;
    try {
      final row = await _s.db
          .from('ports')
          .insert({
            'tenant_id': _s.tenantId,
            'code': code.text.trim().toUpperCase(),
            'name': name.text.trim(),
            'country_code': cc.text.trim().toUpperCase(),
            'kind': kind,
          })
          .select('id, code, name, country_code, kind')
          .single();
      if (mounted) Navigator.pop(context, row);
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: widget.kind == 'air' ? 'Airport code, city or country' : 'Port code, name or country',
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onChanged: (v) {
                      _q = v.trim();
                      _load();
                    },
                  ),
                ),
                if (_s.can('log.fleet.manage')) IconButton.filled(onPressed: _add, icon: const Icon(Icons.add_location_alt_outlined)),
              ]),
            ),
            Expanded(
              child: ListView(children: [
                for (final p in _rows)
                  ListTile(
                    leading: Icon(p['kind'] == 'air' ? Icons.flight : (p['kind'] == 'sea' ? Icons.anchor : Icons.place_outlined)),
                    title: Text('${p['code']} · ${p['name']}'),
                    subtitle: Text(p['country_code'] as String),
                    onTap: () => Navigator.pop(context, p),
                  ),
                if (_rows.isEmpty) const ListTile(title: Text('Nothing found')),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

String portLabel(Map<String, dynamic>? p) => p == null ? '—' : '${p['code']} · ${p['name']}';
