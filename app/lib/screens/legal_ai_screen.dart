import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/legal.dart';
import '../services/session.dart';
import 'legal_screen.dart' show newContract;

const _disclaimer = 'General information, not legal advice. For high-value, unusual or disputed matters, ask a lawyer.';

Widget _banner(BuildContext context, String text, {bool warn = false}) {
  final cs = Theme.of(context).colorScheme;
  return Card(
    color: warn ? cs.errorContainer : cs.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Icon(warn ? Icons.gavel : Icons.info_outline, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      ]),
    ),
  );
}

List<Map<String, dynamic>> _list(dynamic v) =>
    v is List ? [for (final x in v) if (x is Map) Map<String, dynamic>.from(x)] : const [];
List<String> _strings(dynamic v) => v is List ? [for (final x in v) if (x != null) x.toString()] : const [];

/// Ask the AI a legal question, or have it draft a document.
class LegalAiScreen extends StatefulWidget {
  final bool startOnDraft;
  const LegalAiScreen({super.key, this.startOnDraft = false});
  @override
  State<LegalAiScreen> createState() => _LegalAiScreenState();
}

class _LegalAiScreenState extends State<LegalAiScreen> {
  final _question = TextEditingController();
  final _instructions = TextEditingController();
  Map<String, dynamic>? _answer;
  Map<String, dynamic>? _draft;
  Map<String, dynamic>? _quota;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadQuota();
  }

  Future<void> _loadQuota() async {
    _quota = await Legal.quota();
    if (mounted) setState(() {});
  }

  Future<void> _go(String kind) async {
    final text = kind == 'ask' ? _question.text.trim() : _instructions.text.trim();
    if (text.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please give a little more detail')));
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final r = kind == 'ask' ? await Legal.ai('ask', question: text) : await Legal.ai('draft', instructions: text);
      setState(() {
        if (kind == 'ask') {
          _answer = r;
        } else {
          _draft = r;
        }
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Legal.errorText(e))));
    }
    if (mounted) setState(() => _busy = false);
    _loadQuota();
  }

  @override
  Widget build(BuildContext context) {
    final q = _quota;
    return DefaultTabController(
      length: 2,
      initialIndex: widget.startOnDraft ? 1 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AI legal assistant'),
          bottom: PreferredSize(
            preferredSize: Size.fromHeight(_busy ? 51 : 48),
            child: Column(children: [
              const TabBar(tabs: [Tab(text: 'Ask'), Tab(text: 'Draft')]),
              if (_busy) const LinearProgressIndicator(),
            ]),
          ),
        ),
        body: TabBarView(children: [
          // Ask
          ListView(padding: const EdgeInsets.all(16), children: [
            _banner(context, _disclaimer),
            TextField(
              controller: _question,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'e.g. A staff member hasn\'t come to work for 3 days and isn\'t answering. What can I do?',
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              if (q != null) Expanded(child: Text('${q['used']} of ${q['limit']} AI requests used this month', style: const TextStyle(fontSize: 12))),
              if (q == null) const Spacer(),
              FilledButton.icon(onPressed: _busy ? null : () => _go('ask'), icon: const Icon(Icons.send), label: const Text('Ask')),
            ]),
            if (_answer != null) ..._answerView(context, _answer!),
          ]),
          // Draft
          ListView(padding: const EdgeInsets.all(16), children: [
            _banner(context, _disclaimer),
            TextField(
              controller: _instructions,
              minLines: 4,
              maxLines: 10,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'e.g. A 12-month agreement to supply 500 kg of coffee beans a month to a café in Penang, '
                    'paid 30 days after invoice, with a 3-month notice to end.',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                  onPressed: _busy ? null : () => _go('draft'), icon: const Icon(Icons.auto_awesome), label: const Text('Draft it')),
            ),
            if (_draft != null) ..._draftView(context, _draft!),
          ]),
        ]),
      ),
    );
  }

  List<Widget> _answerView(BuildContext context, Map<String, dynamic> a) {
    final laws = _list(a['laws_referenced']);
    return [
      const SizedBox(height: 16),
      if (a['see_lawyer'] == true) _banner(context, 'Talk to a lawyer about this one before acting.', warn: true),
      SelectableText((a['answer'] ?? '').toString()),
      if (_strings(a['key_points']).isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('Key points', style: Theme.of(context).textTheme.titleSmall),
        for (final p in _strings(a['key_points'])) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $p')),
      ],
      if (laws.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('Laws mentioned', style: Theme.of(context).textTheme.titleSmall),
        for (final l in laws) Text('• ${l['name']}${l['section'] != null ? ', ${l['section']}' : ''}'),
      ],
      if (_strings(a['follow_up_questions']).isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('You could also ask', style: Theme.of(context).textTheme.titleSmall),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final f in _strings(a['follow_up_questions']))
            ActionChip(label: Text(f, maxLines: 2), onPressed: () => setState(() => _question.text = f)),
        ]),
      ],
      const SizedBox(height: 8),
      Text('Confidence: ${a['confidence'] ?? '—'}', style: const TextStyle(fontSize: 12)),
    ];
  }

  List<Widget> _draftView(BuildContext context, Map<String, dynamic> d) {
    final s = Session.instance;
    return [
      const SizedBox(height: 16),
      if (d['see_lawyer'] == true) _banner(context, 'Have a lawyer check this draft before you use it.', warn: true),
      Text((d['title'] ?? 'Draft').toString(), style: Theme.of(context).textTheme.titleMedium),
      if (_strings(d['notes']).isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('Check before using', style: Theme.of(context).textTheme.titleSmall),
        for (final n in _strings(d['notes'])) Text('• $n'),
      ],
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SelectableText((d['body'] ?? '').toString(), style: const TextStyle(fontFamily: 'serif')),
        ),
      ),
      Row(children: [
        TextButton.icon(
          icon: const Icon(Icons.copy),
          label: const Text('Copy'),
          onPressed: () => Clipboard.setData(ClipboardData(text: (d['body'] ?? '').toString())),
        ),
        const Spacer(),
        if (s.can('law.manage'))
          FilledButton(
            onPressed: () => newContract(context, title: (d['title'] ?? 'AI draft').toString(), body: (d['body'] ?? '').toString()),
            child: const Text('Make it a contract'),
          ),
      ]),
    ];
  }
}

