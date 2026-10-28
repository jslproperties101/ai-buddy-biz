import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../services/session.dart';

/// Web forms that drop enquiries straight into Customers + Pipeline + a follow-up task.
class LeadFormsScreen extends StatefulWidget {
  const LeadFormsScreen({super.key});
  @override
  State<LeadFormsScreen> createState() => _LeadFormsScreenState();
}

class _LeadFormsScreenState extends State<LeadFormsScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  Session get _s => Session.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _s.db.from('lead_forms').select().eq('tenant_id', _s.tenantId!).order('created_at');
      _rows = List<Map<String, dynamic>>.from(r);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _new() async {
    final name = TextEditingController(text: 'Website enquiry');
    final tags = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New lead form'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Form name')),
          TextField(controller: tags, decoration: const InputDecoration(labelText: 'Tag new leads with', hintText: 'web, raya-promo')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    try {
      await _s.db.from('lead_forms').insert({
        'tenant_id': _s.tenantId,
        'name': name.text.trim(),
        'owner_id': _s.db.auth.currentUser!.id,
        'tags': tags.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
      });
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  String _snippet(Map<String, dynamic> f) {
    final consent = (f['consent_text'] ?? 'I agree to be contacted.') as String;
    return '''<!-- ${AppConfig.appName} lead form: ${f['name']} -->
<form id="abb-lead" style="max-width:420px;display:grid;gap:8px;font-family:sans-serif">
  <input name="name" placeholder="Your name" required>
  <input name="phone" placeholder="Phone / WhatsApp">
  <input name="email" type="email" placeholder="Email">
  <textarea name="message" placeholder="How can we help?"></textarea>
  <input name="website" style="display:none" tabindex="-1" autocomplete="off">
  <label><input type="checkbox" name="consent"> $consent</label>
  <button type="submit">Send</button>
  <p id="abb-msg"></p>
</form>
<script>
document.getElementById('abb-lead').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = new FormData(e.target);
  const p = Object.fromEntries(f.entries());
  p.consent = f.get('consent') === 'on';
  const r = await fetch('${AppConfig.supabaseUrl}/rest/v1/rpc/submit_lead', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'apikey': '${AppConfig.supabaseAnonKey}' },
    body: JSON.stringify({ p_key: '${f['public_key']}', p })
  });
  const out = await r.json().catch(() => ({}));
  document.getElementById('abb-msg').textContent = r.ok ? 'Thank you! We will be in touch soon.' : (out.message || 'Something went wrong');
  if (r.ok) e.target.reset();
});
</script>''';
  }

  Future<void> _toggle(Map<String, dynamic> f) async {
    await _s.db.from('lead_forms').update({'active': !(f['active'] as bool)}).eq('id', f['id'] as String);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Lead forms')),
      floatingActionButton: FloatingActionButton(onPressed: _new, child: const Icon(Icons.add)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(12), children: [
              const Text(
                'Put a form on your website. Each enquiry becomes a lead with a deal in your pipeline and a follow-up task for tomorrow. '
                'Consent is recorded when the person ticks the box.',
              ),
              const SizedBox(height: 12),
              if (_rows.isEmpty) const Card(child: ListTile(title: Text('No forms yet — tap + to create one'))),
              for (final f in _rows)
                Card(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    ListTile(
                      title: Text(f['name'] as String),
                      subtitle: Text('${f['submissions']} enquiries · ${f['active'] == true ? 'live' : 'paused'}'),
                      trailing: Switch(value: f['active'] as bool, onChanged: (_) => _toggle(f)),
                    ),
                    OverflowBar(alignment: MainAxisAlignment.end, children: [
                      TextButton.icon(
                        icon: const Icon(Icons.code),
                        label: const Text('Copy website code'),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: _snippet(f)));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Copied. Paste it into your website where the form should appear.')));
                          }
                        },
                      ),
                    ]),
                  ]),
                ),
            ]),
    );
  }
}
