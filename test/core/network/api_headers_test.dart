/*
 * This file is part of wger Workout Manager <https://github.com/wger-project>.
 * Copyright (c) 2026 - 2026 wger Team
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

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wger/core/network/api_headers.dart';

void main() {
  group('appPlatformName', () {
    test('is web in the browser, where Platform getters throw', () {
      expect(appPlatformName(isWeb: true), 'web');
    });

    test('is the OS name elsewhere', () {
      expect(appPlatformName(isWeb: false), Platform.operatingSystem);
    });
  });
}
