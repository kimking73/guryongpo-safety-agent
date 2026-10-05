import 'dart:convert';
import 'dart:typed_data';
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
/// - ai(8001): /api/chat, 음성 /api/voice·/api/tts
/// - route(8002): /api/route
/// 알림은 /api/v1/alerts에서 실시간 수신하고, /api/route는 이동 경로를 계산한다.
class RemoteSafetyRepository implements SafetyRepository {
  RemoteSafetyRepository({ApiClient? client, AccountService? account, AuthService? auth})
      : _auth = auth ?? AuthService(),
        _account = account ?? AccountService(),
        _client = client ?? ApiClient(auth ?? AuthService());
  final AuthService _auth;
  final ApiClient _client;
  final AccountService _account;
  String? _conversationId;
  Map<String, String>? _hazardNames;

  /// 사용자 위치 주변 이 거리(m) 안의 위험 영역까지 위험도에 넣는다
  static const riskRadiusM = 300;

  Future<Map<String, dynamic>> _risk(LatLng o) async {
    final r = await _guard(() => _client.api
            .get<Map<String, dynamic>>('/api/v1/risk', queryParameters: {
          'lat': o.latitude,
          'lng': o.longitude,
          'radius_m': riskRadiusM
        }));
    return r.data!;
  }

  @override
  Future<RiskStatus> risk(LatLng origin) async =>
      riskFromJson(await _risk(origin));

  @override
  Future<List<AlertItem>> alerts(LatLng origin) async =>
      alertsFromRiskJson(await _risk(origin));

  @override
  Future<AlertPollResult> pollAlerts(
    LatLng origin, {
    String? since,
    String? deviceId,
  }) async {
    final r = await _guard(() => _client.api.get<Map<String, dynamic>>(
          '/api/v1/alerts',
          queryParameters: {
            if (since != null) 'since': since,
            if (deviceId != null) 'device_id': deviceId,
            'lat': origin.latitude,
            'lng': origin.longitude,
          },
        ));
    return alertPollResultFromJson(r.data!);
  }

  @override
  Future<RouteCheckResult> checkRoute({
    required LatLng current,
    required LatLng destination,
    required String geometry,
    required String profile,
    required String facilityId,
    required RouteType routeType,
  }) async {
    final r = await _guard(() => _client.route.post<Map<String, dynamic>>(
          '/api/route/check',
          data: {
            'current': {'lat': current.latitude, 'lon': current.longitude},
            'destination': {
              'lat': destination.latitude,
              'lon': destination.longitude,
            },
            'geometry': geometry,
            'profile': profile,
          },
        ));
    return routeCheckResultFromJson(
      r.data!,
      facilityId: facilityId,
      routeType: routeType,
      names: await _routeHazardNames(),
    );
  }

  @override
  Future<String?> registerDeviceToken(String token, String platform) async {
    final r = await _guard(() => _client.api.post<Map<String, dynamic>>(
          '/api/v1/device-token',
          data: {'token': token, 'platform': platform},
        ));
    return r.data?['device_id'] as String?;
  }

  @override
  Future<void> unregisterDeviceToken(String token) async {
    await _guard(() => _client.api.delete<void>(
          '/api/v1/device-token',
          queryParameters: {'token': token},
        ));
  }

  @override
  Future<void> markAlertRead(String alertId) async {
    await _guard(() => _client.api.post<void>(
          '/api/v1/alerts/$alertId/read',
        ));
  }

  @override
  Future<void> respondToAlert({
    required String alertId,
    required String status,
    required LatLng location,
  }) async {
    await _client.api.post<void>(
      '/api/v1/alerts/$alertId/response',
      data: {
        'status': status,
        'via': 'button',
        'location': {'lat': location.latitude, 'lng': location.longitude},
      },
    );
  }

  @override
  Future<List<RiskArea>> riskAreas() async {
    final r = await _guard(
        () => _client.api.get<Map<String, dynamic>>('/api/v1/risk/areas'));
    return riskAreasFromGeoJson(r.data!);
  }

  @override
  Future<List<FloodGrid>> floodGrid({int timeIndex = 0}) async {
    final r = await _guard(() => _client.api
        .get<Map<String, dynamic>>('/api/v1/dashboard/layers/flood_grid'));
    return floodGridFromGeoJson(r.data!);
  }

  @override
  Future<List<Facility>> getFacilities(LatLng o) async {
    final shelters = await _guard(() => _client.api
        .get<Map<String, dynamic>>('/api/v1/dashboard/layers/shelters'));
    final medical = await _guard(() => _client.api
        .get<Map<String, dynamic>>('/api/v1/dashboard/layers/medical'));
    return [
      ...facilitiesFromGeoJson(shelters.data!, FacilityType.shelter, o),
      ...facilitiesFromGeoJson(medical.data!, FacilityType.medical, o),
    ]..sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
  }

