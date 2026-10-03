import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart';
import '../models/domain_models.dart';
import '../services/account_service.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/polyline.dart';
import 'mock_repository.dart';

/// 실제 서버 연결 (APP_MODE=remote).
/// - api(8000): 위험도 /api/v1/risk, 위험 영역 /api/v1/risk/areas, 시설 /api/v1/dashboard/layers/{shelters,medical}
/// - ai(8001): /api/chat
/// - route(8002): /api/route
/// 알림은 /api/v1/alerts가 아직 목업(A5)이라 위험도 판정 항목으로 만든다.
class RemoteSafetyRepository implements SafetyRepository {
  RemoteSafetyRepository({ApiClient? client, AccountService? account})
      : _client = client ?? ApiClient(AuthService()),
        _account = account ?? AccountService();
  final ApiClient _client;
  final AccountService _account;
  String? _conversationId;
  Map<String, String>? _hazardNames;

  /// 사용자 위치 주변 이 거리(m) 안의 위험 영역까지 위험도에 넣는다
  static const riskRadiusM = 300;

  Future<Map<String, dynamic>> _risk(LatLng o) async {
    final r = await _guard(() => _client.api.get<Map<String, dynamic>>('/api/v1/risk',
        queryParameters: {'lat': o.latitude, 'lng': o.longitude, 'radius_m': riskRadiusM}));
    return r.data!;
  }

  @override
  Future<RiskStatus> risk(LatLng origin) async => riskFromJson(await _risk(origin));

  @override
  Future<List<AlertItem>> alerts(LatLng origin) async => alertsFromRiskJson(await _risk(origin));

  @override
  Future<List<RiskArea>> riskAreas() async {
    final r = await _guard(() => _client.api.get<Map<String, dynamic>>('/api/v1/risk/areas'));
    return riskAreasFromGeoJson(r.data!);
  }

  @override
  Future<List<Facility>> getFacilities(LatLng o) async {
    final shelters = await _guard(() => _client.api.get<Map<String, dynamic>>('/api/v1/dashboard/layers/shelters'));
    final medical = await _guard(() => _client.api.get<Map<String, dynamic>>('/api/v1/dashboard/layers/medical'));
    return [
      ...facilitiesFromGeoJson(shelters.data!, FacilityType.shelter, o),
      ...facilitiesFromGeoJson(medical.data!, FacilityType.medical, o),
    ]..sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
  }

  @override
  Future<SafetyRoute> routeFor(Facility facility, UserMode userMode, RouteType routeType, LatLng o) async {
    final (age, transport) = await _account.requiredSetup();
    final walking = await _account.walkingImpaired();
    final r = await _guard(() => _client.route.post<Map<String, dynamic>>('/api/route', data: {
          'origin': {'lat': o.latitude, 'lon': o.longitude},
          'destination': {'lat': facility.position.latitude, 'lon': facility.position.longitude},
          // 위험 영역 회피는 항상 켜짐. 안전 경로 = 사용자 유형(노약자면 급경사 회피), 가까운 경로 = 경사 무시 최단
          'profile': routeType == RouteType.safest ? routeProfileFor(age, transport, walkingImpaired: walking) : 'adult',
        }), notFound: '이 시설까지 걸어서 갈 수 있는 길을 찾지 못했습니다.');
    return routeFromJson(r.data!, facility.id, routeType, names: await _routeHazardNames());
  }

  /// 경로 서버의 위험 구역 id → 이름 (응답의 avoided·still_inside는 id). 한 번만 받아 둔다
  Future<Map<String, String>> _routeHazardNames() async {
    if (_hazardNames != null) return _hazardNames!;
    try {
      final r = await _client.route.get<Map<String, dynamic>>('/api/route/hazards');
      return _hazardNames = {
        for (final f in (r.data!['features'] as List).cast<Map<String, dynamic>>())
          '${f['properties']['id']}': '${f['properties']['name']}'
      };
    } on DioException {
      return const {};
    }
  }

  @override
  Future<ChatAnswer> ask(String question, UserMode userMode, LatLng o) async {
    final uid = await _account.deviceUserId();
    final (age, transport) = await _account.requiredSetup();
    final walking = await _account.walkingImpaired();
    final places = await _account.places();
    try {
      final r = await _guard(() => _client.ai.post<Map<String, dynamic>>('/api/chat', data: {
            'user_id': uid,
            'question': question,
            if (_conversationId != null) 'conversation_id': _conversationId,
            'current_location': {'lat': o.latitude, 'lon': o.longitude, 'label': '현재 위치'},
            'profile': {
              'user_id': uid,
              'user_type': userMode == UserMode.resident ? 'resident' : 'tourist',
              if (age != null) 'age': age,
              'mobility': transport == '휠체어' ? 'wheelchair' : 'walk',
              if (walking) 'walking_impaired': true,
              ...placesForProfile(places),
            },
          }));
      _conversationId = r.data!['conversation_id'] as String?;
      return chatAnswerFromJson(r.data!, names: await _routeHazardNames());
    } on RemoteError catch (e) {
      return ChatAnswer(e.message);
    }
  }

