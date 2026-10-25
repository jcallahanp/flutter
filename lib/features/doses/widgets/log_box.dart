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
 * Free-text log box on the Today screen, with an optional microphone.
 */

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/l10n/generated/app_localizations.dart';

/// Speech recognition behind a seam, so widget tests need no platform channel.
abstract class SpeechInput {
  /// `false` when speech recognition is not available or not allowed.
  Future<bool> initialize();

  /// Starts listening; [onWords] gets the recognized words so far.
  Future<void> start(void Function(String words) onWords, {required VoidCallback onDone});

  Future<void> stop();
}

/// [SpeechInput] on the `speech_to_text` plugin.
class PluginSpeechInput implements SpeechInput {
  final SpeechToText _speech = SpeechToText();

  @override
  Future<bool> initialize() async {
    try {
      return await _speech.initialize();
    } catch (_) {
      // Web without support, a missing engine or a denied permission
      return false;
    }
  }

  @override
  Future<void> start(void Function(String words) onWords, {required VoidCallback onDone}) async {
    _speech.statusListener = (status) {
      if (status == SpeechToText.doneStatus || status == SpeechToText.notListeningStatus) {
        onDone();
      }
    };
    await _speech.listen(onResult: (r) => onWords(r.recognizedWords));
  }

  @override
  Future<void> stop() => _speech.stop();
}

final speechInputProvider = Provider<SpeechInput>((ref) => PluginSpeechInput());

class LogBox extends ConsumerStatefulWidget {
  const LogBox({super.key});

  @override
  ConsumerState<LogBox> createState() => _LogBoxState();
}

class _LogBoxState extends ConsumerState<LogBox> {
  final _controller = TextEditingController();
  late final SpeechInput _speech;
  bool _micAvailable = false;
  bool _listening = false;
  bool _sending = false;
  String _dictationBase = '';

  @override
  void initState() {
    super.initState();
    _speech = ref.read(speechInputProvider);
    _controller.addListener(() => setState(() {}));
    _speech.initialize().then((ok) {
      if (mounted) {
        setState(() => _micAvailable = ok);
      }
    });
  }

  @override
  void dispose() {
    if (_listening) {
      _speech.stop();
    }
    _controller.dispose();
    super.dispose();
  }

  bool get _canSend => !_sending && _controller.text.trim().isNotEmpty;

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) {
      return;
    }
    setState(() => _sending = true);
    try {
      await ref.read(doseRepositoryProvider).createRawEntry(text);
      _controller.clear();
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _toggleMic() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) {
        setState(() => _listening = false);
      }
      return;
    }
    _dictationBase = _controller.text.trim();
    setState(() => _listening = true);
    await _speech.start(
      (words) {
        if (!mounted) {
          return;
        }
        final text = [_dictationBase, words].where((s) => s.isNotEmpty).join(' ');
        _controller.value = TextEditingValue(
          text: text.length > rawEntryMaxLength ? text.substring(0, rawEntryMaxLength) : text,
          selection: TextSelection.collapsed(offset: text.length.clamp(0, rawEntryMaxLength)),
        );
      },
      onDone: () {
        if (mounted) {
          setState(() => _listening = false);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: const Key('log-box-field'),
              controller: _controller,
              maxLength: rawEntryMaxLength,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: i18n.logBoxHint,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (_micAvailable)
            IconButton(
              key: const Key('log-box-mic'),
              icon: Icon(_listening ? Icons.mic : Icons.mic_none),
              tooltip: _listening ? i18n.logBoxListening : i18n.logBoxMic,
              onPressed: _toggleMic,
            ),
          IconButton(
            key: const Key('log-box-send'),
            icon: const Icon(Icons.send),
            tooltip: i18n.logBoxSend,
            onPressed: _canSend ? _send : null,
          ),
        ],
      ),
    );
  }
}