  @override
  Future<SafetyRoute> routeFor(Facility facility, UserMode userMode,
      RouteType routeType, LatLng o) async {
    final (age, transport) = await _account.requiredSetup();
    final walking = await _account.walkingImpaired();
    final r = await _guard(
        () => _client.route.post<Map<String, dynamic>>('/api/route', data: {
              'origin': {'lat': o.latitude, 'lon': o.longitude},
              'destination': {
                'lat': facility.position.latitude,
                'lon': facility.position.longitude
              },
              // 두 전략 모두 활성 위험 영역은 회피한다. 가까운 경로는 시간 우선,
              // 안전 경로는 사용자 이동 조건(고령·휠체어·보행 불편)을 반영한다.
              'strategy': routeType == RouteType.nearest ? 'fastest' : 'safest',
              'profile': routeProfileFor(age, transport, walkingImpaired: walking),
            }),
        notFound: '이 시설까지 걸어서 갈 수 있는 길을 찾지 못했습니다.');
    return routeFromJson(r.data!, facility.id, routeType,
        names: await _routeHazardNames());
  }

  /// 경로 서버의 위험 구역 id → 이름 (응답의 avoided·still_inside는 id). 한 번만 받아 둔다
  Future<Map<String, String>> _routeHazardNames() async {
    if (_hazardNames != null) return _hazardNames!;
    try {
      final r =
          await _client.route.get<Map<String, dynamic>>('/api/route/hazards');
      return _hazardNames = {
        for (final f
            in (r.data!['features'] as List).cast<Map<String, dynamic>>())
          '${f['properties']['id']}': '${f['properties']['name']}'
      };
    } on DioException {
      return const {};
    }
  }

  /// /api/chat·/api/voice 공통 사용자 정보 (서버 ChatRequest.profile)
  Future<(String, Map<String, Object>)> _profile(UserMode userMode) async {
    // 로그인했으면 Firebase uid (AI 기억이 계정을 따라감), Firebase가 없으면 기기 ID
    final uid = _auth.uid ?? await _account.deviceUserId();
    final (age, transport) = await _account.requiredSetup();
    final walking = await _account.walkingImpaired();
    final places = await _account.places();
    return (uid, <String, Object>{
      'user_id': uid,
      // 사용자 유형 구분(주민·관광객)이 앱에서 빠져 서버 기본값(resident)을 쓴다
      if (age != null) 'age': age,
      'mobility': switch (transport) { '휠체어' => 'wheelchair', '자동차' => 'car', _ => 'walk' },
      if (walking) 'walking_impaired': true,
      ...placesForProfile(places),
    });
  }

  @override
  Future<ChatAnswer> ask(String question, UserMode userMode, LatLng o) async {
    final (uid, profile) = await _profile(userMode);
    try {
      final r = await _guard(() => _client.ai.post<Map<String, dynamic>>('/api/chat', data: {
            'user_id': uid,
            'question': question,
            if (_conversationId != null) 'conversation_id': _conversationId,
            'current_location': {'lat': o.latitude, 'lon': o.longitude, 'label': '현재 위치'},
            'profile': profile,
          }));
      _conversationId = r.data!['conversation_id'] as String?;
      return chatAnswerFromJson(r.data!, names: await _routeHazardNames());
    } on RemoteError catch (e) {
      return ChatAnswer(e.message, isError: true);
    }
  }

  /// 녹음(WAV) → ai /api/voice (multipart). 같은 대화(conversation_id)로 이어진다.
  /// 말을 못 알아들음(422)·음성 기능 없음(503)은 서버 문구를 그대로 RemoteError로
  @override
  Future<VoiceAnswer> askVoice(Uint8List wav, UserMode userMode, LatLng o) async {
    final (uid, profile) = await _profile(userMode);
    final form = FormData.fromMap({
      'audio': MultipartFile.fromBytes(wav, filename: 'question.wav', contentType: DioMediaType('audio', 'wav')),
      'user_id': uid,
      if (_conversationId != null) 'conversation_id': _conversationId,
      'lat': '${o.latitude}',
      'lon': '${o.longitude}',
      'profile': jsonEncode(profile),
    });
    final r = await _guard(() => _client.ai.post<Map<String, dynamic>>('/api/voice', data: form), passDetail: const {422, 503});
    _conversationId = r.data!['conversation_id'] as String?;
    return VoiceAnswer(r.data!['transcript'] as String, chatAnswerFromJson(r.data!, names: await _routeHazardNames()));
  }

