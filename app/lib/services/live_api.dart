import 'package:dio/dio.dart';
import 'api_client.dart';
import 'auth_service.dart';
import 'demo_mode.dart';

/// 실측 화면용 서버 호출 (2026-10-05). 응답은 명세(server/spec/openapi.yaml) 그대로 Map으로 쓴다.
class LiveApi {
  LiveApi({Dio? api, Dio? route}) {
    final client = api == null || route == null ? ApiClient(AuthService()) : null;
    _api = api ?? client!.api;
    _route = route ?? client!.route;
  }
  late final Dio _api, _route;

  Future<Map<String, dynamic>> _send(Future<Response<Map<String, dynamic>>> call) async =>
      Map<String, dynamic>.from((await call).data ?? const {});

  Future<Map<String, dynamic>> _get(String path, [Map<String, dynamic>? q]) async =>
      Map<String, dynamic>.from((await _api.get<Map<String, dynamic>>(path, queryParameters: q)).data ?? const {});

  Future<List<Map<String, dynamic>>> _list(String path, [Map<String, dynamic>? q]) async =>
      [for (final x in (await _api.get<List<dynamic>>(path, queryParameters: q)).data ?? const []) Map<String, dynamic>.from(x as Map)];

  /// 맞춤 대시보드: 위험도·특보·강수·바람·수위·파고·태풍·예보·재난문자·자외선/미세먼지·장소별 위험·가까운 대피소
  Future<Map<String, dynamic>> dashboard(double lat, double lng) =>
      _get(DemoData.path('/api/v1/dashboard', '/api/v1/demo/dashboard'), {'lat': lat, 'lng': lng});

  /// 관측소 + 최신값 GeoJSON (바람 화살표·센서 표시)
  Future<Map<String, dynamic>> stationsLayer() =>
      _get(DemoData.path('/api/v1/dashboard/layers/stations', '/api/v1/demo/layers/stations'));

  Future<List<Map<String, dynamic>>> supportPrograms({String? hazard}) =>
      _list('/api/v1/support-programs', {if (hazard != null) 'hazard': hazard});

  Future<List<Map<String, dynamic>>> hotlines({String? hazard}) =>
      _list('/api/v1/hotlines', {if (hazard != null) 'hazard': hazard});

  // ---- 방재단 (역할 필요: 초대 코드로 받음) ----
  /// 방재단 업무 단계(가는 중·방문 중·대피 동행·완료)를 서버에 저장할 수 있는지.
  /// 2026-10-09: 서버(incident_targets)에 업무 단계 칸이 아직 없어 false — 배정(assigned_to)만 저장된다. 시연은 true
  bool get supportsWorkStatus => false;
  Future<Map<String, dynamic>> me() => _get('/api/v1/user');
  Future<Map<String, dynamic>> claimRole(String code) async => Map<String, dynamic>.from(
      (await _api.post<Map<String, dynamic>>('/api/v1/user/role', data: {'invite_code': code.trim()})).data ?? const {});
  Future<void> dropRole() => _api.delete<Object?>('/api/v1/user/role');
  Future<Map<String, dynamic>> adminOverview() => _get('/api/v1/admin/overview');
  Future<List<Map<String, dynamic>>> adminHouseholds() => _list('/api/v1/admin/households');
  Future<List<Map<String, dynamic>>> adminIncidents() => _list('/api/v1/admin/incidents');
  /// 시연용 가상 가구 (서버 DB의 '[시연] …', 역할 없이 조회) — 시연 모드 방재단 화면
  Future<List<Map<String, dynamic>>> demoHouseholds() => _list('/api/v1/demo/households');

  // ---- 시연 대피 응답 (2026-10-12): 서버에 저장해 다른 계정의 방재단원 모드와 주고받는다 (server app/demo_evac.py) ----
  // needs = '내 정보'의 장애 유형 (vision · hearing · mobility_limited). 주소·전화·실제 위치는 보내지 않는다
  /// 새 시연 경보 시작 — 내 응답을 '응답 없음'으로, 지난 출동 기록은 지운다
  /// [lat]·[lng] = 주민의 현재 위치 (GPS·지도에서 고른 곳, 2026-10-12) — 없으면 방재단 화면엔 가상 위치
  Future<Map<String, dynamic>> demoEvacStart(List<String> needs, {double? lat, double? lng}) =>
      _send(_api.post<Map<String, dynamic>>('/api/v1/demo/evacuation/start',
          data: {'needs': needs, if (lat != null && lng != null) 'location': {'lat': lat, 'lng': lng}}));

