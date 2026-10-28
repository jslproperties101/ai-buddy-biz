import 'package:url_launcher/url_launcher.dart';

/// Opens the phone dialler, WhatsApp chat or email app for a contact.
class ContactLinks {
  static Future<bool> call(String phone) => launchUrl(Uri(scheme: 'tel', path: phone));

  /// [phoneNorm] is digits with country code, e.g. 60123456789.
  static Future<bool> whatsapp(String phoneNorm, {String? text}) => launchUrl(
        Uri.https('wa.me', '/$phoneNorm', {if (text != null && text.isNotEmpty) 'text': text}),
        mode: LaunchMode.externalApplication,
      );

  static Future<bool> email(String address, {String? subject, String? body}) => launchUrl(Uri(
        scheme: 'mailto',
        path: address,
        query: _encode({if (subject != null) 'subject': subject, if (body != null) 'body': body}),
      ));

  static String? _encode(Map<String, String> p) => p.isEmpty
      ? null
      : p.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&');

  /// Fills {{name}}, {{first_name}}, {{points}}, {{business}}.
  static String fill(String text, Map<String, String> vars) =>
      text.replaceAllMapped(RegExp(r'\{\{\s*(\w+)\s*\}\}'), (m) => vars[m.group(1)] ?? '');
}
