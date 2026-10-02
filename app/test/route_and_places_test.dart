// AI 답의 경로 → 지도, 등록 장소 저장 → AI 요청 profile, 보행 불편 → 노약자 경로
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:guryongpo_safety/dashboard_parts.dart';
import 'package:guryongpo_safety/main.dart';
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/repositories/mock_repository.dart';
import 'package:guryongpo_safety/repositories/remote_repository.dart';
import 'package:guryongpo_safety/services/account_service.dart';

const _chat = {
  'conversation_id': 'c1',
  'answer': '구룡포항까지 성인 경로로 902m, 도보 12분입니다.',
  'route': {
    'destination': {'name': '구룡포항', 'lat': 35.9905, 'lon': 129.556, 'kind': 'place'},
    'profile': 'adult', 'distance_m': 902, 'duration_s': 700, 'avoided': ['flood-67'], 'still_inside': [],
    'hazards_ok': true, 'geometry': '_p~iF~ps|U_ulLnnqC',
  },
};

/// 목업 저장소 + AI 답에 경로가 오는 가짜
class RouteAnsweringRepo extends MockSafetyRepository {
  @override
  Future<ChatAnswer> ask(String question, UserMode userMode) async => chatAnswerFromJson(_chat);
}

void main() {
  test('채팅 응답의 경로 → 지도용 경로·목적지', () {
    final a = chatAnswerFromJson(_chat, names: {'flood-67': '침수 경보'});
    expect(a.text, contains('902m'));
    expect(a.route!.polylinePoints, hasLength(2));
    expect(a.route!.riskAvoidanceSummary, contains('침수 경보'));
    expect((a.destinationName, a.destinationKind), ('구룡포항', 'place'));
    expect(a.destinationPos, const LatLng(35.9905, 129.556));
    expect(chatAnswerFromJson({'answer': '안녕하세요'}).route, isNull);
  });

  test('등록 장소 저장·삭제와 AI 요청 profile', () async {
    SharedPreferences.setMockInitialValues({});
    final acc = AccountService();
    await acc.addPlace(const SavedPlace(id: '1', name: '우리집', type: '집', position: LatLng(35.99, 129.55)));
    await acc.addPlace(const SavedPlace(id: '2', name: '수산 작업장', type: '직장', position: LatLng(35.98, 129.56)));
    await acc.addPlace(const SavedPlace(id: '3', name: '교회', type: '기타', position: LatLng(35.97, 129.54), alert: false));
    final places = await acc.places();
    expect(places.map((p) => p.name), ['우리집', '수산 작업장', '교회']);
    expect(placesForProfile(places), {
      'home': {'lat': 35.99, 'lon': 129.55, 'label': '집'},
      'frequent_places': [
        {'lat': 35.98, 'lon': 129.56, 'label': '직장'},
        {'lat': 35.97, 'lon': 129.54, 'label': '교회'},
      ],
    });
    await acc.removePlace('2');
    expect((await acc.places()).map((p) => p.id), ['1', '3']);
    expect(placesForProfile(const []), isEmpty);
  });

  test("선택 정보 '보행 능력'을 적으면 노약자 경로", () async {
    SharedPreferences.setMockInitialValues({});
    final acc = AccountService();
    expect(await acc.walkingImpaired(), isFalse);
    await acc.saveOptionalProfile({'보행 능력': '무릎이 불편함'});
    expect(await acc.walkingImpaired(), isTrue);
    expect(routeProfileFor(40, '도보', walkingImpaired: true), 'elderly');
    expect(routeProfileFor(40, '도보'), 'adult');
  });

  testWidgets('AI 답의 "지도에서 경로 보기" → 대시보드 지도가 그 경로를 그린다', (t) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    // 테스트에서는 지도 타일 다운로드가 막혀 이미지 오류가 난다 — 그것만 무시하고 나머지 오류는 그대로 실패로 본다
    final onError = FlutterError.onError;
    FlutterError.onError = (d) { if (d.library != 'image resource service') onError?.call(d); };
    addTearDown(() => FlutterError.onError = onError);
    SharedPreferences.setMockInitialValues({'profile_setup_complete': true});
    await t.pumpWidget(ProviderScope(overrides: [repo.overrideWithValue(RouteAnsweringRepo())], child: const GuryongpoApp()));
    for (var i = 0; i < 10; i++) { await t.pump(const Duration(milliseconds: 300)); }
    final chip = find.text('지금 침수 위험이 있어?');
    await t.ensureVisible(chip.first);
    await t.tap(chip.first);
    for (var i = 0; i < 4; i++) { await t.pump(const Duration(milliseconds: 300)); }
    final button = find.byType(RouteButton);
    expect(button, findsOneWidget);
    await t.ensureVisible(button);
    await t.tap(find.text('지도에서 경로 보기'));
    for (var i = 0; i < 6; i++) { await t.pump(const Duration(milliseconds: 300)); }
    expect(find.byType(RouteMap), findsOneWidget);
    expect(find.textContaining('구룡포항 · 0.9km · 도보 12분'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });
}
