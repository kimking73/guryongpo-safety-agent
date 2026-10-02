import 'package:latlong2/latlong.dart';
import '../models/domain_models.dart';

/// 화면이 쓰는 데이터 창구. 목업(MockSafetyRepository)과 실제 서버(RemoteSafetyRepository)가 같은 형식으로 돌려준다.
abstract class SafetyRepository {
  Future<RiskStatus> risk(UserMode userMode);
  Future<List<RiskArea>> riskAreas();
  Future<List<Facility>> getFacilities(UserMode userMode);
  Future<List<AlertItem>> alerts(UserMode userMode);
  Future<SafetyRoute> routeFor(Facility facility, UserMode userMode, RouteType routeType);
  Future<ChatAnswer> ask(String question, UserMode userMode);
}

class MockSafetyRepository implements SafetyRepository {
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
    // Visitor origin: 35.9907, 129.5526
    'visitor/safest/gym': _route('gym', RouteType.safest, 800, 12,
        '침수 예시 구간과 맨홀 주변을 우회합니다.', [
      (35.9907, 129.5526), (35.9912, 129.5505), (35.9910, 129.5514),
      (35.9920, 129.5515), (35.9928, 129.5518)
    ]),
    'visitor/nearest/gym': _route('gym', RouteType.nearest, 680, 10,
        '가까운 보행로를 따라 이동하며 위험 표지를 확인합니다.', [
      (35.9907, 129.5526), (35.9911, 129.5525), (35.9920, 129.5521),
      (35.9928, 129.5518)
    ]),
    'visitor/safest/school': _route('school', RouteType.safest, 1200, 18,
        '저지대 대신 북쪽 보행로로 우회합니다.', [
      (35.9907, 129.5526), (35.9913, 129.5517), (35.9908, 129.5509),
      (35.9902, 129.5506), (35.9898, 129.5501)
    ]),
    'visitor/nearest/school': _route('school', RouteType.nearest, 1010, 15,
        '가까운 도보 구간을 이용합니다.', [
      (35.9907, 129.5526), (35.9909, 129.5518), (35.9901, 129.5509),
      (35.9898, 129.5501)
    ]),
    'visitor/safest/hall': _route('hall', RouteType.safest, 1500, 21,
        '해안가 대신 내륙 보행로로 위험 구간을 회피합니다.', [
      (35.9907, 129.5526), (35.9915, 129.5514), (35.9927, 129.5520),
      (35.9940, 129.5544), (35.9955, 129.5562)
    ]),
    'visitor/nearest/hall': _route('hall', RouteType.nearest, 1280, 18,
        '가까운 교차로를 경유하는 도보 경로입니다.', [
      (35.9907, 129.5526), (35.9920, 129.5530), (35.9935, 129.5546),
      (35.9955, 129.5562)
    ]),
    'visitor/safest/clinic': _route('clinic', RouteType.safest, 900, 13,
        '침수 예시 구간을 피해 의료지원소로 이동합니다.', [
      (35.9907, 129.5526), (35.9909, 129.5514), (35.9918, 129.5510),
      (35.9922, 129.5531), (35.9915, 129.5554)
    ]),
    'visitor/nearest/clinic': _route('clinic', RouteType.nearest, 760, 11,
        '가까운 보행로로 의료지원소에 접근합니다.', [
      (35.9907, 129.5526), (35.9912, 129.5530), (35.9915, 129.5542),
      (35.9915, 129.5554)
    ]),
    // Resident origin: 35.9918, 129.5507
    'resident/safest/gym': _route('gym', RouteType.safest, 640, 10,
        '침수 예시 구간을 피해 실내체육관으로 이동합니다.', [
      (35.9918, 129.5507), (35.9911, 129.5512), (35.9920, 129.5515),
      (35.9928, 129.5518)
    ]),
    'resident/nearest/gym': _route('gym', RouteType.nearest, 520, 8,
        '가까운 보행로를 따라 이동합니다.', [
      (35.9918, 129.5507), (35.9922, 129.5511), (35.9928, 129.5518)
    ]),
    'resident/safest/school': _route('school', RouteType.safest, 980, 15,
        '저지대 보행로를 피해 학교 대피소로 이동합니다.', [
      (35.9918, 129.5507), (35.9913, 129.5512), (35.9908, 129.5508),
      (35.9898, 129.5501)
    ]),
    'resident/nearest/school': _route('school', RouteType.nearest, 820, 12,
        '가까운 골목 보행로를 경유합니다.', [
      (35.9918, 129.5507), (35.9909, 129.5507), (35.9898, 129.5501)
    ]),
    'resident/safest/hall': _route('hall', RouteType.safest, 1300, 19,
        '위험 표지 구간을 피해 문화회관으로 이동합니다.', [
      (35.9918, 129.5507), (35.9921, 129.5520), (35.9934, 129.5532),
      (35.9944, 129.5550), (35.9955, 129.5562)
    ]),
    'resident/nearest/hall': _route('hall', RouteType.nearest, 1120, 16,
        '가까운 교차로를 이용하는 보행 경로입니다.', [
      (35.9918, 129.5507), (35.9929, 129.5527), (35.9940, 129.5546),
      (35.9955, 129.5562)
    ]),
    'resident/safest/clinic': _route('clinic', RouteType.safest, 780, 12,
        '침수 위험 표지 주변을 우회해 의료지원소로 이동합니다.', [
      (35.9918, 129.5507), (35.9922, 129.5518), (35.9920, 129.5530),
      (35.9915, 129.5554)
    ]),
    'resident/nearest/clinic': _route('clinic', RouteType.nearest, 650, 10,
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
    final route = _routes['${userMode.name}/${routeType.name}/$facilityId'];
    if (route == null) {
      throw StateError('No map route is configured for $facilityId.');
    }
    return route;
  }
  @override
  Future<SafetyRoute> routeFor(
      Facility facility, UserMode userMode, RouteType routeType) async {
    await Future<void>.delayed(const Duration(milliseconds: 550));
    return exampleRoute(facility.id, userMode, routeType);
  }
  @override
  Future<List<RiskArea>> riskAreas() async => const [];
  @override
  Future<RiskStatus> risk(UserMode userMode) async { await Future<void>.delayed(const Duration(milliseconds: 450)); return const RiskStatus(
      level: '경계',
      title: '호우·침수 위험 예시',
      summary: '예시 데이터: 저지대 보행 시 침수 구간과 맨홀을 피하세요.',
      updatedAt: '10:42',
      guide: '안전한 실내 또는 지정 대피소로 이동하고, 물이 고인 도로와 해안가에 접근하지 마세요.'); }
  @override
  Future<List<Facility>> getFacilities(UserMode userMode) async { await Future<void>.delayed(const Duration(milliseconds: 350)); return facilities; }
  @override
  Future<List<AlertItem>> alerts(UserMode userMode) async { await Future<void>.delayed(const Duration(milliseconds: 350)); return const [
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
      ]; }
  @override
  Future<ChatAnswer> ask(String question, UserMode userMode) async => ChatAnswer(_mockAnswer(question));

  String _mockAnswer(String question) {
    if (question.contains('대피소'))
      return '예시 데이터: 가장 안전한 대피소는 구룡포 실내체육관입니다. 0.8km, 도보 12분이며 침수 예시 구간을 피합니다.';
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