  Future<Response<T>> _guard<T>(Future<Response<T>> Function() call, {String? notFound}) async {
    try {
      return await call();
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404 && notFound != null) throw RemoteError(notFound);
      if (e.type == DioExceptionType.receiveTimeout) throw const RemoteError('서버 응답이 늦습니다. 잠시 후 다시 시도해 주세요.');
      if (status == null) throw const RemoteError('서버에 연결하지 못했습니다. 인터넷 연결을 확인해 주세요.');
      throw RemoteError('서버 오류가 발생했습니다 ($status). 잠시 후 다시 시도해 주세요.');
    }
  }
}

/// 화면에 그대로 보여 줄 수 있는 오류 문구
class RemoteError implements Exception {
  const RemoteError(this.message);
  final String message;
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// 서버 응답 → 화면 모델 (테스트에서 실제 응답 모양으로 검사)

const _levelKo = {'normal': '정상', 'watch': '관심', 'advisory': '주의', 'warning': '경계', 'critical': '심각'};
String levelKo(String? level) => _levelKo[level] ?? '정상';

String guideFor(String levelKorean) => switch (levelKorean) {
      '심각' || '경계' => '즉시 안전한 실내나 지정 대피소로 이동하고, 물이 고인 도로·해안가·맨홀 주변에 접근하지 마세요.',
      '주의' => '저지대와 해안가 접근을 자제하고 기상 정보를 계속 확인하세요.',
      _ => '현재 발효 중인 위험은 없습니다. 기상 변화를 계속 확인하세요.',
    };

/// ISO 시각 문자열에서 서버 기준(KST) "HH:mm"만 뽑는다
String _hhmm(Object? iso) {
  final s = iso as String? ?? '';
  return s.length >= 16 ? s.substring(11, 16) : '-';
}

RiskStatus riskFromJson(Map<String, dynamic> j) {
  final items = (j['items'] as List? ?? const []).cast<Map<String, dynamic>>();
  final level = levelKo(j['max_level'] as String?);
  final stale = j['data_stale'] == true;
  final String title, summary;
  if (items.isEmpty) {
    title = '현재 위험 없음';
    summary = stale
        ? '위험 판정 정보가 지연되고 있습니다. 공식 재난 안내를 함께 확인하세요.'
        : '주변 ${RemoteSafetyRepository.riskRadiusM}m 안에 발효 중인 위험이 없습니다.';
  } else {
    title = items.take(2).map((i) => i['label']).join(' · ');
    summary = (items.first['reason'] as String?) ?? items.first['label'] as String;
  }
  return RiskStatus(
    level: level,
    title: title,
    summary: summary,
    updatedAt: _hhmm(j['computed_at']),
    guide: guideFor(level),
    details: [for (final i in items) i['reason'] == null ? '${i['label']}' : '${i['label']} — ${i['reason']}'],
    stale: stale,
  );
}

List<AlertItem> alertsFromRiskJson(Map<String, dynamic> j) {
  final items = (j['items'] as List? ?? const []).cast<Map<String, dynamic>>();
  return [
    for (final (n, i) in items.indexed)
      AlertItem(
        id: '${i['hazard']}-${i['area_id'] ?? n}',
        title: i['label'] as String,
        level: levelKo(i['level'] as String?),
        time: _hhmm(i['observed_at'] ?? j['computed_at']),
        summary: (i['reason'] as String?) ?? i['label'] as String,
        guide: guideFor(levelKo(i['level'] as String?)),
      ),
  ];
}

List<RiskArea> riskAreasFromGeoJson(Map<String, dynamic> fc) {
  List<LatLng> ring(List coords) => [for (final c in coords) LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())];
  return [
    for (final f in (fc['features'] as List).cast<Map<String, dynamic>>())
      if (f['geometry'] case {'type': final String type, 'coordinates': final List coords})
        RiskArea(
          level: levelKo(f['properties']?['level'] as String?),
          label: f['properties']?['label'] as String? ?? '',
          hazard: f['properties']?['hazard'] as String? ?? '',
          polygons: switch (type) {
            'Polygon' => [ring(coords.first as List)],
            'MultiPolygon' => [for (final p in coords) ring((p as List).first as List)],
            _ => const [],
          },
        ),
  ];
}

const _shelterKind = {'tsunami': '지진해일 대피장소', 'civil_defense': '민방위 대피시설', 'earthquake': '지진 옥외대피장소', 'shelter': '임시주거시설'};

