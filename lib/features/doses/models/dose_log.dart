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

/// One dose taken, skipped or missed on a day.
class DoseLog {
  final String id;
  final String medicationId;

  /// `null` for a dose outside any regimen (as-needed, one-off)
  final String? regimenId;
  final DateTime date;
  final DateTime? takenAt;
  final double? plannedAmount;

  /// 0 for skipped and missed doses
  final double amount;
  final String unit;

  /// `taken`, `partial`, `skipped` or `missed`
  final String status;

  /// `one_tap`, `parsed`, `missed_prompt` or `manual`
  final String source;
  final String? rawEntryId;
  final String note;

  DoseLog.fromDb({
    required this.id,
    required this.medicationId,
    this.regimenId,
    required this.date,
    this.takenAt,
    this.plannedAmount,
    required this.amount,
    required this.unit,
    required this.status,
    required this.source,
    this.rawEntryId,
    required this.note,
  });
}