  /// 시연 응답 저장 (status: evacuated|evacuating|need_help, via: button|voice|dashboard|alarm)
  Future<Map<String, dynamic>> demoEvacRespond(String status, List<String> needs,
          {String via = 'button', double? lat, double? lng}) =>
      _send(_api.post<Map<String, dynamic>>('/api/v1/demo/evacuation/response', data: {
        'status': status,
        'needs': needs,
        'via': via,
        if (lat != null && lng != null) 'location': {'lat': lat, 'lng': lng},
      }));

  /// 서버의 시연 주민 응답 전부 초기화 (시연 모드를 껐다 켤 때, 모든 계정 — 이력은 서버에 남는다)
  Future<void> demoEvacReset() => _api.delete<Object?>('/api/v1/demo/evacuation');

  /// 시연 주민이 움직이면 현재 위치만 갱신 (이력 없음)
  Future<void> demoEvacLocation(double lat, double lng) =>
      _api.post<Object?>('/api/v1/demo/evacuation/location', data: {'location': {'lat': lat, 'lng': lng}});

  /// 내 시연 응답 + 방재단 출동 기록(dispatch). 진행 중인 시연이 없으면 null
  Future<Map<String, dynamic>?> demoEvacMine() async {
    final d = (await _api.get<Object?>('/api/v1/demo/evacuation/me')).data;
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  /// 최근 시연 응답 전체 (다른 계정 포함, is_me 로 내 것 구분) — 방재단원 모드 화면
  Future<List<Map<String, dynamic>>> demoEvacResponses() => _list('/api/v1/demo/evacuation/responses');

  /// 방재단 출동 기록을 그 주민에게 (departed_at·eta·responder·stage), null 이면 지운다
  Future<void> demoEvacDispatch(String targetId, Map<String, dynamic>? dispatch) async {
    final path = '/api/v1/demo/evacuation/${Uri.encodeComponent(targetId)}/dispatch';
    if (dispatch == null) {
      await _api.delete<Object?>(path);
    } else {
      await _api.put<Object?>(path, data: dispatch);
    }
  }

  /// 대피 상황 상세: 대상 가구(targets: priority_rank·priority_reasons·status·last_visit), 영역(area), next_poll_sec.
  /// [lat]·[lng] = 방재단원 위치 (B13: 같은 순위 안에서 가까운 순, 없으면 오래 기다린 순)
  Future<Map<String, dynamic>> incident(String id, {double? lat, double? lng}) =>
      _get('/api/v1/admin/incidents/$id', lat != null && lng != null ? {'lat': lat, 'lng': lng} : null);

  /// 대상 상태·담당 바꾸기 (assigned_to: "me" | null, status: evacuated|evacuating|need_help)
  Future<Map<String, dynamic>> patchTarget(String incidentId, String targetId, Map<String, dynamic> body) =>
      _send(_api.patch<Map<String, dynamic>>('/api/v1/admin/incidents/$incidentId/targets/$targetId', data: body));

  /// '내 방문 경로' [출발] (2026-10-12): 경로의 집들을 내가 맡는다. 실제 서버엔 업무 단계·도착 예정 칸이 없어 배정만 —
  /// 도착 예정 시각을 시민에게 보내는 것은 시연(DemoLiveApi)만
  Future<void> dispatch(String incidentId, List<(String targetId, DateTime eta)> stops) async {
    for (final (id, _) in stops) {
      await patchTarget(incidentId, id, {'assigned_to': 'me', if (supportsWorkStatus) 'work_status': 'en_route'});
    }
  }

  /// 방문 결과 기록 (result: evacuated_with_help|already_evacuated|transported|refused|not_home|other, note?)
  Future<Map<String, dynamic>> recordVisit(String incidentId, String targetId, Map<String, dynamic> body) =>
      _send(_api.post<Map<String, dynamic>>('/api/v1/admin/incidents/$incidentId/targets/$targetId/visits', data: body));

  /// 방재단 대리 등록 (consent_method: written|verbal, consent_by 필수)
  Future<Map<String, dynamic>> createHousehold(Map<String, dynamic> body) =>
      _send(_api.post<Map<String, dynamic>>('/api/v1/admin/households', data: body));

  // ---- 해상 → 최근접 항 → 육상 경로 (B11, route 서버, 좌표 키 lat·lon) ----
  /// [toLat]·[toLon] = 도착 (2026-10-11, 경로 안내 '도착:'에서 고른 곳). 없으면 항구에서 가장 가까운 갈 만한 대피소
  Future<Map<String, dynamic>> seaRoute(double lat, double lon, {String profile = 'adult', double? toLat, double? toLon}) =>
      _send(_route.post<Map<String, dynamic>>('/api/route/sea', data: {
        'origin': {'lat': lat, 'lon': lon},
        if (toLat != null && toLon != null) 'destination': {'lat': toLat, 'lon': toLon},
        'profile': profile,
        if (DemoData.on) 'demo': true,
      }));

  /// 지금 위치가 바다 위인지 (2026-10-09, 경로 안내 메뉴). 경로 서버 육지 지도로 판별 — 범위 밖은 422(오류로 던짐).
  /// 판별 창구가 아직 없는 서버(404·405)면 해상 경로 응답의 at_sea 로 대신한다
  Future<bool> seaCheck(double lat, double lon) async {
    try {
      final r = await _route.post<Map<String, dynamic>>('/api/route/sea/check', data: {
        'origin': {'lat': lat, 'lon': lon},
      });
      return r.data?['at_sea'] == true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code != 404 && code != 405) rethrow;
      return (await seaRoute(lat, lon))['at_sea'] == true;
    }
  }

