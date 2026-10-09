import 'dart:typed_data';
import 'package:latlong2/latlong.dart';
import '../models/domain_models.dart';
import '../services/account_service.dart';

/// 화면이 쓰는 데이터 창구. 목업(MockSafetyRepository)과 실제 서버(RemoteSafetyRepository)가 같은 형식으로 돌려준다.
/// origin = 사용자 현재 위치 (구룡포 안 GPS, 아니면 사용자 유형별 예시 좌표 — main.dart userLocation).
abstract class SafetyRepository {
  Future<RiskStatus> risk(LatLng origin);
  Future<List<RiskArea>> riskAreas();
  Future<List<FloodGrid>> floodGrid({int timeIndex = 0});
  Future<List<Facility>> getFacilities(LatLng origin);
  Future<List<AlertItem>> alerts(LatLng origin);
  Future<AlertPollResult> pollAlerts(
    LatLng origin, {
    String? since,
    String? deviceId,
  });
  Future<RouteCheckResult> checkRoute({
    required LatLng current,
    required LatLng destination,
    required String geometry,
    required String profile,
    required String facilityId,
    required RouteType routeType,
  });
  Future<String?> registerDeviceToken(String token, String platform);
  Future<void> unregisterDeviceToken(String token);
  Future<void> markAlertRead(String alertId);
  Future<void> respondToAlert({
    required String alertId,
    required String status,
    required LatLng location,
  });
  Future<SafetyRoute> routeFor(Facility facility, UserMode userMode, RouteType routeType, LatLng origin);
  Future<ChatAnswer> ask(String question, UserMode userMode, LatLng origin);

  /// 음성 질문 (WAV 녹음) → 받아쓴 질문 + 답 + 답 음성. 실패하면 RemoteError 메시지와 함께 예외
  Future<VoiceAnswer> askVoice(Uint8List wav, UserMode userMode, LatLng origin);

  /// 문장 → 음성(mp3). 음성 기능을 쓸 수 없으면 null
  Future<Uint8List?> speak(String text);
}

class MockSafetyRepository implements SafetyRepository {
  final AccountService _account = AccountService();
  final Map<String, String> _alertResponses = {};

  @override
  Future<AlertPollResult> pollAlerts(
    LatLng origin, {
    String? since,
    String? deviceId,
  }) async => AlertPollResult(
    alerts: await alerts(origin),
    serverTime: DateTime.now().toUtc(),
    nextPollSeconds: 60,
    mode: 'normal',
  );

  @override
  Future<RouteCheckResult> checkRoute({
    required LatLng current,
    required LatLng destination,
    required String geometry,
    required String profile,
    required String facilityId,
    required RouteType routeType,
  }) async => const RouteCheckResult(
    reroute: false,
    reasons: [],
    offRouteMeters: 0,
    hazardsAhead: [],
    arrived: false,
  );

  @override
  Future<String?> registerDeviceToken(String token, String platform) async =>
      null;

  @override
  Future<void> unregisterDeviceToken(String token) async {}

  @override
  Future<void> markAlertRead(String alertId) async {}

  @override
  Future<void> respondToAlert({
    required String alertId,
    required String status,
    required LatLng location,
  }) async {
    _alertResponses[alertId] = status;
  }

  @override
  Future<List<FloodGrid>> floodGrid({int timeIndex = 0}) async => demoFloodGrid(timeIndex);

  static final facilities = <Facility>[
    Facility(
        id: 'gym',
        name: '구룡포 실내체육관 (예시)',
        type: FacilityType.shelter,
        position: LatLng(35.9928, 129.5518),
        address: '구룡포읍 예시로 12',
        description: '휠체어 접근 가능한 예시 대피소',
        distanceKm: .8,
        walkMinutes: 12,
        accessible: true),
    Facility(
        id: 'school',
        name: '구룡포초등학교 (예시)',
        type: FacilityType.shelter,
        position: LatLng(35.9898, 129.5501),
        address: '구룡포읍 예시로 25',
        description: '운영 중인 예시 대피소',
        distanceKm: 1.2,
        walkMinutes: 18,
        accessible: true),
    Facility(
        id: 'hall',
        name: '구룡포 문화회관 (예시)',
        type: FacilityType.shelter,
        position: LatLng(35.9955, 129.5562),
        address: '구룡포읍 예시로 48',
        description: '보조 대피 후보',
        distanceKm: 1.5,
        walkMinutes: 21,
        accessible: false),
    Facility(
        id: 'clinic',
        name: '구룡포 의료지원소 (예시)',
        type: FacilityType.medical,
        position: LatLng(35.9915, 129.5554),
        address: '구룡포읍 예시로 31',
        description: '응급 처치 예시 시설',
        distanceKm: .9,
        walkMinutes: 13,
        accessible: true),
  ];

