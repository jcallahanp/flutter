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

/// What the server's parser made of a `RawEntry`. Read-only on the app.
class ParseResult {
  final String id;
  final String rawEntryId;
  final String model;

  /// JSON list, raw text
  final String toolCalls;
  final String question;

  /// `null` while the parser still has a question
  final Map<String, dynamic>? proposal;
  final int inputTokens;
  final int outputTokens;
  final String error;
  final DateTime created;

  ParseResult.fromDb({
    required this.id,
    required this.rawEntryId,
    required this.model,
    required this.toolCalls,
    required this.question,
    this.proposal,
    required this.inputTokens,
    required this.outputTokens,
    required this.error,
    required this.created,
  });
}
