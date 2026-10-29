import 'package:url_launcher/url_launcher.dart';

import 'session.dart';

class LoyaltyRules {
  final bool enabled;
  final double pointsPerUnit; // points earned per 1.00 spent
  final double pointValue; // money value of 1 point when redeeming
  final double minRedeem; // minimum points per redemption
  const LoyaltyRules(this.enabled, this.pointsPerUnit, this.pointValue, this.minRedeem);

  static LoyaltyRules fromJson(Map<String, dynamic>? j) => LoyaltyRules(
        (j?['enabled'] ?? false) as bool,
        ((j?['points_per_unit'] ?? 0) as num).toDouble(),
        ((j?['point_value'] ?? 0) as num).toDouble(),
        ((j?['min_redeem'] ?? 0) as num).toDouble(),
      );

  /// Largest amount a balance can pay, capped at what's due. Zero if below the minimum.
  double redeemable(double points, double due) {
    if (!enabled || pointValue <= 0 || points < minRedeem) return 0;
    final v = (points * pointValue * 100).floorToDouble() / 100;
    return v < due ? v : due;
  }
}

class Crm {
  Crm._();
  static final Crm instance = Crm._();

  LoyaltyRules loyalty = const LoyaltyRules(false, 0, 0, 0);
  String? leadFormKey;

  Future<void> load() async {
    final s = AppSession.instance;
    try {
      final r = await s.db.rpc('get_crm_settings', params: {'p_tenant': s.tenantId}) as Map<String, dynamic>;
      loyalty = LoyaltyRules.fromJson(r['loyalty'] as Map<String, dynamic>?);
      leadFormKey = r['lead_form_key'] as String?;
    } catch (_) {
      // offline or CRM not set up: keep defaults
    }
  }
}

String digitsOnly(String? p) => (p ?? '').replaceAll(RegExp(r'[^0-9]'), '');

/// Malaysian numbers like 012-3456789 become 60123456789 for WhatsApp links.
String waNumber(String phone, String countryCode) {
  var d = digitsOnly(phone);
  if (d.startsWith('0')) {
    const dial = {'MY': '60', 'SG': '65', 'ID': '62', 'TH': '66', 'PH': '63', 'VN': '84', 'IN': '91', 'AU': '61', 'GB': '44'};
    final cc = dial[countryCode];
    if (cc != null) d = cc + d.substring(1);
  }
  return d;
}

Future<bool> openWhatsApp(String phone, {String text = ''}) => launchUrl(
      Uri.parse('https://wa.me/${waNumber(phone, AppSession.instance.countryCode)}${text.isEmpty ? '' : '?text=${Uri.encodeComponent(text)}'}'),
      mode: LaunchMode.externalApplication,
    );

Future<bool> callPhone(String phone) => launchUrl(Uri(scheme: 'tel', path: phone));

Future<bool> sendEmail(String email) => launchUrl(Uri(scheme: 'mailto', path: email));
