// 사용자 화면 간결화 (2026-10-09 사용자 요청): 내 정보 요약·수정, 접근성 지원 요약, 알림 6개, 안전 기능 2개,
// 방재단 전용 코드 로그인(서버 인증을 거쳐야만 방재단 화면), 지운 항목이 다시 나오지 않는지, 좁은 화면 배치
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:guryongpo_safety/live_screens.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/profile_cards.dart';
import 'package:guryongpo_safety/profile_refresh.dart';
import 'package:guryongpo_safety/services/account_sync.dart';
import 'package:guryongpo_safety/services/demo_mode.dart';
import 'package:guryongpo_safety/services/live_api.dart';
import 'package:guryongpo_safety/ui/gk_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 서버 대신: 'GRP-OK'만 방재단, 'CARE-1'은 돌봄 담당, 나머지는 서버처럼 400 INVALID_INVITE
class FakeTeamApi extends LiveApi {
  final codes = <String>[];
  @override
  Future<Map<String, dynamic>> me() async => {'role': 'resident'};
  @override
  Future<Map<String, dynamic>> claimRole(String code) async {
    codes.add(code);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (code.trim() == 'GRP-OK') return {'role': 'responder', 'label': '구룡포 방재단'};
    if (code.trim() == 'CARE-1') return {'role': 'caregiver', 'label': '돌봄'};
    final req = RequestOptions(path: '/api/v1/user/role');
    throw DioException(
        requestOptions: req,
        response: Response(
            requestOptions: req, statusCode: 400, data: {'code': 'INVALID_INVITE', 'message': '초대 코드가 올바르지 않거나 만료되었습니다.'}));
  }
}

Widget app({bool demo = true, LiveApi? api}) {
  final router = GoRouter(initialLocation: '/profile', routes: [
    GoRoute(path: '/profile', builder: (_, __) => const Scaffold(body: ProfileScreen())),
    GoRoute(path: '/responder', builder: (_, __) => const Scaffold(body: Text('방재단 화면'))),
    GoRoute(path: '/sea-route', builder: (_, __) => const Scaffold(body: Text('해상 경로 화면'))),
  ]);
  return ProviderScope(overrides: [
    showDemoProvider.overrideWithValue(demo),
    if (api != null) liveApiProvider.overrideWithValue(api),
    meProvider.overrideWith((_) async => {'role': 'resident'}),
  ], child: MaterialApp.router(routerConfig: router));
}

