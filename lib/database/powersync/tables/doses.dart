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

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' as ps;
import 'package:wger/database/converters/date_only_text_converter.dart';
import 'package:wger/database/converters/json_map_converter.dart';
import 'package:wger/database/converters/time_of_day_converter.dart';
import 'package:wger/database/converters/utc_datetime_converter.dart';
import 'package:wger/features/doses/models/dose_log.dart';
import 'package:wger/features/doses/models/dose_slot.dart';
import 'package:wger/features/doses/models/medication.dart';
import 'package:wger/features/doses/models/parse_result.dart';
import 'package:wger/features/doses/models/raw_entry.dart';
import 'package:wger/features/doses/models/regimen.dart';

// Mirrors the server's `healthhub_*` tables. `user_id` is not declared: the
// server forces the owner on upload. Decimals are `real` (PowerSync sends
// Postgres numeric as text, the view casts), booleans are integers.

@UseRowClass(Medication, constructor: 'fromDb')
class MedicationTable extends Table {
  @override
  String get tableName => 'healthhub_medication';

  TextColumn get id => text().clientDefault(() => ps.uuid.v7())();

  TextColumn get name => text()();
  RealColumn get strength => real().nullable()();
  TextColumn get unit => text()();
  TextColumn get form => text().withDefault(const Constant(''))();

  /// `routine`, `as_needed` or `one_off`
  TextColumn get kind => text().withDefault(const Constant('routine'))();

  /// Medications are deactivated, never deleted: deleting one on the server
  /// cascades its dose history.
  BoolColumn get active => boolean().withDefault(const Constant(true))();

  DateTimeColumn get created => dateTime().map(const UtcDateTimeConverter()).nullable()();
  DateTimeColumn get updated => dateTime().map(const UtcDateTimeConverter()).nullable()();
}

const PowersyncMedicationTable = ps.Table(
  'healthhub_medication',
  [
    ps.Column.text('name'),
    ps.Column.real('strength'),
    ps.Column.text('unit'),
    ps.Column.text('form'),
    ps.Column.text('kind'),
    // Postgres boolean; integer so the view yields 0/1
    ps.Column.integer('active'),
    ps.Column.text('created'),
    ps.Column.text('updated'),
  ],
);

@UseRowClass(DoseSlot, constructor: 'fromDb')
class DoseSlotTable extends Table {
  @override
  String get tableName => 'healthhub_doseslot';

  TextColumn get id => text().clientDefault(() => ps.uuid.v7())();

  TextColumn get name => text()();

  /// Server `TimeField`, "HH:MM:SS"
  TextColumn get usualTime => text().named('usual_time').map(const TimeOfDayConverter())();
  IntColumn get order => integer().withDefault(const Constant(0))();
}

const PowersyncDoseSlotTable = ps.Table(
  'healthhub_doseslot',
  [
    ps.Column.text('name'),
    ps.Column.text('usual_time'),
    ps.Column.integer('order'),
  ],
);

@UseRowClass(Regimen, constructor: 'fromDb')
class RegimenTable extends Table {
  @override
  String get tableName => 'healthhub_regimen';

  TextColumn get id => text().clientDefault(() => ps.uuid.v7())();

