import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:guryongpo_safety/services/prototype_safety_store.dart';
import 'package:guryongpo_safety/prototype_safety_screens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('evacuation responses and accessibility preferences persist locally',
      () async {
    final controller = PrototypeSafetyController();
    await controller.load();
    await controller.respond('alert-1', EvacuationResponseStatus.needHelp);
    await controller.updateAccessibility(
        controller.accessibility.copyWith(visionSupport: true));

    final restored = PrototypeSafetyController();
    await restored.load();

    expect(restored.responseFor('alert-1'), EvacuationResponseStatus.needHelp);
    expect(restored.accessibility.visionSupport, isTrue);
  });

  test('screen flashing is disabled for new profiles', () {
    expect(const AccessibilitySettings().screenFlash, isFalse);
  });

  test('explicit saved screen-flash choices survive loading', () async {
    SharedPreferences.setMockInitialValues({
      'prototype_accessibility_v1':
          '{"hearingSupport":true,"visionSupport":false,"strongVibration":true,"screenFlash":true,"largeText":true,"voicePrompts":true}',
    });
    final controller = PrototypeSafetyController();
    await controller.load();

    expect(controller.accessibility.hearingSupport, isTrue);
    expect(controller.accessibility.screenFlash, isTrue);
  });

  test('missing legacy screen-flash value defaults safely to disabled', () {
    final settings = AccessibilitySettings.fromJson({
      'hearingSupport': true,
      'largeText': true,
    });

    expect(settings.hearingSupport, isTrue);
    expect(settings.screenFlash, isFalse);
  });

  test('household registration requires separate sensitive-data consent',
      () async {
    final controller = PrototypeSafetyController();
    await controller.load();
    final before = controller.households.length;

    await expectLater(
      controller.registerHousehold(
        label: '시연 가구',
        address: '구룡포읍 시연로 1',
        members: 1,
        needs: const ['elderly'],
        consent: false,
        consentBy: '본인',
        consentMethod: 'app',
        note: '',
        delegated: false,
      ),
      throwsArgumentError,
    );
    expect(controller.households, hasLength(before));
  });

  test('only a demo responder role can create delegated households or visits',
      () async {
    final controller = PrototypeSafetyController();
    await controller.load();

    await expectLater(
      controller.recordVisit(
        householdId: 'sample-1',
        result: 'already_evacuated',
        note: '',
      ),
      throwsStateError,
    );
    expect(await controller.claimDemoRole('DEMO-RESPONDER'), isTrue);
    await controller.recordVisit(
      householdId: 'sample-1',
      result: 'already_evacuated',
      note: '확인 완료',
    );

    expect(controller.visits, hasLength(1));
    expect(controller.households.first.status, '대피 완료');
  });

  testWidgets('evacuation card checks the saved response beside its button',
      (tester) async {
    final controller = PrototypeSafetyController();
    await controller.load();
    final selected = <EvacuationResponseStatus>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [prototypeSafetyProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        home: Scaffold(
          body: EvacuationResponseCard(
            alertId: 'alert-1',
            title: '대피 확인',
            detail: '안전 상태를 알려 주세요.',
            onResponse: (status) async {
              selected.add(status);
              await controller.respond('alert-1', status);
            },
          ),
        ),
      ),
    ));

    for (final status in EvacuationResponseStatus.values) {
      await tester.tap(find.text(status.label).last);
      await tester.pumpAndSettle();
      expect(controller.responseFor('alert-1'), status);
      expect(find.byIcon(Icons.check), findsOneWidget);
    }
    expect(selected, EvacuationResponseStatus.values);
  });

  testWidgets(
      'warning card exposes voice status, replay, microphone, and actions',
      (tester) async {
    final controller = PrototypeSafetyController();
    await controller.load();
    await controller.updateAccessibility(
      controller.accessibility.copyWith(
        visionSupport: true,
        voicePrompts: true,
      ),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [prototypeSafetyProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        home: Scaffold(
          body: EvacuationResponseCard(
            alertId: 'alert-voice',
            title: '침수 대피 경보',
            detail: '안전한 장소로 이동해 주세요.',
            onResponse: (_) async {},
            onReplayVoice: () {},
            onVoice: () {},
          ),
        ),
      ),
    ));

    expect(find.text('경보 안내 음성이 자동 재생됩니다'), findsOneWidget);
    expect(find.text('경보 안내 다시 듣기'), findsOneWidget);
    expect(find.byIcon(Icons.mic_none_outlined), findsOneWidget);
    expect(find.text('음성 응답 시연'), findsOneWidget);
    expect(find.text('실제 마이크 입력 없이 문구를 선택하는 시연입니다.'), findsOneWidget);

    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('대피 완료 응답 보내기'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('screen reader announcement replaces automatic TTS status',
      (tester) async {
    final controller = PrototypeSafetyController();
    await controller.load();
    await controller.updateAccessibility(
      controller.accessibility.copyWith(
        visionSupport: true,
        voicePrompts: true,
      ),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [prototypeSafetyProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(accessibleNavigation: true),
          child: Scaffold(
            body: EvacuationResponseCard(
              alertId: 'alert-reader',
              title: '침수 대피 경보',
              detail: '안전한 장소로 이동해 주세요.',
              accessibleNavigation: true,
              onResponse: (_) async {},
            ),
          ),
        ),
      ),
    ));

    expect(find.text('화면낭독기가 경고 내용을 안내합니다'), findsOneWidget);
    expect(find.text('경보 안내 음성이 자동 재생됩니다'), findsNothing);
  });

  testWidgets('large warning text wraps in a narrow viewport', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = PrototypeSafetyController();
    await controller.load();
    await controller.updateAccessibility(
      controller.accessibility.copyWith(largeText: true),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [prototypeSafetyProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        home: Scaffold(
          body: EvacuationResponseCard(
            alertId: 'alert-large-text',
            title: '구룡포 저지대 침수 대피 확인 경보',
            detail: '안전한 실내 또는 지정 대피소로 이동해 주세요.',
            onResponse: (_) async {},
          ),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    final warningTitle = tester.widget<Text>(
      find.text('구룡포 저지대 침수 대피 확인 경보'),
    );
    expect(warningTitle.style?.fontSize, greaterThan(16));
  });

  testWidgets('warning effects flash at one cycle per second and stop by 30s',
      (tester) async {
    final controller = PrototypeSafetyController();
    await controller.load();
    await controller.updateAccessibility(
      controller.accessibility.copyWith(
        hearingSupport: true,
        screenFlash: true,
        strongVibration: true,
      ),
    );
    final hapticCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          hapticCalls.add(call.method);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(ProviderScope(
      overrides: [prototypeSafetyProvider.overrideWith((ref) => controller)],
      child: const MaterialApp(home: Scaffold(body: EvacuationDemoScreen())),
    ));
    await tester.pump();
    final backgroundFinder =
        find.byKey(const ValueKey('evacuation-demo-background'));
    expect(
      (tester.widget<AnimatedContainer>(backgroundFinder).decoration
              as BoxDecoration)
          .color,
      isNull,
    );

    await tester.pump(evacuationFlashTransitionInterval);
    expect(
      (tester.widget<AnimatedContainer>(backgroundFinder).decoration
              as BoxDecoration)
          .color,
      const Color(0xffffe082),
    );
    await tester.pump(evacuationFlashTransitionInterval);
    expect(
      (tester.widget<AnimatedContainer>(backgroundFinder).decoration
              as BoxDecoration)
          .color,
      isNull,
    );
    await tester
        .pump(evacuationFlashDuration - evacuationFlashTransitionInterval * 3);
    expect(
      (tester.widget<AnimatedContainer>(backgroundFinder).decoration
              as BoxDecoration)
          .color,
      isNotNull,
    );
    await tester.pump(evacuationFlashTransitionInterval);
    expect(
      (tester.widget<AnimatedContainer>(backgroundFinder).decoration
              as BoxDecoration)
          .color,
      isNull,
    );
    expect(hapticCalls, hasLength(evacuationHapticPulseLimit));
  });

  testWidgets('hearing and vision support enable their related preferences',
      (tester) async {
    final controller = PrototypeSafetyController();
    await controller.load();
    await tester.pumpWidget(ProviderScope(
      overrides: [prototypeSafetyProvider.overrideWith((ref) => controller)],
      child: const MaterialApp(home: AccessibilitySettingsScreen()),
    ));

    await tester.tap(find.text('청각 지원 경보'));
    await tester.pumpAndSettle();
    expect(controller.accessibility.hearingSupport, isTrue);
    expect(controller.accessibility.strongVibration, isTrue);
    expect(controller.accessibility.screenFlash, isTrue);
    expect(controller.accessibility.largeText, isTrue);

    await tester.tap(find.text('시각 지원 음성 안내'));
    await tester.pumpAndSettle();
    expect(controller.accessibility.visionSupport, isTrue);
    expect(controller.accessibility.voicePrompts, isTrue);
  });

  test(
      'automatic prompt requires support, opt-in, and no accessible navigation',
      () {
    const enabled = AccessibilitySettings(
      visionSupport: true,
      voicePrompts: true,
    );
    expect(
      shouldAutoPlayAccessibilityPrompt(enabled, accessibleNavigation: false),
      isTrue,
    );
    expect(
      shouldAutoPlayAccessibilityPrompt(enabled, accessibleNavigation: true),
      isFalse,
    );
    expect(
      shouldAutoPlayAccessibilityPrompt(
        enabled.copyWith(voicePrompts: false),
        accessibleNavigation: false,
      ),
      isFalse,
    );
    expect(
      shouldAutoPlayAccessibilityPrompt(
        enabled.copyWith(visionSupport: false),
        accessibleNavigation: false,
      ),
      isFalse,
    );
  });
}