Future<void> setSize(WidgetTester t, double w, [double h = 3200]) async {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('접근성 지원 요약: 정하지 않음 / 꺼 둠 / 켠 것', () {
    expect(accessibilitySummary({}), '설정 안 함');
    expect(accessibilitySummary({'시각 지원': '필요 없음'}), '사용 안 함');
    expect(accessibilitySummary({'시각 지원': '필요 없음', '청각 지원': '필요 없음'}), '사용 안 함');
    expect(accessibilitySummary({'시각 지원': '저시력', '청각 지원': '필요 없음'}), '시각');
    expect(accessibilitySummary({'시각 지원': '지원 필요', '청각 지원': '난청'}), '시각 · 청각');
    expect(accessibilitySummary({'청각': '지원 필요'}), '청각'); // 예전 키
  });

  test('AI 수집 기록: 보행·동반자는 화면에 보이지 않는다', () {
    expect(shownProfileUpdate(const ProfileUpdate(id: 1, field: 'walking_impaired', label: '보행', value: '보행 불편')), isFalse);
    expect(shownProfileUpdate(const ProfileUpdate(id: 2, field: 'has_dependents', label: '보호가 필요한 동반자', value: '있음')),
        isFalse);
    expect(shownProfileUpdate(const ProfileUpdate(id: 3, label: '보행', value: '보행 불편')), isFalse); // field 없는 옛 응답
    expect(shownProfileUpdate(const ProfileUpdate(id: 4, field: 'occupation', label: '직업', value: '어업 종사')), isTrue);
  });

  testWidgets('요약 카드 항목·순서, 지운 메뉴는 없음', (t) async {
    await setSize(t, 1280);
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    final labels = ['나이', '접근성 지원', '이동 수단', '직업', '집', '내 장소'];
    final ys = [for (final l in labels) t.getTopLeft(find.text(l).first).dy];
    expect(ys, [...ys]..sort(), reason: '나이 → 접근성 지원 → 이동 수단 → 직업 → 집 → 내 장소 순서');
    expect(find.text('설정 안 함'), findsOneWidget);
    expect(find.text('내 장소 추가하기'), findsOneWidget);
    for (final s in ['음성 안내 자동 재생', '진동 알림', '화면 점멸', '청각 지원', '시각 지원', '재난 푸시 알림']) {
      expect(find.widgetWithText(GkSwitchRow, s), findsOneWidget, reason: s);
    }
    expect(find.text('광과민성이 있으면 꺼 두세요'), findsOneWidget);
    for (final gone in ['경고·대피 확인', '재난 후 지원·복구', '내 가구 등록', '보행 능력', '보호가 필요한 동반자', '출발 위치']) {
      expect(find.textContaining(gone), findsNothing, reason: gone);
    }
    expect(find.textContaining('음성 언어'), findsNothing);
    expect(find.textContaining('접근성 자세히'), findsNothing);
    expect(find.text('바다 위 대피 경로'), findsOneWidget);
    expect(find.text('방재단 현황 (시연)'), findsOneWidget); // 시연 모드는 시연 데이터 화면으로 바로
  });

  testWidgets('수정 → 나이·이동 수단·직업 기타 입력 → 저장하면 요약에 보인다', (t) async {
    await setSize(t, 1280);
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    await t.tap(find.text('수정'));
    await t.pumpAndSettle();
    expect(find.text('내 정보 수정'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextFormField, '예: 35'), '70');
    await t.tap(find.widgetWithText(ChoiceChip, '휠체어'));
    await t.tap(find.widgetWithText(FilterChip, '기타'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextFormField, '직업을 입력해 주세요'), '해녀');
    await t.tap(find.widgetWithText(FilledButton, '저장'));
    await t.pumpAndSettle();
    expect(find.text('내 정보'), findsOneWidget);
    expect(find.text('70세'), findsOneWidget);
    expect(find.text('휠체어'), findsOneWidget);
    expect(find.text('해녀'), findsOneWidget);
    final saved = await SharedPreferences.getInstance();
    expect(saved.getString('optional_profile'), allOf(contains('"age":"70"'), contains('"transport":"휠체어"')));
  });

  testWidgets('시각 지원 스위치 → 접근성 지원 요약 (켬 → 시각, 끔 → 사용 안 함)', (t) async {
    await setSize(t, 1280);
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(GkSwitchRow, '시각 지원'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(GkInfoRow, '시각'), findsOneWidget);
    await t.tap(find.widgetWithText(GkSwitchRow, '시각 지원'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(GkInfoRow, '사용 안 함'), findsOneWidget);
  });

  testWidgets('내 장소 추가하기 → 장소 등록 창', (t) async {
    await setSize(t, 1280);
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    await t.tap(find.text('내 장소 추가하기'));
    await t.pumpAndSettle();
    expect(find.text('내 장소 추가'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '주소 확인 후 추가'), findsOneWidget);
  });

  testWidgets('방재단 로그인: 빈 코드 비활성 · 틀린 코드 오류 · 돌봄 코드 거절 · 맞는 코드만 방재단 화면', (t) async {
    await setSize(t, 1280);
    final api = FakeTeamApi();
    await t.pumpWidget(app(demo: false, api: api));
    await t.pumpAndSettle();
    await t.tap(find.text('방재단 로그인'));
    await t.pumpAndSettle();
    expect(find.text('방재단원은 전용 코드로 로그인하세요'), findsOneWidget);
    expect(find.text('방재단 전용 코드'), findsOneWidget);
    FilledButton login() => t.widget<FilledButton>(find.widgetWithText(FilledButton, '로그인'));
    expect(login().onPressed, isNull); // 빈 코드

    await t.enterText(find.widgetWithText(TextField, '예: GRP-1234'), 'WRONG');
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, '로그인'));
    await t.pump();
    expect(find.text('확인 중…'), findsOneWidget); // 처리 중 → 다시 못 누름
    await t.tap(find.text('확인 중…'), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(api.codes, ['WRONG']);
    expect(find.textContaining('코드가 맞지 않거나 만료됐어요'), findsOneWidget);
    expect(find.text('방재단 화면'), findsNothing);

    await t.enterText(find.byType(TextField).last, 'CARE-1');
    await t.tap(find.widgetWithText(FilledButton, '로그인'));
    await t.pumpAndSettle();
    expect(find.textContaining('돌봄 담당 코드예요'), findsOneWidget);
    expect(find.text('방재단 화면'), findsNothing);

    await t.enterText(find.byType(TextField).last, 'GRP-OK');
    await t.tap(find.widgetWithText(FilledButton, '로그인'));
    await t.pumpAndSettle();
    expect(find.text('방재단 화면'), findsOneWidget);
  });

  testWidgets('좁은 화면(360px): 넘침 없음, 안전 기능·로그인 칸 세로 배치', (t) async {
    await setSize(t, 360, 5000);
    await t.pumpWidget(app(demo: false, api: FakeTeamApi()));
    await t.pumpAndSettle();
    final sea = t.getTopLeft(find.text('바다 위 대피 경로'));
    final team = t.getTopLeft(find.text('방재단 로그인'));
    expect(team.dy, greaterThan(sea.dy));
    await t.tap(find.text('방재단 로그인'));
    await t.pumpAndSettle();
    final field = t.getTopLeft(find.widgetWithText(TextField, '예: GRP-1234'));
    final button = t.getTopLeft(find.widgetWithText(FilledButton, '로그인'));
    expect(button.dy, greaterThan(field.dy));
    expect(t.takeException(), isNull);
  });
}
