import 'package:flutter_tts/flutter_tts.dart';

class DemoSpeech {
  DemoSpeech._();

  static final DemoSpeech instance = DemoSpeech._();
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;

  Future<void> speak(String text) async {
    try {
      if (!_ready) {
        await _tts.setLanguage('ko-KR');
        await _tts.setSpeechRate(0.45);
        await _tts.setVolume(1.0);
        await _tts.awaitSpeakCompletion(true);
        _ready = true;
      }
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {
      // TTS engines differ by device. The same prompt remains visible on screen.
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
