// 음성 질문·답 (B5): 녹음 WAV 머리말, /api/voice 응답 → 답·음성 문장·답 음성, "음성으로 듣기" 버튼(예시 모드)
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/dashboard_parts.dart';
import 'package:guryongpo_safety/repositories/remote_repository.dart';
import 'package:guryongpo_safety/services/voice_service.dart';

void main() {
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