List<Facility> facilitiesFromGeoJson(Map<String, dynamic> fc, FacilityType type, LatLng origin) {
  const distance = Distance();
  return [
    for (final f in (fc['features'] as List).cast<Map<String, dynamic>>())
      () {
        final p = f['properties'] as Map<String, dynamic>;
        final c = f['geometry']['coordinates'] as List;
        final pos = LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());
        final km = distance.as(LengthUnit.Meter, origin, pos) / 1000;
        final String description;
        if (type == FacilityType.shelter) {
          final kinds = (p['shelter_types'] as List? ?? const []).map((k) => _shelterKind[k] ?? '$k').join('·');
          description = [
            if (kinds.isNotEmpty) kinds,
            p['is_indoor'] == true ? '실내' : '실외',
            if (p['in_risk_area'] == true) '현재 위험 구역 안 — 다른 대피소를 우선 확인하세요',
          ].join(' · ');
        } else {
          description = (p['emergency_class'] as String?) ?? '의료시설';
        }
        return Facility(
          id: '${type == FacilityType.shelter ? 'shelter' : 'medical'}-${p['id'] ?? f['id']}',
          name: p['name'] as String,
          type: type,
          position: pos,
          address: (p['address'] as String?) ?? '주소 정보 없음',
          description: description,
          distanceKm: double.parse(km.toStringAsFixed(1)),
          // 직선거리 × 1.3 (길 굽이) ÷ 시속 4km — 경로를 계산하기 전 대략값
          walkMinutes: (km * 1.3 / 4 * 60).ceil(),
          accessible: p['is_accessible'] == true,
          open: p['in_risk_area'] != true,
          phone: (p['er_phone'] ?? p['phone']) as String?,
        );
      }(),
  ];
}

/// 65세 이상·휠체어·보행 불편이면 급경사를 피하는 노약자 경로 (AI tools.route_profile과 같은 기준)
String routeProfileFor(int? age, String? transport, {bool walkingImpaired = false}) =>
    (age != null && age >= 65) || transport == '휠체어' || walkingImpaired ? 'elderly' : 'adult';

/// 등록 장소 → AI 요청 profile (집 → home, 나머지 → frequent_places). AI가 "집까지", "직장까지"를 찾는다
Map<String, Object> placesForProfile(List<SavedPlace> places) {
  Map<String, Object> loc(SavedPlace p, String label) => {'lat': p.position.latitude, 'lon': p.position.longitude, 'label': label};
  final home = places.where((p) => p.type == '집').firstOrNull;
  final others = places.where((p) => p != home).map((p) => loc(p, p.type == '직장' ? '직장' : p.name)).toList();
  return {if (home != null) 'home': loc(home, '집'), if (others.isNotEmpty) 'frequent_places': others};
}

/// /api/chat 응답 → 답변 + (있으면) 지도에 그릴 경로
ChatAnswer chatAnswerFromJson(Map<String, dynamic> j, {Map<String, String> names = const {}}) {
  final r = j['route'] as Map<String, dynamic>?;
  if (r == null) return ChatAnswer(j['answer'] as String);
  final dest = r['destination'] as Map<String, dynamic>;
  return ChatAnswer(j['answer'] as String,
      route: routeFromJson(r, 'ai', RouteType.safest, names: names),
      destinationName: dest['name'] as String,
      destinationKind: dest['kind'] as String?,
      destinationPos: LatLng((dest['lat'] as num).toDouble(), (dest['lon'] as num).toDouble()));
}

SafetyRoute routeFromJson(Map<String, dynamic> j, String facilityId, RouteType routeType, {Map<String, String> names = const {}}) {
  final avoided = [for (final id in (j['avoided'] as List? ?? const []).cast<String>()) names[id] ?? id];
  final inside = [for (final id in (j['still_inside'] as List? ?? const []).cast<String>()) names[id] ?? id];
  final slope = (j['max_slope_pct'] as num?)?.toInt() ?? 0;
  final summary = [
    if (avoided.isNotEmpty) '위험 구역 ${avoided.length}곳을 피했습니다: ${avoided.join(', ')}',
    if (inside.isNotEmpty) '주의: 다른 길이 없어 지나는 위험 구역 — ${inside.join(', ')}',
    if (avoided.isEmpty && inside.isEmpty) '경로 위에 알려진 위험 구역이 없습니다.',
    if (j['profile'] == 'elderly') '급경사를 피한 노약자 경로 (최대 경사 $slope%)',
    if (j['hazards_ok'] == false) '주의: 위험 정보를 확인하지 못해 위험 영역 회피 없이 계산한 경로입니다',
  ].join('\n');
  return SafetyRoute(
    shelterId: facilityId,
    routeType: routeType,
    polylinePoints: decodePolyline(j['geometry'] as String),
    distanceMeters: (j['distance_m'] as num).toInt(),
    estimatedMinutes: ((j['duration_s'] as num) / 60).ceil(),
    riskAvoidanceSummary: summary,
    avoided: avoided,
    stillInside: inside,
  );
}
