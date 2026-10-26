import 'package:flutter/foundation.dart';
import 'package:wger/features/doses/widgets/log_box.dart';
import 'package:wger/features/doses/widgets/missed_prompt.dart';

class FakeSpeech implements SpeechInput {
  final bool available;
  final bool plausible;
  int initializeCalls = 0;
  void Function(String words)? onWords;
  VoidCallback? onDone;
  bool listening = false;

  FakeSpeech({this.available = true, this.plausible = true});

  @override
  bool get plausiblySupported => plausible;

  @override
  Future<bool> initialize() async {
    initializeCalls++;
    return available;
  }

  @override
  Future<void> start(void Function(String words) onWords, {required VoidCallback onDone}) async {
    listening = true;
    this.onWords = onWords;
    this.onDone = onDone;
  }

  @override
  Future<void> stop() async => listening = false;
}

class FakeDismissals implements MissedDismissals {
  final keys = <String>{};
  bool throwOnRead = false;

  @override
  Future<bool> isDismissed(String slotId, DateTime date) async {
    if (throwOnRead) {
      throw StateError('storage unreadable');
    }
    return keys.contains(missedDismissKey(slotId, date));
  }

  @override
  Future<void> dismiss(String slotId, DateTime date) async =>
      keys.add(missedDismissKey(slotId, date));
}
