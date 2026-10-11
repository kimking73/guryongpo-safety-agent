// 음성 질문·답 (B5): 녹음 WAV 머리말, /api/voice 응답 → 답·음성 문장·답 음성, "음성으로 듣기" 버튼(예시 모드)
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/dashboard_parts.dart';
import 'package:guryongpo_safety/repositories/remote_repository.dart';
import 'package:guryongpo_safety/services/voice_conversation.dart';
import 'package:guryongpo_safety/services/voice_service.dart';

/// 크기가 [amp]인 16kHz PCM [ms]밀리초 (부호를 번갈아 RMS = amp)
Uint8List tone(int amp, int ms) {
  final n = voiceSampleRate * ms ~/ 1000;
  final b = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    b.setInt16(i * 2, i.isEven ? amp : -amp, Endian.little);
  }
  return b.buffer.asUint8List();
}

/// 가짜 녹음기: start 때 받은 콜백을 테스트가 직접 부른다
class FakeInput implements VoiceInput {
  bool permission = true;
  int starts = 0, stops = 0;
  Uint8List? wav = Uint8List.fromList([1, 2, 3]);
  void Function()? speechEnd, noSpeech;
  @override
  Future<bool> start({void Function()? onLimit, void Function()? onSpeechEnd, void Function()? onNoSpeech}) async {
    if (!permission) return false;
    starts++;
    speechEnd = onSpeechEnd;
    noSpeech = onNoSpeech;
    return true;
  }

