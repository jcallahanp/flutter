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

/// How much of a medication is planned for a slot, between [startDate] and
/// [endDate] (inclusive, `null` while open-ended).
class Regimen {
  final String id;
  final String medicationId;
  final String slotId;
  final double amount;
  final String unit;
  final String schedule;
  final DateTime startDate;
  final DateTime? endDate;

  Regimen.fromDb({
    required this.id,
    required this.medicationId,
    required this.slotId,
    required this.amount,
    required this.unit,
    required this.schedule,
    required this.startDate,
    this.endDate,
  });
}