  /// Every selectable example facility has a bent, in-service-area walking
  /// polyline for each user origin and route preference. There is deliberately
  /// no text-only fallback route.
  static final _routes = <String, SafetyRoute>{
    // User origin: 35.9918, 129.5507
    'user/safest/gym': _route('gym', RouteType.safest, 640, 10,
        '침수 예시 구간을 피해 실내체육관으로 이동합니다.', [
      (35.9918, 129.5507), (35.9911, 129.5512), (35.9920, 129.5515),
      (35.9928, 129.5518)
    ]),
    'user/nearest/gym': _route('gym', RouteType.nearest, 520, 8,
        '가까운 보행로를 따라 이동합니다.', [
      (35.9918, 129.5507), (35.9922, 129.5511), (35.9928, 129.5518)
    ]),
    'user/safest/school': _route('school', RouteType.safest, 980, 15,
        '저지대 보행로를 피해 학교 대피소로 이동합니다.', [
      (35.9918, 129.5507), (35.9913, 129.5512), (35.9908, 129.5508),
      (35.9898, 129.5501)
    ]),
    'user/nearest/school': _route('school', RouteType.nearest, 820, 12,
        '가까운 골목 보행로를 경유합니다.', [
      (35.9918, 129.5507), (35.9909, 129.5507), (35.9898, 129.5501)
    ]),
    'user/safest/hall': _route('hall', RouteType.safest, 1300, 19,
        '위험 표지 구간을 피해 문화회관으로 이동합니다.', [
      (35.9918, 129.5507), (35.9921, 129.5520), (35.9934, 129.5532),
      (35.9944, 129.5550), (35.9955, 129.5562)
    ]),
    'user/nearest/hall': _route('hall', RouteType.nearest, 1120, 16,
        '가까운 교차로를 이용하는 보행 경로입니다.', [
      (35.9918, 129.5507), (35.9929, 129.5527), (35.9940, 129.5546),
      (35.9955, 129.5562)
    ]),
    'user/safest/clinic': _route('clinic', RouteType.safest, 780, 12,
        '침수 위험 표지 주변을 우회해 의료지원소로 이동합니다.', [
      (35.9918, 129.5507), (35.9922, 129.5518), (35.9920, 129.5530),
      (35.9915, 129.5554)
    ]),
    'user/nearest/clinic': _route('clinic', RouteType.nearest, 650, 10,
        '가까운 보행로로 의료지원소에 접근합니다.', [
      (35.9918, 129.5507), (35.9919, 129.5524), (35.9915, 129.5540),
      (35.9915, 129.5554)
    ]),
  };

  static SafetyRoute _route(String shelterId, RouteType routeType,
      int distanceMeters, int estimatedMinutes, String avoidance,
      List<(double, double)> points) => SafetyRoute(
          shelterId: shelterId,
          routeType: routeType,
          distanceMeters: distanceMeters,
          estimatedMinutes: estimatedMinutes,
          riskAvoidanceSummary: avoidance,
          polylinePoints: points.map((point) => LatLng(point.$1, point.$2)).toList());

  /// 예시 경로 조회 (동기). 테스트와 [routeFor]가 쓴다.
  SafetyRoute exampleRoute(
      String facilityId, UserMode userMode, RouteType routeType) {
    // 오르막 회피(2026-10-07 추가)는 목업 예시가 없어 안전 경로 예시를 그대로 쓴다
    final key = routeType == RouteType.flat ? RouteType.safest : routeType;
    final route = _routes['${userMode.name}/${key.name}/$facilityId'];
    if (route == null) {
      throw StateError('No map route is configured for $facilityId.');
    }
    if (routeType != RouteType.flat) return route;
    return SafetyRoute(
        shelterId: route.shelterId,
        routeType: RouteType.flat,
        polylinePoints: route.polylinePoints,
        distanceMeters: route.distanceMeters,
        estimatedMinutes: route.estimatedMinutes,
        riskAvoidanceSummary: route.riskAvoidanceSummary,
        avoided: route.avoided,
        stillInside: route.stillInside,
        profile: route.profile,
        maxSlopePercent: route.maxSlopePercent,
        maxUphillPercent: route.maxUphillPercent,
        hazardsOk: route.hazardsOk,
        encodedGeometry: route.encodedGeometry,
        seaPoints: route.seaPoints);
  }

  Future<SafetyRoute> _applySavedProfile(SafetyRoute route) async {
    final (age, transport) = await _account.requiredSetup();
    final profile = deriveRouteProfile(age, transport);
    return SafetyRoute(
      shelterId: route.shelterId,
      routeType: route.routeType,
      polylinePoints: route.polylinePoints,
      distanceMeters: route.distanceMeters,
      estimatedMinutes: route.estimatedMinutes,
      riskAvoidanceSummary: route.riskAvoidanceSummary,
      avoided: route.avoided,
      stillInside: route.stillInside,
      profile: profile,
      maxSlopePercent: route.routeType == RouteType.safest ? 5 : 9,
      hazardsOk: true,
    );
  }

