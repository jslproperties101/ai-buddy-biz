import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'session.dart';

/// Shared helpers for the kids care module (staff and parent screens).
class Kids {
  Kids._();

  static final time = DateFormat('HH:mm');
  static final day = DateFormat('EEE d MMM');

  static const logKinds = <String, (String, IconData)>{
    'meal': ('Meal', Icons.restaurant),
    'drink': ('Drink', Icons.local_drink_outlined),
    'nap': ('Nap', Icons.bedtime_outlined),
    'nappy': ('Nappy', Icons.baby_changing_station),
    'toilet': ('Toilet', Icons.wc),
    'mood': ('Mood', Icons.mood),
    'activity': ('Activity', Icons.palette_outlined),
    'milestone': ('Milestone', Icons.emoji_events_outlined),
    'health': ('Health', Icons.thermostat),
    'medication': ('Medicine', Icons.medication_outlined),
    'note': ('Note', Icons.sticky_note_2_outlined),
    'photo': ('Photo', Icons.photo_camera_outlined),
  };

  static const incidentKinds = {
    'injury': 'Injury',
    'illness': 'Illness',
    'allergic_reaction': 'Allergic reaction',
    'behaviour': 'Behaviour',
    'near_miss': 'Near miss',
    'safeguarding': 'Safeguarding concern (private)',
    'other': 'Other',
  };

  static String errorText(Object e) {
    if (e is PostgrestException) return e.message;
    if (e is StorageException) return e.message;
    final t = e.toString();
    return t.startsWith('Exception: ') ? t.substring(11) : t;
  }

  static String fmtTime(dynamic v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '' : time.format(d.toLocal());
  }

  static String isoDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  /// "2 yrs 5 mths" / "7 mths"
  static String age(dynamic dob) {
    final b = DateTime.tryParse('${dob ?? ''}');
    if (b == null) return '';
    final now = DateTime.now();
    var months = (now.year - b.year) * 12 + now.month - b.month;
    if (now.day < b.day) months--;
    if (months < 0) return '';
    if (months < 24) return '$months mth${months == 1 ? '' : 's'}';
    final y = months ~/ 12, m = months % 12;
    return '$y yrs${m > 0 ? ' $m mths' : ''}';
  }

  /// One line describing a log entry.
  static String describe(Map<String, dynamic> l) {
    final d = Map<String, dynamic>.from((l['detail'] ?? {}) as Map);
    final note = (l['note'] ?? '') as String;
    String part;
    switch (l['kind']) {
      case 'meal':
        part = [d['item'], if (d['amount'] != null) 'ate ${d['amount']}'].whereType<String>().join(' — ');
      case 'drink':
        part = [d['item'] ?? 'Drink', if (d['ml'] != null) '${d['ml']} ml'].join(' ');
      case 'nap':
        part = d['start'] != null ? 'Slept ${d['start']}${d['end'] != null ? '–${d['end']}' : ''}' : 'Nap';
      case 'nappy':
        part = 'Nappy: ${d['type'] ?? ''}';
      case 'toilet':
        part = 'Toilet${d['type'] != null ? ': ${d['type']}' : ''}';
      case 'mood':
        part = 'Mood: ${d['mood'] ?? ''}';
      case 'health':
        part = d['temperature'] != null ? 'Temperature ${d['temperature']}°C' : 'Health check';
      case 'medication':
        part = 'Given ${d['medicine'] ?? 'medicine'}${d['dose'] != null ? ' (${d['dose']})' : ''}';
      default:
        part = '';
    }
    return [part, note].where((x) => x.trim().isNotEmpty).join(' · ');
  }

  // ───── Photos (private Supabase Storage bucket "kids") ─────

  static final _urls = <String, (String, DateTime)>{};

  static Future<String?> photoUrl(String? path) async {
    if (path == null || path.isEmpty) return null;
    final hit = _urls[path];
    if (hit != null && hit.$2.isAfter(DateTime.now())) return hit.$1;
    try {
      final u = await AppSession.instance.db.storage.from('kids').createSignedUrl(path, 3600);
      _urls[path] = (u, DateTime.now().add(const Duration(minutes: 50)));
      return u;
    } catch (_) {
      return null;
    }
  }

  /// Takes or picks a photo and uploads it under <tenant>/<child>/. Returns the storage path.
  static Future<String?> pickAndUpload(BuildContext context, {required String tenantId, required String childId}) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_camera), title: const Text('Take a photo'), onTap: () => Navigator.pop(context, ImageSource.camera)),
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose from gallery'), onTap: () => Navigator.pop(context, ImageSource.gallery)),
        ]),
      ),
    );
    if (source == null) return null;
    final x = await ImagePicker().pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 75);
    if (x == null) return null;
    final Uint8List bytes = await x.readAsBytes();
    final path = '$tenantId/$childId/${const Uuid().v4()}.jpg';
    await AppSession.instance.db.storage.from('kids').uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'image/jpeg'));
    return path;
  }
}