  // ---- 방재단 다중 방문 경로 (2026-10-09, route 서버 /api/route/visits) ----
  /// 출발점 → 고른 집 1~10곳. 응답 shortest·priority 두 경로 (order[id·seq·tier·leg_distance_m·leg_duration_s], distance_m,
  /// duration_s, geometry, still_inside), blocked_zones. stops = [{id, lat, lon, tier}] (이름 등 개인정보는 보내지 않는다)
  Future<Map<String, dynamic>> visitRoute(double lat, double lon, List<Map<String, dynamic>> stops, {String mode = 'walk'}) =>
      _send(_route.post<Map<String, dynamic>>('/api/route/visits', data: {
        'origin': {'lat': lat, 'lon': lon},
        'stops': stops,
        'mode': mode,
        if (DemoData.on) 'demo': true,
      }));

  // ---- 내 취약 가구 등록 (동의 필수) ----
  Future<Map<String, dynamic>?> myHousehold() async {
    try {
      return await _get('/api/v1/user/household');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<Map<String, dynamic>> saveHousehold(Map<String, dynamic> body) =>
      _send(_api.put<Map<String, dynamic>>('/api/v1/user/household', data: body));
  Future<void> deleteHousehold() => _api.delete<Object?>('/api/v1/user/household');
}

/// 서버 오류 → 한국어 한 줄
String liveError(Object e) {
  if (e is DioException) {
    final code = e.response?.statusCode;
    final data = e.response?.data;
    // api 서버: {code, message, detail} / route 서버(FastAPI): {detail: "문장"}
    final msg = data is Map ? (data['message'] ?? (data['detail'] is String ? data['detail'] : null)) as String? : null;
    if (msg != null && msg.isNotEmpty) return msg;
    if (code == 401) return '로그인 정보를 확인하지 못했습니다. 앱을 다시 열어 주세요.';
    if (code == 403) return '권한이 없습니다.';
    if (code == null) return '서버에 연결하지 못했습니다. 인터넷 연결을 확인해 주세요.';
    return '서버 오류 ($code)';
  }
  return '$e';
}
