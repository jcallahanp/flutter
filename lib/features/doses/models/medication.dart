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

/// A medication the user takes. Never deleted by the app, only deactivated.
class Medication {
  final String id;
  final String name;
  final double? strength;
  final String unit;
  final String form;

  /// `routine`, `as_needed` or `one_off`
  final String kind;
  final bool active;

  Medication.fromDb({
    required this.id,
    required this.name,
    this.strength,
    required this.unit,
    required this.form,
    required this.kind,
    required this.active,
  });
}