  TextColumn get medicationId => text().named('medication_id').references(MedicationTable, #id)();
  TextColumn get slotId => text().named('slot_id').references(DoseSlotTable, #id)();
  RealColumn get amount => real()();
  TextColumn get unit => text()();
  TextColumn get schedule => text().withDefault(const Constant('daily'))();

  TextColumn get startDate => text().named('start_date').map(const DateOnlyTextConverter())();

  /// `null` while the regimen is open-ended
  TextColumn get endDate =>
      text().named('end_date').nullable().map(const DateOnlyTextConverter())();
}

const PowersyncRegimenTable = ps.Table(
  'healthhub_regimen',
  [
    ps.Column.text('medication_id'),
    ps.Column.text('slot_id'),
    ps.Column.real('amount'),
    ps.Column.text('unit'),
    ps.Column.text('schedule'),
    ps.Column.text('start_date'),
    ps.Column.text('end_date'),
  ],
  indexes: [
    ps.Index('medication_idx', [ps.IndexedColumn('medication_id')]),
    ps.Index('slot_idx', [ps.IndexedColumn('slot_id')]),
  ],
);

@UseRowClass(RawEntry, constructor: 'fromDb')
class RawEntryTable extends Table {
  @override
  String get tableName => 'healthhub_rawentry';

  TextColumn get id => text().clientDefault(() => ps.uuid.v7())();

  /// The free text the user typed, max. 2000 characters
  TextColumn get body => text().named('text')();

  DateTimeColumn get createdOnDevice =>
      dateTime().named('created_on_device').map(const UtcDateTimeConverter())();

  /// IANA name of the device zone when the text was written
  TextColumn get timeZone => text().named('time_zone')();
  TextColumn get parentId => text().named('parent_id').nullable()();

  /// `pending`, `parsed`, `needs_answer`, `failed`, `over_limit` or `no_key`;
  /// the server moves it on from `pending`.
  TextColumn get state => text().withDefault(const Constant('pending'))();
  DateTimeColumn get parsedAt =>
      dateTime().named('parsed_at').map(const UtcDateTimeConverter()).nullable()();
}

const PowersyncRawEntryTable = ps.Table(
  'healthhub_rawentry',
  [
    ps.Column.text('text'),
    ps.Column.text('created_on_device'),
    ps.Column.text('time_zone'),
    ps.Column.text('parent_id'),
    ps.Column.text('state'),
    ps.Column.text('parsed_at'),
  ],
  indexes: [
    ps.Index('created_idx', [ps.IndexedColumn('created_on_device')]),
  ],
);

/// Written by the server only, the app never uploads it.
@UseRowClass(ParseResult, constructor: 'fromDb')
class ParseResultTable extends Table {
  @override
  String get tableName => 'healthhub_parseresult';

  TextColumn get id => text().clientDefault(() => ps.uuid.v7())();

  TextColumn get rawEntryId => text().named('raw_entry_id')();
  TextColumn get model => text()();

  /// JSON list, kept as the raw text
  TextColumn get toolCalls => text().named('tool_calls')();
  TextColumn get question => text()();

  /// JSON object, `null` while the parser still has a question
  TextColumn get proposal => text().map(const JsonMapConverter()).nullable()();
  IntColumn get inputTokens => integer().named('input_tokens')();
  IntColumn get outputTokens => integer().named('output_tokens')();
  TextColumn get error => text()();
  DateTimeColumn get created => dateTime().map(const UtcDateTimeConverter())();
}

const PowersyncParseResultTable = ps.Table(
  'healthhub_parseresult',
  [
    ps.Column.text('raw_entry_id'),
    ps.Column.text('model'),
    ps.Column.text('tool_calls'),
    ps.Column.text('question'),
    ps.Column.text('proposal'),
    ps.Column.integer('input_tokens'),
    ps.Column.integer('output_tokens'),
    ps.Column.text('error'),
    ps.Column.text('created'),
  ],
  indexes: [
    ps.Index('raw_entry_idx', [ps.IndexedColumn('raw_entry_id')]),
  ],
);

@UseRowClass(DoseLog, constructor: 'fromDb')
class DoseLogTable extends Table {
  @override
  String get tableName => 'healthhub_doselog';

  TextColumn get id => text().clientDefault(() => ps.uuid.v7())();

  TextColumn get medicationId => text().named('medication_id').references(MedicationTable, #id)();
  TextColumn get regimenId => text().named('regimen_id').nullable().references(RegimenTable, #id)();

  TextColumn get date => text().map(const DateOnlyTextConverter())();
  DateTimeColumn get takenAt =>
      dateTime().named('taken_at').map(const UtcDateTimeConverter()).nullable()();
  RealColumn get plannedAmount => real().named('planned_amount').nullable()();

  /// 0 for skipped and missed doses
  RealColumn get amount => real()();
  TextColumn get unit => text()();

  /// `taken`, `partial`, `skipped` or `missed`
  TextColumn get status => text()();

  /// `one_tap`, `parsed`, `missed_prompt` or `manual`
  TextColumn get source => text()();
  TextColumn get rawEntryId => text().named('raw_entry_id').nullable()();
  TextColumn get note => text().withDefault(const Constant(''))();
}

const PowersyncDoseLogTable = ps.Table(
  'healthhub_doselog',
  [
    ps.Column.text('medication_id'),
    ps.Column.text('regimen_id'),
    ps.Column.text('date'),
    ps.Column.text('taken_at'),
    ps.Column.real('planned_amount'),
    ps.Column.real('amount'),
    ps.Column.text('unit'),
    ps.Column.text('status'),
    ps.Column.text('source'),
    ps.Column.text('raw_entry_id'),
    ps.Column.text('note'),
  ],
  indexes: [
    ps.Index('date_idx', [ps.IndexedColumn('date')]),
    ps.Index('raw_entry_idx', [ps.IndexedColumn('raw_entry_id')]),
  ],
);