/// Shows an AI review (or extracted dates) for a contract and lets you add dates to the calendar.
class AiReviewScreen extends StatefulWidget {
  final Map<String, dynamic> result;
  final String contractId;
  final bool canEdit;
  final bool datesOnly;
  const AiReviewScreen({super.key, required this.result, required this.contractId, required this.canEdit, this.datesOnly = false});
  @override
  State<AiReviewScreen> createState() => _AiReviewScreenState();
}

class _AiReviewScreenState extends State<AiReviewScreen> {
  late final List<Map<String, dynamic>> _dates = _list(widget.result['key_dates']);
  late final Set<int> _picked = {for (var i = 0; i < _dates.length; i++) if (_dates[i]['date'] != null) i};
  bool _saving = false;

  Future<void> _accept() async {
    setState(() => _saving = true);
    try {
      final n = await Session.instance.db.rpc('accept_ai_dates', params: {
        'p_contract': widget.contractId,
        'p_items': [for (final i in _picked) _dates[i]],
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n date(s) added to the calendar')));
        setState(() => _picked.clear());
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Legal.errorText(e))));
    }
    if (mounted) setState(() => _saving = false);
  }

  Color _sev(String? s) => s == 'high' ? Colors.red.shade700 : s == 'medium' ? Colors.orange.shade800 : Colors.green.shade700;

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final issues = _list(r['issues']);
    final missing = _list(r['missing_clauses']);
    final tips = _strings(r['negotiation_tips']);
    return Scaffold(
      appBar: AppBar(title: Text(widget.datesOnly ? 'Key dates found' : 'AI review')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 100), children: [
        _banner(context, _disclaimer),
        if (r['see_lawyer'] == true)
          _banner(context, 'Have a lawyer look at this. ${r['see_lawyer_reason'] ?? ''}', warn: true),
        if (!widget.datesOnly) ...[
          Row(children: [
            Text('Overall risk: ', style: Theme.of(context).textTheme.titleMedium),
            Text('${r['risk_level'] ?? '—'}'.toUpperCase(),
                style: TextStyle(color: _sev(r['risk_level'] as String?), fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 4),
          SelectableText((r['summary'] ?? '').toString()),
          if (issues.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Issues (${issues.length})', style: Theme.of(context).textTheme.titleMedium),
            for (final i in issues)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.circle, size: 10, color: _sev(i['severity'] as String?)),
                      const SizedBox(width: 6),
                      Expanded(child: Text((i['clause'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.bold))),
                    ]),
                    const SizedBox(height: 4),
                    Text((i['problem'] ?? '').toString()),
                    if (i['suggestion'] != null) ...[
                      const SizedBox(height: 4),
                      Text('Suggestion: ${i['suggestion']}'),
                    ],
                    if (i['suggested_wording'] != null) ...[
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: SelectableText(i['suggested_wording'].toString(), style: const TextStyle(fontFamily: 'serif')),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy wording'),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: i['suggested_wording'].toString()));
                            ScaffoldMessenger.of(context)
                                .showSnackBar(const SnackBar(content: Text('Copied — paste it in Edit on the contract')));
                          },
                        ),
                      ),
                    ],
                  ]),
                ),
              ),
          ],
          if (missing.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Missing clauses', style: Theme.of(context).textTheme.titleMedium),
            for (final m in missing) ListTile(contentPadding: EdgeInsets.zero, title: Text('${m['clause']}'), subtitle: Text('${m['why'] ?? ''}')),
          ],
          if (tips.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Negotiation tips', style: Theme.of(context).textTheme.titleMedium),
            for (final t in tips) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $t')),
          ],
        ],
        const SizedBox(height: 16),
        Text('Key dates (${_dates.length})', style: Theme.of(context).textTheme.titleMedium),
        if (_dates.isEmpty) const Text('No dates found.'),
        for (var i = 0; i < _dates.length; i++)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _picked.contains(i),
            onChanged: _dates[i]['date'] == null || !widget.canEdit
                ? null
                : (v) => setState(() => v == true ? _picked.add(i) : _picked.remove(i)),
            title: Text('${_dates[i]['title']}'),
            subtitle: Text('${_dates[i]['date'] != null ? Legal.fmtDate(_dates[i]['date']) : 'No exact date'}'
                '${_dates[i]['note'] != null ? ' — ${_dates[i]['note']}' : ''}'),
          ),
        if (_dates.isNotEmpty) const Text('Check each date against the contract before adding it.', style: TextStyle(fontSize: 12)),
      ]),
      bottomNavigationBar: widget.canEdit && _picked.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: _saving ? null : _accept,
                  child: Text('Add ${_picked.length} date(s) to the calendar'),
                ),
              ),
            )
          : null,
    );
  }
}
