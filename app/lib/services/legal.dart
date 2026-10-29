import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'session.dart';

/// Shared helpers for the Legal module: template filling, statuses, signing links and the AI assistant.
class Legal {
  Legal._();

  static final _blank = RegExp(r'\{\{([a-z_]+)\}\}');
  static final dateFmt = DateFormat('d MMM yyyy');

  static const categories = {
    'nda': 'Non-disclosure (NDA)',
    'employment': 'Employment',
    'service': 'Services',
    'sales_terms': 'Sales terms',
    'supplier': 'Supplier',
    'tenancy': 'Tenancy',
    'privacy': 'Privacy notice',
    'letter': 'Letter',
    'other': 'Other',
  };

  static const statusLabels = {
    'draft': 'Draft',
    'in_review': 'In review',
    'out_for_signature': 'Out for signature',
    'partially_signed': 'Partly signed',
    'signed': 'Signed',
    'expired': 'Expired',
    'terminated': 'Terminated',
    'cancelled': 'Cancelled',
  };

  static const obligationKinds = {
    'renewal_notice': 'Renewal notice',
    'expiry': 'Expiry',
    'payment': 'Payment',
    'deliverable': 'Deliverable',
    'deadline': 'Deadline',
    'review': 'Review',
    'other': 'Other',
  };

  static bool editable(String status) => status == 'draft' || status == 'in_review';

  /// Keys of the {{blanks}} still left in a text, in order of first appearance.
  static List<String> blanks(String body) {
    final seen = <String>{};
    return [for (final m in _blank.allMatches(body)) if (seen.add(m.group(1)!)) m.group(1)!];
  }

  /// Replace {{key}} with values; anything without a value stays as a blank.
  static String fill(String body, Map<String, String> values) => body.replaceAllMapped(_blank, (m) {
        final v = values[m.group(1)!]?.trim();
        return (v == null || v.isEmpty) ? m.group(0)! : v;
      });

  /// Company details that every template can use.
  static Future<Map<String, String>> companyValues() async {
    final s = Session.instance;
    final t = await s.db
        .from('tenants')
        .select('name, legal_name, company_reg_no, address, phone, email')
        .eq('id', s.tenantId!)
        .single();
    String v(String k) => (t[k] ?? '').toString().trim();
    return {
      'company_name': v('legal_name').isNotEmpty ? v('legal_name') : v('name'),
      'company_reg_no': v('company_reg_no'),
      'company_address': v('address'),
      'company_phone': v('phone'),
      'company_email': v('email'),
      'currency': s.currency == 'MYR' ? 'RM' : s.currency,
    };
  }

  static String signBase() => AppConfig.signUrl;
  static String signLink(String token) => '${AppConfig.signUrl}?t=$token';
  static String verifyLink(String hash) => '${AppConfig.signUrl}?verify=$hash';

  static String fmtDate(dynamic v) {
    if (v == null) return '—';
    final d = DateTime.tryParse(v.toString());
    return d == null ? v.toString() : dateFmt.format(d.toLocal());
  }

  static String isoDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  /// Calls the ai-legal edge function. Throws a readable message on failure.
  static Future<Map<String, dynamic>> ai(String kind,
      {String? contractId, String? text, String? question, String? instructions, String? baseText}) async {
    final s = Session.instance;
    try {
      final r = await s.db.functions.invoke('ai-legal', body: {
        'tenant_id': s.tenantId,
        'kind': kind,
        if (contractId != null) 'contract_id': contractId,
        if (text != null) 'text': text,
        if (question != null) 'question': question,
        if (instructions != null) 'instructions': instructions,
        if (baseText != null) 'base_text': baseText,
      });
      final data = r.data;
      if (data is Map && data['result'] is Map) return Map<String, dynamic>.from(data['result'] as Map);
      throw Exception((data is Map ? data['error'] : null) ?? 'No answer from the AI');
    } on FunctionException catch (e) {
      final d = e.details;
      throw Exception(d is Map && d['error'] != null ? d['error'] : 'AI request failed (${e.status})');
    }
  }

  static Future<Map<String, dynamic>?> quota() async {
    final s = Session.instance;
    try {
      final q = await s.db.rpc('ai_quota', params: {'p_tenant': s.tenantId});
      return q == null ? null : Map<String, dynamic>.from(q as Map);
    } catch (_) {
      return null;
    }
  }

  static String errorText(Object e) {
    if (e is PostgrestException) return e.message;
    final t = e.toString();
    return t.startsWith('Exception: ') ? t.substring(11) : t;
  }
}
