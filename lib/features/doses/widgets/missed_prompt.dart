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
 * The missed-slot prompt: asks once per past slot and day, logs only on yes.
 */

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wger/features/doses/logic/missed.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/l10n/generated/app_localizations.dart';

/// Which prompts the user hid on this device. Behind an interface so tests
/// need no platform channel.
abstract class MissedDismissals {
  Future<bool> isDismissed(String slotId, DateTime date);

  Future<void> dismiss(String slotId, DateTime date);
}

String missedDismissKey(String slotId, DateTime date) =>
    'doses.missed.dismissed.$slotId.${DateFormat('yyyy-MM-dd').format(date)}';

class PrefsMissedDismissals implements MissedDismissals {
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  @override
  Future<bool> isDismissed(String slotId, DateTime date) async =>
      await _prefs.getBool(missedDismissKey(slotId, date)) ?? false;

  @override
  Future<void> dismiss(String slotId, DateTime date) =>
      _prefs.setBool(missedDismissKey(slotId, date), true);
}

final missedDismissalsProvider = Provider<MissedDismissals>((ref) => PrefsMissedDismissals());

/// The prompts for [missed], oldest first, without those hidden on this device.
class MissedPrompt extends ConsumerStatefulWidget {
  final List<MissedSlot> missed;
  final DateTime today;

  const MissedPrompt({super.key, required this.missed, required this.today});

  @override
  ConsumerState<MissedPrompt> createState() => _MissedPromptState();
}

class _MissedPromptState extends ConsumerState<MissedPrompt> {
  /// Keys of the prompts hidden on this device
  final _hidden = <String>{};
  final _checked = <String>{};

  String _key(MissedSlot m) => missedDismissKey(m.slot.id, m.date);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MissedPrompt old) {
    super.didUpdateWidget(old);
    _load();
  }

  Future<void> _load() async {
    final store = ref.read(missedDismissalsProvider);
    for (final m in widget.missed) {
      final key = _key(m);
      if (!_checked.add(key)) {
        continue;
      }
      final hidden = await store.isDismissed(m.slot.id, m.date);
      if (hidden && mounted) {
        setState(() => _hidden.add(key));
      }
    }
  }

  Future<void> _yes(MissedSlot m) async {
    final repo = ref.read(doseRepositoryProvider);
    for (final item in m.items) {
      await repo.logDose(
        medicationId: item.medicationId,
        regimenId: item.id,
        date: m.date,
        plannedAmount: item.amount,
        amount: 0,
        unit: item.unit,
        status: 'missed',
        source: 'missed_prompt',
      );
    }
  }

  Future<void> _notNow(MissedSlot m) async {
    setState(() => _hidden.add(_key(m)));
    await ref.read(missedDismissalsProvider).dismiss(m.slot.id, m.date);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toString();
    final yesterday = DateTime(widget.today.year, widget.today.month, widget.today.day - 1);
    return Column(
      children: [
        for (final m in widget.missed)
          if (!_hidden.contains(_key(m)))
            Card(
              key: Key('missed-${m.slot.name}-${DateFormat('yyyy-MM-dd').format(m.date)}'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      i18n.missedPromptText(
                        m.slot.name,
                        m.date == yesterday
                            ? i18n.missedPromptYesterday
                            : DateFormat.MMMEd(locale).format(m.date),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          key: Key(
                            'missed-not-now-${m.slot.name}-${DateFormat('yyyy-MM-dd').format(m.date)}',
                          ),
                          onPressed: () => _notNow(m),
                          child: Text(i18n.missedPromptNotNow),
                        ),
                        FilledButton(
                          key: Key(
                            'missed-yes-${m.slot.name}-${DateFormat('yyyy-MM-dd').format(m.date)}',
                          ),
                          onPressed: () => _yes(m),
                          child: Text(i18n.missedPromptYes),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}