  @override
  Future<Uint8List?> speak(String text) async {
    try {
      final r = await _client.ai.post<List<int>>('/api/tts',
          data: {'text': text}, options: Options(responseType: ResponseType.bytes));
      return Uint8List.fromList(r.data!);
    } on DioException {
      return null; // 키 없음(503)·서버 꺼짐 → 버튼이 "쓸 수 없음"을 알린다
    }
  }

  /// passDetail: 이 상태 코드면 서버가 보낸 문구(FastAPI detail)를 그대로 보여 준다
  Future<Response<T>> _guard<T>(Future<Response<T>> Function() call,
      {String? notFound, Set<int> passDetail = const {}}) async {
    try {
      return await call();
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404 && notFound != null) throw RemoteError(notFound);
      final body = e.response?.data;
      if (passDetail.contains(status) && body is Map && body['detail'] is String) throw RemoteError(body['detail'] as String);
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

const _levelKo = {
  'normal': '정상',
  'watch': '관심',
  'advisory': '주의',
  'warning': '경계',
  'critical': '심각'
};
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
    summary =
        (items.first['reason'] as String?) ?? items.first['label'] as String;
  }
  return RiskStatus(
    level: level,
    title: title,
    summary: summary,
    updatedAt: _hhmm(j['computed_at']),
    guide: guideFor(level),
    details: [
      for (final i in items)
        i['reason'] == null ? '${i['label']}' : '${i['label']} — ${i['reason']}'
    ],
    stale: stale,
  );
}

