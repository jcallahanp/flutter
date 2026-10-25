/*
 * This file is part of wger Workout Manager <https://github.com/wger-project>.
 * Copyright (c) 2026 wger Team
 *
 * wger Workout Manager is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/*
 * One typed entry: its text, the doses the server made from it, its state,
 * the server's question with a reply box, and Undo.
 */

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wger/core/formatting/formatting.dart';
import 'package:wger/features/doses/models/dose_log.dart';
import 'package:wger/features/doses/models/medication.dart';
import 'package:wger/features/doses/models/parse_result.dart';
import 'package:wger/features/doses/models/raw_entry.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/l10n/generated/app_localizations.dart';

/// The reply that confirms an `add_medication` proposal.
const addMedicationReply = 'yes, add it as an as-needed med';

final _dosesOfEntryProvider = StreamProvider.autoDispose.family<List<DoseLog>, String>(
  (ref, id) => ref.watch(doseRepositoryProvider).watchDosesOfEntry(id),
);
final _parseResultProvider = StreamProvider.autoDispose.family<ParseResult?, String>(
  (ref, id) => ref.watch(doseRepositoryProvider).watchParseResultFor(id),
);

class EntryCard extends ConsumerStatefulWidget {
  final RawEntry entry;

  /// The entries that answer this one
  final List<RawEntry> replies;
  final List<Medication> medications;

  /// The current time, for doses logged by a proposal
  final DateTime now;

  const EntryCard({
    super.key,
    required this.entry,
    this.replies = const [],
    required this.medications,
    required this.now,
  });

  @override
  ConsumerState<EntryCard> createState() => _EntryCardState();
}

class _EntryCardState extends ConsumerState<EntryCard> {
  final _reply = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reply.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _sendReply(String text) async {
    if (text.trim().isEmpty) {
      return;
    }
    await _run(() async {
      await ref.read(doseRepositoryProvider).createRawEntry(text.trim(), parentId: widget.entry.id);
      _reply.clear();
    });
  }

  Future<void> _markRestTaken(Map<String, dynamic> proposal) async {
    final slotId = proposal['slot_id'];
    final dateText = proposal['date'];
    if (slotId is! String || dateText is! String) {
      return;
    }
    final parsed = DateTime.tryParse(dateText);
    if (parsed == null) {
      return;
    }
    final date = DateTime(parsed.year, parsed.month, parsed.day);
    await _run(
      () => ref
          .read(doseRepositoryProvider)
          .logRestTaken(slotId: slotId, date: date, now: widget.now, rawEntryId: widget.entry.id),
    );
  }

  Future<void> _undo() async {
    final i18n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(i18n.entryUndoTitle),
        content: Text(i18n.entryUndoBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(i18n.cancel)),
          FilledButton(
            key: const Key('entry-undo-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(i18n.entryUndo),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(doseRepositoryProvider).deleteDosesOf(widget.entry.id);
    }
  }

  String _stateLine(AppLocalizations i18n) => switch (widget.entry.state) {
    'pending' => i18n.entryWaiting,
    'no_key' => i18n.entryNoKey,
    'over_limit' => i18n.entryOverLimit,
    'failed' => i18n.entryFailed,
    'needs_answer' => i18n.entryNeedsAnswer,
    _ => i18n.entryRead,
  };

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    final entry = widget.entry;
    final doses = ref.watch(_dosesOfEntryProvider(entry.id)).value ?? const <DoseLog>[];
    final result = ref.watch(_parseResultProvider(entry.id)).value;
    final question = entry.state == 'needs_answer' ? result?.question ?? '' : '';
    final answered = widget.replies.isNotEmpty;
    final proposal = answered ? null : result?.proposal;
    final type = proposal?['type'];
    final names = {for (final m in widget.medications) m.id: m.name};

    return Card(
      key: Key('entry-${entry.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.text),
            for (final d in doses)
              ListTile(
                key: Key('entry-dose-${d.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(names[d.medicationId] ?? ''),
                subtitle: d.status == 'skipped' || d.status == 'missed'
                    ? null
                    : Text('${localizedNumberFormat(context).format(d.amount)} ${d.unit}'),
                trailing: Text(_statusText(i18n, d.status)),
              ),
            const SizedBox(height: 4),
            Text(_stateLine(i18n), style: Theme.of(context).textTheme.bodySmall),
            if (question.isNotEmpty && !answered) ...[
              const SizedBox(height: 8),
              Text(question, key: const Key('entry-question')),
              if (type == 'mark_rest_taken')
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    key: const Key('entry-mark-rest-taken'),
                    onPressed: _busy ? null : () => _markRestTaken(proposal!),
                    child: Text(i18n.entryMarkRestTaken),
                  ),
                ),
              if (type == 'add_medication')
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    key: const Key('entry-add-medication'),
                    onPressed: _busy ? null : () => _sendReply(addMedicationReply),
                    child: Text(i18n.entryAddMedication),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('entry-reply-field'),
                      controller: _reply,
                      maxLength: rawEntryMaxLength,
                      decoration: InputDecoration(hintText: i18n.entryReplyHint),
                    ),
                  ),
                  IconButton(
                    key: const Key('entry-reply-send'),
                    icon: const Icon(Icons.send),
                    tooltip: i18n.entryReplySend,
                    onPressed: _busy || _reply.text.trim().isEmpty
                        ? null
                        : () => _sendReply(_reply.text),
                  ),
                ],
              ),
            ],
            if (doses.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('entry-undo'),
                  onPressed: _undo,
                  child: Text(i18n.entryUndo),
                ),
              ),
            for (final reply in widget.replies)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: EntryCard(
                  entry: reply,
                  medications: widget.medications,
                  now: widget.now,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _statusText(AppLocalizations i18n, String status) => switch (status) {
  'taken' => i18n.doseStatusTaken,
  'partial' => i18n.doseStatusPartial,
  'skipped' => i18n.doseStatusSkipped,
  'missed' => i18n.doseStatusMissed,
  _ => status,
};