  @override
  Future<Uint8List?> stop() async {
    stops++;
    return wav;
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('말 끝 감지 (SpeechEndDetector)', () {
    test('말한 뒤 1.2초 조용하면 한 번만 알린다', () {
      var end = 0, none = 0;
      final d = SpeechEndDetector(onSpeechEnd: () => end++, onNoSpeech: () => none++);
      d.add(tone(50, 400)); // 조용
      d.add(tone(4000, 1000)); // 말
      expect(d.started, isTrue);
      d.add(tone(50, 1000)); // 아직 1.2초 전
      expect(end, 0);
      d.add(tone(50, 300));
      expect(end, 1);
      d.add(tone(50, 3000));
      expect([end, none], [1, 0]);
    });

    test('말 사이 짧은 쉼(0.8초)은 끝이 아니다', () {
      var end = 0;
      final d = SpeechEndDetector(onSpeechEnd: () => end++);
      d.add(tone(50, 400));
      d.add(tone(4000, 600));
      d.add(tone(50, 800));
      d.add(tone(4000, 600));
      expect(end, 0);
      d.add(tone(50, 1300));
      expect(end, 1);
    });

    test('8초 동안 말이 없으면 onNoSpeech', () {
      var end = 0, none = 0;
      final d = SpeechEndDetector(onSpeechEnd: () => end++, onNoSpeech: () => none++);
      d.add(tone(80, 7900));
      expect(none, 0);
      d.add(tone(80, 200));
      expect([end, none], [0, 1]);
    });

    test('주변이 시끄러우면 기준을 올린다 — 소음은 말이 아니고 더 큰 소리만 말', () {
      var end = 0;
      final d = SpeechEndDetector(onSpeechEnd: () => end++);
      d.add(tone(800, 1000)); // 계속 나는 소음
      expect(d.started, isFalse);
      expect(d.threshold, 2000);
      d.add(tone(6000, 500));
      expect(d.started, isTrue);
      d.add(tone(800, 1300));
      expect(end, 1);
    });

    test('조각이 홀수 바이트로 끊겨 와도 같다', () {
      var end = 0;
      final d = SpeechEndDetector(onSpeechEnd: () => end++);
      final all = (BytesBuilder()
            ..add(tone(50, 400))
            ..add(tone(4000, 600))
            ..add(tone(50, 1300)))
          .takeBytes();
      for (var i = 0; i < all.length; i += 333) {
        d.add(Uint8List.sublistView(all, i, i + 333 > all.length ? all.length : i + 333));
      }
      expect(end, 1);
    });
  });

  group('연속 음성 대화 (VoiceConversation)', () {
    late FakeInput input;
    late List<VoiceTurn> turns;
    late List<String> said;
    late List<VoiceState> states;
    late VoiceConversation voice;
    var asked = 0;
    Completer<void>? hold;

    setUp(() {
      input = FakeInput();
      turns = [];
      said = [];
      states = [];
      asked = 0;
      hold = null;
      voice = VoiceConversation(
          input: () => input,
          say: said.add,
          ask: (wav, {onSpeaking, shouldPlay}) async {
            asked++;
            await hold?.future;
            if (shouldPlay?.call() ?? true) onSpeaking?.call();
            return turns.removeAt(0);
          });
      voice.addListener(states.add, fireImmediately: false);
    });

    test('듣기 → 말 끝 → 답 → 다시 듣기, "그만"이면 끝', () async {
      turns = [VoiceTurn.answered, VoiceTurn.ended];
      expect(await voice.start(), isTrue);
      expect(voice.state, VoiceState.listening);
      input.speechEnd!();
      await settle();
      expect([asked, input.starts, voice.state], [1, 2, VoiceState.listening]); // 답한 뒤 다시 듣는 중
      input.speechEnd!();
      await settle();
      expect([asked, input.starts, voice.state, voice.active], [2, 2, VoiceState.off, false]);
      expect(states, [
        VoiceState.listening, VoiceState.thinking, VoiceState.speaking,
        VoiceState.listening, VoiceState.thinking, VoiceState.speaking, VoiceState.off,
      ]);
      expect(said, isEmpty);
    });

    test('말이 없는 것이 두 번 이어지면 안내하고 끝 — 중간에 답하면 다시 센다', () async {
      turns = [VoiceTurn.answered];
      await voice.start();
      input.noSpeech!();
      await settle();
      expect(voice.state, VoiceState.listening);
      input.speechEnd!();
      await settle();
      input.noSpeech!();
      await settle();
      expect(voice.state, VoiceState.listening);
      input.noSpeech!();
      await settle();
      expect([voice.state, asked, said.length], [VoiceState.off, 1, 1]);
    });

    test('못 알아들음(422) 두 번이면 끝, 오류는 바로 끝', () async {
      turns = [VoiceTurn.notHeard, VoiceTurn.notHeard];
      await voice.start();
      input.speechEnd!();
      await settle();
      expect(voice.state, VoiceState.listening);
      input.speechEnd!();
      await settle();
      expect(voice.state, VoiceState.off);

      turns = [VoiceTurn.failed];
      await voice.start();
      input.speechEnd!();
      await settle();
      expect([voice.state, input.starts], [VoiceState.off, 3]);
    });

    test('중지: 듣던 것은 보내지 않고, 답을 기다리던 중이면 답 음성을 틀지 않는다', () async {
      await voice.start();
      await voice.stop();
      await settle();
      expect([voice.state, asked, input.stops], [VoiceState.off, 0, 1]);

      turns = [VoiceTurn.answered];
      hold = Completer<void>();
      await voice.start();
      input.speechEnd!();
      await settle();
      expect(voice.state, VoiceState.thinking);
      await voice.stop();
      expect(voice.state, VoiceState.off);
      hold!.complete();
      await settle();
      expect([voice.state, input.starts], [VoiceState.off, 2]); // 다시 듣지 않는다
      expect(states.contains(VoiceState.speaking), isFalse);
    });

    test('마이크 권한이 없으면 시작하지 않는다', () async {
      input.permission = false;
      expect(await voice.start(), isFalse);
      expect([voice.state, voice.active], [VoiceState.off, false]);
    });
  });

  test('PCM → WAV: 16kHz mono 16bit 머리말 + 원본', () {
    final pcm = Uint8List.fromList(List.filled(32000, 1)); // 1초
    final wav = pcmToWav(pcm);
    final h = ByteData.sublistView(wav);
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
    expect(h.getUint16(22, Endian.little), 1); // mono
    expect(h.getUint32(24, Endian.little), 16000);
    expect(h.getUint16(34, Endian.little), 16);
    expect(h.getUint32(40, Endian.little), 32000);
    expect(wav.length, 44 + 32000);
  });

  test('/api/voice 응답 → 답 + 음성 문장 + 답 음성(mp3)', () {
    final a = chatAnswerFromJson({
      'conversation_id': 'c1',
      'answer': '현재 위치의 침수 위험 단계는 정상입니다.\n\n지금 할 일:\n1. 물에 잠긴 도로는 피하세요.',
      'voice_text': '침수 위험은 정상입니다. 물에 잠긴 도로는 피하세요.',
      'transcript': '비 많이 와?',
      'audio_b64': base64Encode(utf8.encode('MP3')),
    });
    expect(a.voiceText, '침수 위험은 정상입니다. 물에 잠긴 도로는 피하세요.');
    expect(utf8.decode(a.audio!), 'MP3');
    final textOnly = chatAnswerFromJson({'answer': '안녕하세요'});
    expect(textOnly.voiceText, isNull);
    expect(textOnly.audio, isNull);
  });

  testWidgets('예시 모드: 음성으로 듣기 → 재생 안 함 안내', (tester) async {
    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: Center(child: VoiceButton(text: '대피하세요.'))))));
    await tester.tap(find.text('음성으로 듣기'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('예시 모드에서는 음성을 재생하지 않습니다.'), findsOneWidget);
    expect(find.text('음성으로 듣기'), findsOneWidget);
  });
}
