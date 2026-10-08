// AI 답을 기다리는 중에 다른 메뉴로 가도 답이 대화 기록에 남는지 (2026-10-08 사용자 요청)
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/repositories/mock_repository.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 답을 테스트가 정할 때 돌려주는 가짜 (그 전까지는 '생성 중')
class SlowRepo extends MockSafetyRepository {
  final pending = Completer<ChatAnswer>();
  @override
  Future<ChatAnswer> ask(String question, UserMode userMode, LatLng origin) => pending.future;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('답 생성 중 상태와 답은 화면 밖(chatController)에 남는다', () async {
    final slow = SlowRepo();
    final c = ProviderContainer(overrides: [repo.overrideWithValue(slow)]);
    addTearDown(c.dispose);

    final sent = c.read(chatController).ask('지금 침수 위험이 있어?');
    expect(c.read(chatLoading), isTrue);
    expect(c.read(chatMessages).single.text, '지금 침수 위험이 있어?');

    slow.pending.complete(const ChatAnswer('지금은 침수 위험이 낮습니다.'));
    await sent;
    expect(c.read(chatLoading), isFalse);
    expect(c.read(chatMessages).map((m) => m.text), ['지금 침수 위험이 있어?', '지금은 침수 위험이 낮습니다.']);
  });

  test('생성 중에는 같은 질문을 두 번 보내지 않는다', () async {
    final slow = SlowRepo();
    final c = ProviderContainer(overrides: [repo.overrideWithValue(slow)]);
    addTearDown(c.dispose);

    final first = c.read(chatController).ask('대피소 어디야?');
    await c.read(chatController).ask('대피소 어디야?');
    slow.pending.complete(const ChatAnswer('구룡포초등학교입니다.'));
    await first;
    expect(c.read(chatMessages).where((m) => m.mine).length, 1);
  });

  testWidgets('AI 대화창을 떠났다 돌아와도 답이 보인다', (tester) async {
    final slow = SlowRepo();
    final c = ProviderContainer(overrides: [repo.overrideWithValue(slow)]);
    addTearDown(c.dispose);
    final page = ValueNotifier<bool>(true); // true = AI 대화창, false = 다른 메뉴
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: page,
            builder: (_, onChat, __) => onChat ? const AiScreen() : const Text('프로필'),
          ),
        ),
      ),
    ));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '지금 침수 위험이 있어?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(c.read(chatLoading), isTrue);

    page.value = false; // 답 생성 중에 다른 메뉴로
    await tester.pump();
    expect(find.byType(AiScreen), findsNothing);

    slow.pending.complete(const ChatAnswer('지금은 침수 위험이 낮습니다.'));
    await tester.pump();
    expect(c.read(chatLoading), isFalse);

    page.value = true; // 돌아오면 답이 있다
    await tester.pump();
    expect(find.text('지금은 침수 위험이 낮습니다.'), findsOneWidget);
  });
}
