import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../services/crm.dart';
import '../services/session.dart';

class CrmSettingsScreen extends StatefulWidget {
  const CrmSettingsScreen({super.key});
  @override
  State<CrmSettingsScreen> createState() => _CrmSettingsScreenState();
}

class _CrmSettingsScreenState extends State<CrmSettingsScreen> {
  bool _loading = true;
  bool _enabled = true;
  final _perUnit = TextEditingController();
  final _value = TextEditingController();
  final _min = TextEditingController();
  String? _formKey;
  Map<String, bool> _configured = {};
  List<Map<String, dynamic>> _stages = [];

  Session get _s => Session.instance;
  bool get _canManage => _s.can('crm.settings.manage');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await Crm.instance.load();
      final l = Crm.instance.loyalty;
      _enabled = l.enabled;
      _perUnit.text = _n(l.pointsPerUnit);
      _value.text = _n(l.pointValue);
      _min.text = _n(l.minRedeem);
      _formKey = Crm.instance.leadFormKey;
      final st = await _s.db.rpc('integration_status', params: {'p_tenant': _s.tenantId}) as List;
      _configured = {for (final r in st) r['provider'] as String: r['configured'] as bool};
      _stages = List<Map<String, dynamic>>.from(await _s.db
          .from('pipeline_stages')
          .select('id, name, probability, kind, sort_order, pipelines!inner(is_default)')
          .eq('tenant_id', _s.tenantId!)
          .eq('pipelines.is_default', true)
          .order('sort_order'));
    } catch (e) {
      _snack('Could not load: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  String _n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _saveLoyalty({bool rotate = false}) async {
    try {
      await _s.db.rpc('update_crm_settings', params: {
        'p_tenant': _s.tenantId,
        'p_settings': {
          'loyalty': {
            'enabled': _enabled,
            'points_per_unit': double.tryParse(_perUnit.text) ?? 0,
            'point_value': double.tryParse(_value.text) ?? 0,
            'min_redeem': double.tryParse(_min.text) ?? 0,
          },
          if (rotate) 'rotate_lead_form_key': true,
        },
      });
      await _load();
      _snack(rotate ? 'New form key created. Update your website form.' : 'Saved');
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _connect(String provider) async {
    final fields = switch (provider) {
      'whatsapp_cloud' => [('phone_number_id', 'Phone number ID'), ('token', 'Permanent access token'), ('api_version', 'API version (e.g. v21.0)')],
      'resend' => [('api_key', 'Resend API key'), ('from', 'From, e.g. Shop <hello@yourshop.com>')],
      _ => [('account_sid', 'Account SID'), ('auth_token', 'Auth token'), ('from', 'From number, e.g. +60…')],
    };
    final ctrls = {for (final f in fields) f.$1: TextEditingController(text: f.$1 == 'api_version' ? 'v21.0' : '')};
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(switch (provider) { 'whatsapp_cloud' => 'Connect WhatsApp', 'resend' => 'Connect email', _ => 'Connect SMS' }),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final f in fields)
              TextField(
                controller: ctrls[f.$1],
                obscureText: f.$1.contains('token') || f.$1.contains('key'),
                decoration: InputDecoration(labelText: f.$2),
              ),
            const SizedBox(height: 8),
            const Text('Keys are stored securely on the server and are never shown again in the app.', style: TextStyle(fontSize: 12)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final cfg = {for (final e in ctrls.entries) if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim()};
    if (cfg.length < fields.length - (provider == 'whatsapp_cloud' ? 1 : 0)) {
      _snack('Fill in all fields');
      return;
    }
    try {
      await _s.db.rpc('set_integration_secret', params: {'p_tenant': _s.tenantId, 'p_provider': provider, 'p_config': cfg});
      await _load();
      _snack('Connected');
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _editStage(Map<String, dynamic> st) async {
    final name = TextEditingController(text: st['name'] as String);
    final prob = TextEditingController(text: '${st['probability']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Edit stage'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
          if (st['kind'] == 'open')
            TextField(
              controller: prob,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Chance of winning (%)'),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    try {
      await _s.db.from('pipeline_stages').update({
        'name': name.text.trim(),
        if (st['kind'] == 'open') 'probability': (int.tryParse(prob.text) ?? 0).clamp(0, 100),
      }).eq('id', st['id']);
      _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final example = (double.tryParse(_perUnit.text) ?? 0) * 100;
    final worth = (double.tryParse(_value.text) ?? 0) * example;
    return Scaffold(
      appBar: AppBar(title: const Text('CRM settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Text('Loyalty points', style: t.titleMedium),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Customers earn points'),
                value: _enabled,
                onChanged: _canManage ? (v) => setState(() => _enabled = v) : null,
              ),
              Row(children: [
                Expanded(child: _numField(_perUnit, 'Points per ${_s.currency} 1')),
                const SizedBox(width: 12),
                Expanded(child: _numField(_value, 'Value of 1 point (${_s.currency})')),
              ]),
              _numField(_min, 'Minimum points to redeem'),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('Example: spending ${_s.currency} 100 earns ${example.toInt()} points, worth ${_s.currency} ${worth.toStringAsFixed(2)}.',
                    style: t.bodySmall),
              ),
              if (_canManage) FilledButton(onPressed: () => _saveLoyalty(), child: const Text('Save loyalty rules')),
              const Divider(height: 32),
              Text('Website lead form', style: t.titleMedium),
              const SizedBox(height: 4),
              const Text('Enquiries from your website arrive as new leads. Use web/lead-form.html from the project with these values.'),
              if (_formKey != null) ...[
                const SizedBox(height: 8),
                SelectableText('Form key: $_formKey'),
                SelectableText('Project URL: ${AppConfig.supabaseUrl}'),
                Wrap(spacing: 8, children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _formKey!));
                      _snack('Form key copied');
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy key'),
                  ),
                  TextButton(onPressed: () => _saveLoyalty(rotate: true), child: const Text('Make new key')),
                ]),
              ] else
                const Text('Only owners and admins can see the form key.'),
              const Divider(height: 32),
              Text('Messaging connections', style: t.titleMedium),
              for (final p in const [
                ('whatsapp_cloud', 'WhatsApp Business (Meta Cloud API)', Icons.chat_outlined),
                ('resend', 'Email (Resend)', Icons.email_outlined),
                ('twilio', 'SMS (Twilio)', Icons.sms_outlined),
              ])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(p.$3),
                  title: Text(p.$2),
                  subtitle: Text(_configured[p.$1] == true ? 'Connected' : 'Not connected'),
                  trailing: _canManage ? TextButton(onPressed: () => _connect(p.$1), child: Text(_configured[p.$1] == true ? 'Replace' : 'Connect')) : null,
                ),
              const Divider(height: 32),
              Text('Pipeline stages', style: t.titleMedium),
              for (final st in _stages)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(st['name'] as String),
                  subtitle: Text(st['kind'] == 'open' ? '${st['probability']}% chance' : st['kind'] as String),
                  trailing: _canManage ? const Icon(Icons.edit_outlined) : null,
                  onTap: _canManage ? () => _editStage(st) : null,
                ),
              const SizedBox(height: 40),
            ]),
    );
  }

  Widget _numField(TextEditingController c, String label) => TextField(
        controller: c,
        enabled: _canManage,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label),
        onChanged: (_) => setState(() {}),
      );
}