List<FloodGrid> floodGridFromGeoJson(Map<String, dynamic> fc) {
  final result = <FloodGrid>[];
  for (final f
      in (fc['features'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    final geometry = f['geometry'] as Map<String, dynamic>?;
    final properties = f['properties'] as Map<String, dynamic>? ?? const {};
    // 서버는 칸을 침수 영역 모양대로 잘라 보낸다 (Polygon 또는 MultiPolygon, 바깥 고리만 사용)
    final polys = switch (geometry?['type']) {
      'Polygon' => [geometry!['coordinates'] as List],
      'MultiPolygon' => [for (final p in geometry!['coordinates'] as List) p as List],
      _ => const <List>[],
    };
    if (polys.isEmpty) continue;
    final rings = [
      for (final poly in polys)
        [for (final p in (poly.first as List).cast<List>()) LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble())]
    ];
    final points = [for (final r in rings) for (final p in r) [p.longitude, p.latitude]];
    final lngs = points.map((p) => p[0]).toList(),
        lats = points.map((p) => p[1]).toList();
    result.add(FloodGrid(
      id: '${f['id'] ?? 'flood-cell'}',
      level: switch ('${properties['level']}') {
        'critical' || '심각' => '심각',
        'warning' || '경계' => '경계',
        'advisory' || 'watch' || '주의' => '주의',
        _ => '미확인',
      },
      south: lats.reduce((a, b) => a < b ? a : b),
      north: lats.reduce((a, b) => a > b ? a : b),
      west: lngs.reduce((a, b) => a < b ? a : b),
      east: lngs.reduce((a, b) => a > b ? a : b),
      depthCm: (properties['observed_depth_cm'] as num?)?.toDouble(),
      observedAt: properties['observed_at'] as String?,
      source: properties['source'] as String? ?? '위험 판정 자료',
      isExample: properties['simulated'] == true,
      rings: rings,
    ));
  }
  return result;
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

AlertPollResult alertPollResultFromJson(Map<String, dynamic> json) {
  final alerts = (json['alerts'] as List? ?? const [])
      .cast<Map<String, dynamic>>()
      .map((item) {
    final risk = item['risk'] as Map<String, dynamic>? ?? const {};
    final level = levelKo(risk['level'] as String?);
    return AlertItem(
      id: '${item['id']}',
      title: item['title'] as String? ?? '재난 알림',
      level: level,
      time: _hhmm(item['created_at'] as String? ?? ''),
      summary: item['body'] as String? ?? '',
      guide: guideFor(level),
      read: item['read_at'] != null,
      responseRequired: item['response_required'] == true,
      myStatus: item['my_status'] as String?,
    );
  }).toList();
  return AlertPollResult(
    alerts: alerts,
    serverTime: DateTime.tryParse(json['server_time'] as String? ?? ''),
    nextPollSeconds: (json['next_poll_sec'] as num?)?.toInt() ?? 60,
    mode: json['mode'] as String? ?? 'normal',
    evacuation: json['evacuation'] as Map<String, dynamic>?,
  );
}

RouteCheckResult routeCheckResultFromJson(
  Map<String, dynamic> json, {
  required String facilityId,
  required RouteType routeType,
  Map<String, String> names = const {},
}) {
  final routeJson = json['route'] as Map<String, dynamic>?;
  return RouteCheckResult(
    reroute: json['reroute'] == true,
    reasons: (json['reasons'] as List? ?? const []).cast<String>(),
    offRouteMeters: (json['off_route_m'] as num?)?.toInt() ?? 0,
    hazardsAhead: (json['hazards_ahead'] as List? ?? const []).cast<String>(),
    arrived: json['arrived'] == true,
    route: routeJson == null
        ? null
        : routeFromJson(routeJson, facilityId, routeType, names: names),
  );
}

List<RiskArea> riskAreasFromGeoJson(Map<String, dynamic> fc) {
  List<LatLng> ring(List coords) => [
        for (final c in coords)
          LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())
      ];
  return [
    for (final f in (fc['features'] as List).cast<Map<String, dynamic>>())
      if (f['geometry']
          case {'type': final String type, 'coordinates': final List coords})
        RiskArea(
          level: levelKo(f['properties']?['level'] as String?),
          label: f['properties']?['label'] as String? ?? '',
          hazard: f['properties']?['hazard'] as String? ?? '',
          polygons: switch (type) {
            'Polygon' => [ring(coords.first as List)],
            'MultiPolygon' => [
                for (final p in coords) ring((p as List).first as List)
              ],
            _ => const [],
          },
        ),
  ];
}

const _shelterKind = {
  'tsunami': '지진해일 대피장소',
  'civil_defense': '민방위 대피시설',
  'earthquake': '지진 옥외대피장소',
  'shelter': '임시주거시설'
};

List<Facility> facilitiesFromGeoJson(
    Map<String, dynamic> fc, FacilityType type, LatLng origin) {
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
          final kinds = (p['shelter_types'] as List? ?? const [])
              .map((k) => _shelterKind[k] ?? '$k')
              .join('·');
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
String routeProfileFor(int? age, String? transport,
        {bool walkingImpaired = false}) =>
    deriveRouteProfile(age, transport, walkingImpaired: walkingImpaired);

/// 등록 장소 → AI 요청 profile (집 → home, 나머지 → frequent_places). AI가 "집까지", "직장까지"를 찾는다
Map<String, Object> placesForProfile(List<SavedPlace> places) {
  Map<String, Object> loc(SavedPlace p, String label) =>
      {'lat': p.position.latitude, 'lon': p.position.longitude, 'label': label};
  final home = places.where((p) => p.type == '집').firstOrNull;
  final others = places
      .where((p) => p != home)
      .map((p) => loc(p, p.type == '직장' ? '직장' : p.name))
      .toList();
  return {
    if (home != null) 'home': loc(home, '집'),
    if (others.isNotEmpty) 'frequent_places': others
  };
}

/// /api/chat 응답 → 답변 + (있으면) 지도에 그릴 경로
ChatAnswer chatAnswerFromJson(Map<String, dynamic> j,
    {Map<String, String> names = const {}}) {
  final r = j['route'] as Map<String, dynamic>?;
  final voiceText = j['voice_text'] as String?;
  final b64 = j['audio_b64'] as String?;
  final audio = b64 == null ? null : base64Decode(b64);
  if (r == null) return ChatAnswer(j['answer'] as String, voiceText: voiceText, audio: audio);
  final dest = r['destination'] as Map<String, dynamic>;
  return ChatAnswer(j['answer'] as String,
      voiceText: voiceText,
      audio: audio,
      route: routeFromJson(r, 'ai', RouteType.safest, names: names),
      destinationName: dest['name'] as String,
      destinationKind: dest['kind'] as String?,
      destinationPos: LatLng(
          (dest['lat'] as num).toDouble(), (dest['lon'] as num).toDouble()));
}

SafetyRoute routeFromJson(
    Map<String, dynamic> j, String facilityId, RouteType routeType,
    {Map<String, String> names = const {}}) {
  final avoided = [
    for (final id in (j['avoided'] as List? ?? const []).cast<String>())
      names[id] ?? id
  ];
  final inside = [
    for (final id in (j['still_inside'] as List? ?? const []).cast<String>())
      names[id] ?? id
  ];
  final slope = (j['max_slope_pct'] as num?)?.toInt() ?? 0;
  final summary = [
    if (avoided.isNotEmpty)
      '위험 구역 ${avoided.length}곳을 피했습니다: ${avoided.join(', ')}',
    if (inside.isNotEmpty) '주의: 다른 길이 없어 지나는 위험 구역 — ${inside.join(', ')}',
    if (avoided.isEmpty && inside.isEmpty) '경로 위에 알려진 위험 구역이 없습니다.',
    if (j['profile'] == 'elderly') '노약자 프로필: 급경사·계단 부담을 줄이는 경로 (최대 경사 $slope%)',
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
    profile: j['profile'] as String? ?? 'adult',
    maxSlopePercent: slope,
    hazardsOk: j['hazards_ok'] != false,
    encodedGeometry: j['geometry'] as String,
  );
}