/// Shows a private photo (signed URL), or an icon while loading / when missing.
class KidsPhoto extends StatelessWidget {
  final String? path;
  final double size;
  final bool circle;
  final IconData fallback;
  const KidsPhoto({super.key, required this.path, this.size = 48, this.circle = true, this.fallback = Icons.child_care});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget box(Widget child) => circle
        ? ClipOval(child: SizedBox(width: size, height: size, child: child))
        : ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(width: size, height: size, child: child));
    final empty = box(Container(color: cs.secondaryContainer, child: Icon(fallback, color: cs.onSecondaryContainer, size: size * 0.55)));
    if (path == null || path!.isEmpty) return empty;
    return FutureBuilder<String?>(
      future: Kids.photoUrl(path),
      builder: (_, snap) => snap.data == null
          ? empty
          : box(Image.network(snap.data!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => empty)),
    );
  }
}

/// Full-width private photo for log timelines.
class KidsPhotoLarge extends StatelessWidget {
  final String path;
  const KidsPhotoLarge({super.key, required this.path});

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
        future: Kids.photoUrl(path),
        builder: (_, snap) => snap.data == null
            ? const SizedBox(height: 160, child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
            : GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => Scaffold(
                    backgroundColor: Colors.black,
                    appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
                    body: Center(child: InteractiveViewer(child: Image.network(snap.data!))),
                  ),
                )),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(snap.data!, height: 220, width: double.infinity, fit: BoxFit.cover),
                ),
              ),
      );
}

/// Day timeline of logs, used by staff and parents.
class KidsTimeline extends StatelessWidget {
  final List<Map<String, dynamic>> logs;
  final bool showStaffOnly;
  final void Function(Map<String, dynamic>)? onLongPress;
  const KidsTimeline({super.key, required this.logs, this.showStaffOnly = false, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    if (logs.isEmpty) {
      return const Padding(padding: EdgeInsets.all(24), child: Text('Nothing logged yet.', textAlign: TextAlign.center));
    }
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      for (final l in logs)
        InkWell(
          onLongPress: onLongPress == null ? null : () => onLongPress!(l),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 44, child: Text(Kids.fmtTime(l['at']), style: TextStyle(color: cs.outline, fontSize: 12))),
              Icon(Kids.logKinds[l['kind']]?.$2 ?? Icons.circle, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(Kids.logKinds[l['kind']]?.$1 ?? '${l['kind']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (Kids.describe(l).isNotEmpty) Text(Kids.describe(l)),
                  if (l['photo_path'] != null) Padding(padding: const EdgeInsets.only(top: 6), child: KidsPhotoLarge(path: l['photo_path'] as String)),
                  Text([
                    if (l['by_name'] != null) 'by ${l['by_name']}',
                    if (showStaffOnly && l['visible_to_parents'] == false) 'staff only',
                  ].join(' · '), style: TextStyle(fontSize: 11, color: cs.outline)),
                ]),
              ),
            ]),
          ),
        ),
    ]);
  }
}

/// Simple chat about one child, shared by staff and parents.
class KidsChat extends StatefulWidget {
  final String childId;
  final bool asParent;
  const KidsChat({super.key, required this.childId, required this.asParent});
  @override
  State<KidsChat> createState() => _KidsChatState();
}

class _KidsChatState extends State<KidsChat> {
  final _t = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  bool _sending = false;
  SupabaseClient get _db => AppSession.instance.db;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _db.from('kids_messages').select().eq('child_id', widget.childId).order('at', ascending: false).limit(100);
      _rows = List<Map<String, dynamic>>.from(rows);
      await _db.rpc('mark_kids_messages_read', params: {'p_child': widget.childId});
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    final b = _t.text.trim();
    if (b.isEmpty) return;
    setState(() => _sending = true);
    try {
      await _db.rpc('send_kids_message', params: {'p_child': widget.childId, 'p_body': b});
      _t.clear();
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Kids.errorText(e))));
    }
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      Expanded(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.all(12),
            itemCount: _rows.length,
            itemBuilder: (_, i) {
              final m = _rows[i];
              final mine = (m['from_parent'] == true) == widget.asParent;
              return Align(
                alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: mine ? cs.primaryContainer : cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${m['from_name'] ?? ''} · ${Kids.day.format(DateTime.parse(m['at'] as String).toLocal())} ${Kids.fmtTime(m['at'])}',
                        style: TextStyle(fontSize: 11, color: cs.outline)),
                    Text(m['body'] as String),
                  ]),
                ),
              );
            },
          ),
        ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _t,
                minLines: 1,
                maxLines: 4,
                maxLength: 2000,
                decoration: const InputDecoration(hintText: 'Write a message', counterText: '', isDense: true),
              ),
            ),
            IconButton(onPressed: _sending ? null : _send, icon: const Icon(Icons.send)),
          ]),
        ),
      ),
    ]);
  }
}