  @override
  Future<SafetyRoute> routeFor(
      Facility facility, UserMode userMode, RouteType routeType, LatLng origin) async {
    await Future<void>.delayed(const Duration(milliseconds: 550));
    return _applySavedProfile(exampleRoute(facility.id, userMode, routeType));
  }
  @override
  Future<List<RiskArea>> riskAreas() async => const [];
  @override
  Future<RiskStatus> risk(LatLng origin) async { await Future<void>.delayed(const Duration(milliseconds: 450)); return const RiskStatus(
      level: '경계',
      title: '호우·침수 위험 예시',
      summary: '예시 데이터: 저지대 보행 시 침수 구간과 맨홀을 피하세요.',
      updatedAt: '10:42',
      guide: '안전한 실내 또는 지정 대피소로 이동하고, 물이 고인 도로와 해안가에 접근하지 마세요.'); }
  @override
  Future<List<Facility>> getFacilities(LatLng origin) async { await Future<void>.delayed(const Duration(milliseconds: 350)); return facilities; }
  @override
  Future<List<AlertItem>> alerts(LatLng origin) async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    const items = [
        AlertItem(
            id: 'work-flood',
            title: '선제 경고: 등록된 직장 침수 위험',
            level: '경계',
            time: '10:32',
            summary: '예시 데이터 기준, 등록된 직장이 침수 위험 지역에 포함될 가능성이 높습니다. 해당 지역 방문을 피하고, 안전한 장소와 대피 경로를 확인하세요.',
            guide: '관련 등록 장소: 직장 · 저지대·침수 구간·맨홀 주변을 피하고 안전한 실내 또는 지정 대피소로 이동하세요.'),
        AlertItem(
            id: 'wind',
            title: '강풍 주의 예시',
            level: '주의',
            time: '09:58',
            summary: '해안가 돌풍이 예상됩니다.',
            guide: '해안·방파제 접근을 피하고 낙하물에 주의하세요.'),
        AlertItem(
            id: 'uv',
            title: '자외선 높음 예시',
            level: '주의',
            time: '08:00',
            summary: '생활 안전 정보입니다.',
            guide: '외출 시 모자와 자외선 차단을 사용하세요.')
      ];
    return items.map((alert) {
      final status = _alertResponses[alert.id];
      return status == null ? alert : alert.copyWith(myStatus: status);
    }).toList();
  }
  @override
  Future<ChatAnswer> ask(String question, UserMode userMode, LatLng origin) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final wantsRoute = ['대피소', '의료시설', '병원', '경로', '도보로'].any(question.contains);
    if (!wantsRoute) return ChatAnswer(_mockAnswer(question));
    final medical = question.contains('의료') || question.contains('병원');
    final facility = facilities.firstWhere((f) => f.type == (medical ? FacilityType.medical : FacilityType.shelter));
    final routeType = question.contains('가까운') || question.contains('최단') ? RouteType.nearest : RouteType.safest;
    final route = await _applySavedProfile(
        exampleRoute(facility.id, userMode, routeType));
    return ChatAnswer(
      '${_mockAnswer(question)}\n목업 경로 · ${route.distanceMeters}m · 도보 약 ${route.estimatedMinutes}분',
      route: route,
      destinationName: facility.name,
      destinationKind: medical ? 'medical' : 'shelter',
      destinationPos: facility.position,
    );
  }

  // 목업은 받아쓰기·음성 합성이 없다. 녹음 여부와 상관없이 예시 질문으로 답한다
  @override
  Future<VoiceAnswer> askVoice(Uint8List wav, UserMode userMode, LatLng origin) async =>
      VoiceAnswer('(예시) 대피소 어디야?', ChatAnswer(_mockAnswer('대피소')));

  @override
  Future<Uint8List?> speak(String text) async => null;

  String _mockAnswer(String question) {
    if (question.contains('대피소'))
      return '예시 데이터: 가장 안전한 대피소는 구룡포 실내체육관입니다. 0.8km, 도보 12분이며 침수 예시 구간을 피합니다.';
    if (question.contains('의료') || question.contains('병원'))
      return '예시 데이터: 구룡포 의료지원소까지의 경로를 준비했습니다. 실제 운영 여부와 응급 진료 가능 여부를 먼저 확인하세요.';
    if (question.contains('침수') || question.contains('위험'))
      return '예시 데이터: 현재는 경계 단계입니다. 저지대 보행과 맨홀 주변을 피하고 안전한 실내로 이동하세요.';
    if (question.contains('미세먼지'))
      return '예시 생활 안전: 미세먼지는 보통입니다. 장시간 야외 활동 시 개인 건강 상태에 따라 마스크를 사용하세요.';
    if (question.contains('자외선'))
      return '예시 생활 안전: 자외선 지수는 높음입니다. 모자와 자외선 차단제를 사용하세요.';
    if (question.contains('생활'))
      return '예시 생활 안전: 미세먼지 보통, 자외선 높음입니다. 기상 변화와 개인 건강 상태를 함께 확인하세요.';
    return '예시 AI 답변입니다. 현재 위치, 위험 상태, 시설 정보를 바탕으로 안전 경로와 행동 요령을 안내합니다.';
  }
}
