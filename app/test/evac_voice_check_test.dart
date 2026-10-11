// 시각장애인 대피 음성 확인 (B12): gpt-realtime 이 묻고 → set_evacuation_status → 저장(via=voice) → 결과 문장 읽기,
// 대답이 없으면 한 번 더 묻고 noAnswer, 연결 못 하면 unavailable (Google 음성으로 넘어가지 않음), 배정 안내 읽기
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/services/evac_voice_check.dart';
import 'package:guryongpo_safety/services/realtime_link.dart';

class FakeLink implements RealtimeLink {
  bool failConnect = false, closed = false;
  bool? microphone;
  final sent = <Map<String, dynamic>>[];
  late void Function(Map<String, dynamic>) emit;

  @override
  Future<void> connect(
      {required callsUrl, required clientSecret, required onEvent, required onClosed, bool microphone = true}) async {
    if (failConnect) throw StateError('마이크 권한 없음');
    this.microphone = microphone;
    emit = onEvent;
  }

  @override
  void send(Map<String, dynamic> event) => sent.add(event);

  @override
  Future<void> close() async => closed = true;
}

const session = EvacVoiceSession(
    clientSecret: 'ek_e',
    callsUrl: 'https://x/calls',
    statusTool: 'set_evacuation_status',
    endTool: 'end_conversation',
    readOutPrefix: '그대로 읽어라:');

Map<String, dynamic> call(String name, [Map<String, dynamic> args = const {}]) => {
      'type': 'response.done',
      'response': {
        'output': [
          {'type': 'function_call', 'name': name, 'call_id': 'c1', 'arguments': jsonEncode(args)}
        ]
      }
    };

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeLink link;
  late List<String> modes;
  EvacVoiceCheck make({EvacVoiceSession? s = session, Duration timeout = const Duration(seconds: 45)}) {
    link = FakeLink();
    modes = [];
    return EvacVoiceCheck(
        openSession: (mode, {alertText = '', announceText = ''}) async {
          modes.add('$mode|$alertText$announceText');
          return s;
        },
        link: () => link,
        answerTimeout: timeout);
  }

  test('대답 → 상태 저장(음성) → 결과 문장을 그대로 읽고 닫는다', () async {
    final v = make();
    final saved = <(String, String)>[];
    final result = v.check(alertText: '[대피 확인] 호우 경보', save: (s, t) async {
      saved.add((s, t));
      return evacVoiceSavedText(s);
    });
    await settle();
    await settle();
    expect(modes, ['evac_check|[대피 확인] 호우 경보']);
    expect(link.microphone, isTrue);
    expect(link.sent.first, {'type': 'response.create'}); // 모델이 먼저 묻는다
    expect(v.listening, isTrue);
    link.emit(call('set_evacuation_status', {'status': 'evacuating', 'transcript': '지금 가고 있어요'}));
    expect(await result, EvacVoiceResult.saved);
    expect(saved, [('evacuating', '지금 가고 있어요')]);
    final read = link.sent.last['response'] as Map;
    expect(read['tool_choice'], 'none');
    expect(read['instructions'], '그대로 읽어라:${evacVoiceSavedText('evacuating')}');
    expect(link.closed, isFalse); // 다 읽을 때까지 둔다
    link.emit({'type': 'output_audio_buffer.stopped'});
    await settle();
    expect(link.closed, isTrue);
  });

  test('세 가지가 아닌 값은 저장하지 않는다', () async {
    final v = make();
    var saves = 0;
    final result = v.check(alertText: '', save: (s, t) async {
      saves++;
      return '';
    });
    await settle();
    await settle();
    link.emit(call('set_evacuation_status', {'status': 'safe', 'transcript': '?'}));
    await settle();
    expect(saves, 0);
    await v.stop();
    expect(await result, EvacVoiceResult.stopped);
  });

  test('대답이 없으면 한 번 더 묻고, 그래도 없으면 noAnswer', () async {
    final v = make(timeout: const Duration(milliseconds: 30));
    final result = v.check(alertText: '', save: (s, t) async => '');
    expect(await result, EvacVoiceResult.noAnswer);
    final asks = link.sent.where((e) => e['type'] == 'response.create').toList();
    expect(asks, hasLength(2));
    expect((asks[1]['response'] as Map)['instructions'], contains('대피 완료, 대피 중, 도움 필요'));
    expect(link.closed, isTrue);
  });

  test('서버 세션이 없거나 연결에 실패하면 unavailable', () async {
    expect(await make(s: null).check(alertText: '', save: (s, t) async => ''), EvacVoiceResult.unavailable);
    final v = make();
    link.failConnect = true;
    expect(await v.check(alertText: '', save: (s, t) async => ''), EvacVoiceResult.unavailable);
    expect(link.closed, isTrue);
    expect(await EvacVoiceCheck(openSession: (m, {alertText = '', announceText = ''}) async => session, link: () => null)
        .check(alertText: '', save: (s, t) async => ''), EvacVoiceResult.unavailable);
  });

  test('도착 안내: 마이크 없이 문장을 읽고, 다 읽으면 끝', () async {
    final v = make();
    final done = v.announce('방재단원이 배정되었습니다. 약 7분 후 도착합니다.');
    await settle();
    await settle();
    expect(modes, ['announce|방재단원이 배정되었습니다. 약 7분 후 도착합니다.']);
    expect(link.microphone, isFalse);
    link.emit({'type': 'output_audio_buffer.started'});
    link.emit({'type': 'output_audio_buffer.stopped'});
    expect(await done, isTrue);
    expect(link.closed, isTrue);
    expect(await make(s: null).announce('x'), isFalse);
  });

  test('저장 문장', () {
    expect(evacVoiceSavedText('need_help'), contains('방재단에 바로 알렸어요'));
    expect(evacVoiceSavedText('evacuated', queued: true), contains('연결되면 바로 보낼게요'));
  });
}
