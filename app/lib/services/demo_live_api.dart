import 'dart:math' as math;

import '../profile_form.dart' show disabilitiesOf;
import 'account_service.dart';
import 'live_api.dart';
import 'demo_mode.dart';
import 'prototype_safety_store.dart' show DemoDispatch, PrototypeSafetyController, demoProfileNeeds;

/// 시연 모드용 방재단 데이터 (2026-10-05). 시연 모드에서 방재단 화면(patrol_screens.dart, C8)이 [LiveApi] 대신 이 클래스를 쓴다.
/// 가구 목록: 앱 안 6곳 (시각·청각·지체 예시). 예전엔 서버 DB의 시연 가구(GET /api/v1/demo/households)를
/// 먼저 썼지만 장애 유형이 대리 등록(시각·청각·지체)과 달라 뺐다 (2026-10-11). 이름·주소·전화는 모두 가상이다.
/// 대피 상황 (2026-10-09): 앱 안 예시 대피 상황 하나 — 가구별 응답·배정·업무 단계는 이 앱 메모리에만 있고 서버로 보내지 않는다
/// (실제 응답·배정 데이터와 분리). '대피 경보 팝업' 시연 경보가 진행 중이면 '앱 사용자 (시연 주민)'이 대상에 들어가고
/// 상태 = 팝업에서 고른 시연 응답.
class DemoLiveApi extends LiveApi {
  DemoLiveApi();

  /// 앱 안 시연 가구 6곳 (2026-10-10 사용자 요청: 시연 데이터를 줄이고 이름의 '[시연]' 표시는 뗀다 — 독거노인 분류도 서비스 대상 아님).
  /// 장애 유형은 시각·청각·지체만 (2026-10-11 사용자 요청 — 가구 대리 등록이 묻는 유형과 같게. 지체 = mobility_limited).
  /// 앞 4곳은 구룡포항 둘레 대피 경보 지역 안 (우선 확인 가구에 나온다).
  /// 위치는 '최단 방문 경로'와 '우선순위 방문 경로'가 지도에서 다른 길로 그려지도록 골랐다 (2026-10-12 사용자 요청):
  /// 한 줄로 늘어서면 순서만 바뀌고 같은 길을 오가서 선이 똑같아 보인다 → 돌아가는 길이 여럿인 읍 남쪽에 네 곳을 벌려 놓았다.
  /// 로컬 경로 서버 측정(시연 모드, 도보, 기본 위치 출발): 최단 3→1→2→4 4359m / 우선순위 1→2→4→3 6160m,
  /// 서로 겹치지 않는 길 약 0.9km·1.5km (환승센터·읍사무소 쪽에서 출발해도 비슷). 좌표를 바꾸면 다시 잴 것
  static final _households = <Map<String, dynamic>>[
    _h(1, '구룡포리 지체장애 어르신 댁', '구룡포읍 구룡포리 (가상 주소)', 35.98018, 129.54999, 2, ['elderly', 'mobility_limited'],
        note: '대문 옆 초인종 고장 — 문을 두드려 주세요'),
    _h(2, '병포리 지체장애 주민 댁', '구룡포읍 병포리 (가상 주소)', 35.98348, 129.54421, 3, ['mobility_limited'],
        note: '휠체어 사용 · 경사로 없음, 2인 이동 필요'),
    _h(3, '구룡포리 청각장애 주민 댁', '구룡포읍 구룡포리 (가상 주소)', 35.98234, 129.55589, 1, ['hearing'],
        note: '청각 — 문자보다 방문 확인 우선'),
    _h(4, '병포리 시각장애 어르신 댁', '구룡포읍 병포리 (가상 주소)', 35.98571, 129.54111, 2, ['elderly', 'vision'],
        caregiver: '생활지원사 (가상)', landslide: '산사태 취약지역 (구평리 산172임) 60m'),
    _h(5, '하정리 청각장애 어르신 댁', '구룡포읍 하정리 (가상 주소)', 35.9928, 129.5602, 2, ['elderly', 'hearing'],
        note: '보청기 사용 — 문을 크게 두드려 주세요'),
    _h(6, '석병리 해안 시각장애 주민 댁', '구룡포읍 석병리 (가상 주소)', 35.9649, 129.5684, 1, ['vision'],
        landslide: '산사태 취약지역 (병포리 산1-2임) 40m', hasApp: true, source: 'self'),
  ];
  /// 서버 시연 가구를 쓸 때도 이만큼만 보여 준다
  static const maxDemoHouseholds = 6;
  static var _seq = 100;

  static Map<String, dynamic> _h(int n, String label, String address, double lat, double lng, int members, List<String> needs,
          {String? note, String? caregiver, String? landslide, bool hasApp = false, String source = 'responder'}) =>
      {
        'id': 'demo-household-${n.toString().padLeft(2, '0')}',
        'label': label,
        'address': address,
        'location': {'lat': lat, 'lng': lng},
        'phone': '010-0000-${(1000 + n).toString()}',
        'members': members,
        'needs': needs,
        'has_app': hasApp,
        'caregiver': caregiver == null ? null : {'user_id': null, 'nickname': caregiver},
        'source': source,
        'consent': {
          'at': '2026-10-01T09:00:00+09:00',
          'method': source == 'self' ? 'app' : 'verbal',
          'by': '시연용 가상 데이터',
          'version': 'v1',
        },
        'landslide_zone': landslide,
        'note': note,
        'updated_at': '2026-10-01T09:00:00+09:00',
        'active': true,
      };

  /// 시연 모드에서는 늘 방재단 역할 (초대 코드 없이 화면 확인)
  @override
  Future<Map<String, dynamic>> me() async => {'role': 'responder', 'is_anonymous': true, 'profile': const {}, 'places': const []};

  // ------------------------------------------------------------------ 시연 대피 상황
  static const incidentId = 'demo-incident';
  static final _started = DateTime.now().subtract(const Duration(minutes: 18));
  /// 시연 경보(대피 경보 팝업)가 진행 중인지·내 시연 응답 — DemoPatrolScope 가 기기 시연 기록에서 넣는다
  static bool myAlertActive = false;
  static String? myResponse;
  /// 시연 방(다른 계정, demo_relay.dart)에서 받은 시연 주민 장애 유형. null 이면 이 기기의 '내 정보'
  static List<String>? remoteNeeds;
  static const meTargetId = 'demo-me';
  /// 프로필 장애 유형 → 가구 needs (대리 등록과 같은 이름)
  static const _profileNeeds = demoProfileNeeds;

  /// 서버에 저장된 시연 주민 응답 (2026-10-12 사용자 요청: 다른 계정의 사용자 모드 응답을 이 방재단원 화면에).
  /// 서버 연결 + 시연 모드일 때만 읽고, 아니면 null → 예전처럼 이 기기의 시연 기록만. 테스트가 바꿔 끼운다
  static Future<List<Map<String, dynamic>>?> Function(DemoLiveApi api) readServerResponses =
      (api) async => DemoData.on ? api.demoEvacResponses() : null;

  /// 서버 시연 주민에게 출동 기록 보내기 (null = 지우기). 테스트가 바꿔 끼운다
  static Future<void> Function(DemoLiveApi api, String targetId, Map<String, dynamic>? dispatch) writeServerDispatch =
      (api, id, d) => api.demoEvacDispatch(id, d);

  /// 마지막으로 읽은 서버 시연 주민 (대상 id → 서버 행) — 출동 기록을 보낼 곳·지금 기록을 안다
  static final _server = <String, Map<String, dynamic>>{};
  /// 가구별 시연 상태 (응답·담당·업무 단계·마지막 방문). 처음 보는 가구는 아래 순서표로 채운다
  static final _state = <String, Map<String, dynamic>>{};
  /// 앞 4곳(대피 경보 지역 안): 1·2번 도움 요청, 3·4번 응답 없음 — 출발점에서 가장 가까운 3번(동쪽)이 응답 없음이라
  /// 최단 순서(3번부터)와 우선순위 순서(1·2번부터)가 갈린다. 가구 위치 설명은 위 _households 참고
  static const _pattern = <(String, String?, String?)>[
    ('need_help', '방재단원 A (예시)', 'en_route'),
    ('need_help', null, null),
    ('no_response', null, null),
    ('no_response', '방재단원 B (예시)', 'visiting'),
    ('evacuating', '방재단원 C (예시)', 'escorting'),
    ('evacuated', '방재단원 A (예시)', 'done'),
    ('no_response', null, null),
    ('need_help', '방재단원 B (예시)', 'en_route'),
    ('evacuating', null, null),
    ('evacuated', null, null),
    ('no_response', '방재단원 C (예시)', 'en_route'),
    ('evacuated', '방재단원 A (예시)', 'escorting'),
  ];
  /// 시연 대피 경보 지역: 구룡포항 둘레 반경 1.4km 원
  static const _center = (35.9870, 129.5525);
  static const _radiusM = 1400.0;

  static double _distM(double lat, double lng) {
    const r = 6371000.0;
    final dLat = (lat - _center.$1) * math.pi / 180, dLng = (lng - _center.$2) * math.pi / 180;
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_center.$1 * math.pi / 180) * math.cos(lat * math.pi / 180) * math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.sqrt(a));
  }

  static Map<String, dynamic> _area() {
    final ring = <List<double>>[];
    for (var i = 0; i <= 32; i++) {
      final th = 2 * math.pi * i / 32;
      ring.add([
        _center.$2 + _radiusM * math.sin(th) / (111320 * math.cos(_center.$1 * math.pi / 180)),
        _center.$1 + _radiusM * math.cos(th) / 111320,
      ]);
    }
    return {'type': 'Polygon', 'coordinates': [ring]};
  }

  static Map<String, dynamic> _stateFor(String id, int index) => _state.putIfAbsent(id, () {
        final p = _pattern[index % _pattern.length];
        return {
          'status': p.$1,
          'assigned': p.$2 == null ? null : {'user_id': null, 'nickname': p.$2, 'is_me': false},
          'work': p.$3,
          'visit': null,
        };
      });

  Future<List<Map<String, dynamic>>> _demoTargets() async {
    final hh = await adminHouseholds();
    final mins = DateTime.now().difference(_started).inMinutes;
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < hh.length; i++) {
      final h = hh[i];
      final loc = h['location'] as Map?;
      final lat = (loc?['lat'] as num?)?.toDouble(), lng = (loc?['lng'] as num?)?.toDouble();
      final st = _stateFor('${h['id']}', i);
      out.add({
        'id': 'demo-target-${h['id']}',
        'kind': 'household',
        'household_id': h['id'],
        'label': h['label'],
        'address': h['address'],
        'location': loc,
        'phone': h['phone'],
        'needs': h['needs'] ?? const [],
        'has_app': h['has_app'] == true,
        'status': st['status'],
        'minutes_since_alert': mins,
        'reminder_count': 0,
        'escalated': false,
        'assigned_to': st['assigned'],
        'work_status': st['work'],
        'last_visit': st['visit'],
        'eta': st['eta'],
        'in_area': lat == null || lng == null || _distM(lat, lng) <= _radiusM,
      });
    }
    // 서버의 시연 주민들 (다른 계정·기기 포함). 못 읽으면 이 기기 기록만으로 (같은 브라우저 시연은 그대로)
    List<Map<String, dynamic>>? server;
    try {
      server = await readServerResponses(this);
    } catch (_) {
      server = null;
    }
    _server
      ..clear()
      ..addAll({for (final r in server ?? const <Map<String, dynamic>>[]) '${r['id']}': r});
    for (final r in server ?? const <Map<String, dynamic>>[]) {
      final id = '${r['id']}';
      final st = _stateFor(id, 1);
      // 주민이 새 시연 경보를 시작했으면 지난 배정·단계·방문은 지운다
      if (st['started'] != r['started_at']) {
        st
          ..['started'] = r['started_at']
          ..['assigned'] = null
          ..['work'] = null
          ..['eta'] = null
          ..['visit'] = null;
      }
      st['status'] = r['status'] ?? 'no_response';
      // 다른 창·기기의 방재단원이 보낸 출동 기록 → 배정·단계·도착 예정 (내 메모리에 배정이 없을 때)
      final d = _dispatchOf(r);
      if (st['assigned'] == null && d != null && d.stage != 'done') {
        final mine = r['dispatch_by_me'] == true;
        st['assigned'] = {'user_id': null, 'nickname': mine ? _meNick : d.responder, 'is_me': mine};
        st['work'] = d.stage;
        st['eta'] = d.eta.toIso8601String();
      }
      out.add({
        'id': id,
        'kind': 'app_user',
        'household_id': null,
        'label': r['is_me'] == true ? '${r['label']} (나)' : '${r['label']}',
        'address': r['location_source'] == 'app' ? '주민 앱의 현재 위치' : '위치 정보 없음 · 시연 위치',
        'location': r['location'],
        'phone': null,
        'needs': [for (final n in r['needs'] as List? ?? const []) '$n'],
        'has_app': true,
        'status': st['status'],
        'minutes_since_alert': (r['minutes_since_alert'] as num?)?.toInt() ?? 0,
        'reminder_count': 0,
        'escalated': false,
        'assigned_to': st['assigned'],
        'work_status': st['work'],
        'last_visit': st['visit'],
        'eta': st['eta'],
        'in_area': true,
      });
    }
    // 이 기기의 시연 주민 줄: 서버에 내 응답이 없을 때만 (있으면 위 서버 줄과 겹친다)
    if (myAlertActive && !(server ?? const []).any((r) => r['is_me'] == true)) {
      final st = _stateFor(meTargetId, 1);
      st['status'] = myResponse ?? 'no_response';
      // 방재단 창을 새로 열었으면 메모리엔 없지만 기기에 남은 출동 기록으로 배정·단계·도착 예정을 되살린다
      if (st['assigned'] == null) {
        final d = await PrototypeSafetyController.storedDemoDispatch();
        if (d != null) {
          st['assigned'] = {'user_id': null, 'nickname': _meNick, 'is_me': true};
          st['work'] = d.stage;
          st['eta'] = d.eta.toIso8601String();
        }
      }
      // 장애 유형 = 주민이 '내 정보'에서 고른 것 (같은 브라우저의 다른 창이면 같은 기기 기록, 2026-10-11 사용자 요청)
      final profile = await AccountService().optionalProfile();
      final home = profile['homeAddress'] ?? '';
      out.add({
        'id': meTargetId,
        'kind': 'app_user',
        'household_id': null,
        'label': '앱 사용자 (시연 주민)',
        'address': home.isNotEmpty ? home : '예시 위치 (시연)',
        // 이 기기 주민의 현재 위치 (GPS·지도에서 고른 곳), 없으면 예시 위치
        'location': switch (PrototypeSafetyController.currentLocation()) {
          (final lat, final lng) => {'lat': lat, 'lng': lng},
          null => {'lat': 35.9893, 'lng': 129.5541},
        },
        'phone': null,
        'needs': remoteNeeds ?? [for (final d in disabilitiesOf(profile)) if (_profileNeeds[d] case final n?) n],
        'has_app': true,
        'status': st['status'],
        'minutes_since_alert': 0,
        'reminder_count': 0,
        'escalated': false,
        'assigned_to': st['assigned'],
        'work_status': st['work'],
        'last_visit': st['visit'],
        'eta': st['eta'],
        'in_area': true,
      });
    }
    // 서버 순위 대신: 대피 상태 단계 (화면이 우선 확인 순서를 다시 계산한다)
    const order = {'need_help': 1, 'no_response': 3, 'evacuating': 5, 'evacuated': 6};
    out.sort((a, b) => (order[a['status']] ?? 9).compareTo(order[b['status']] ?? 9));
    for (var i = 0; i < out.length; i++) {
      out[i]['priority_rank'] = i + 1;
      out[i]['priority_tier'] = order[out[i]['status']] ?? 6;
    }
    return out;
  }

  Map<String, dynamic> _incidentRow(List<Map<String, dynamic>> targets) => {
        'id': incidentId,
        'hazard': 'flood',
        'level': 'warning',
        'title': '호우 경보 · 구룡포항 저지대 침수 대피',
        'source': 'demo',
        'started_at': _started.toIso8601String(),
        'closed_at': null,
        'summary': {
          'total': targets.length,
          for (final s in const ['need_help', 'no_response', 'evacuating', 'evacuated'])
            s: targets.where((t) => t['status'] == s).length,
          'visited': targets.where((t) => t['last_visit'] != null).length,
        },
      };

  @override
  bool get supportsWorkStatus => true;

  @override
  Future<List<Map<String, dynamic>>> adminIncidents() async => [_incidentRow(await _demoTargets())];

  @override
  Future<Map<String, dynamic>> incident(String id, {double? lat, double? lng}) async {
    final targets = await _demoTargets();
    // 다른 계정의 응답이 몇 초 안에 보이게 5초마다 (2026-10-12)
    return {..._incidentRow(targets), 'area': _area(), 'targets': targets, 'next_poll_sec': 5};
  }

  /// 담당 지정(assigned_to: me|null) · 업무 단계(work_status) · 상태 — 앱 메모리에만
  @override
  Future<Map<String, dynamic>> patchTarget(String incidentId, String targetId, Map<String, dynamic> body) async {
    final st = _targetState(targetId);
    if (body.containsKey('assigned_to')) {
      if (body['assigned_to'] == 'me') {
        st['assigned'] = {'user_id': null, 'nickname': _meNick, 'is_me': true};
        st['work'] = 'en_route';
      } else {
        st['assigned'] = null;
        st['work'] = null;
        st['eta'] = null;
      }
    }
    if (body['work_status'] != null) st['work'] = body['work_status'];
    if (body['status'] != null) st['status'] = body['status'];
    await _syncDispatch(targetId, st);
    return {'id': targetId};
  }

  static const _meNick = '시연 방재단원(나)';

  /// '내 방문 경로' [출발] (2026-10-12 사용자 요청): 경로의 집마다 내가 맡고 '가는 중' + 도착 예정 시각.
  /// 시연 주민(앱 사용자)이 경로에 있으면 출발 사실·도착 예정을 기기 저장소로 보낸다 (같은 브라우저의 시민 창이 받는다)
  @override
  Future<void> dispatch(String incidentId, List<(String targetId, DateTime eta)> stops) async {
    final now = DateTime.now();
    for (final (id, eta) in stops) {
      final st = _targetState(id);
      st['assigned'] = {'user_id': null, 'nickname': _meNick, 'is_me': true};
      st['work'] = 'en_route';
      st['eta'] = eta.toIso8601String();
      final d = DemoDispatch(departedAt: now, eta: eta, responder: '시연 방재단원', stage: 'en_route');
      if (id == meTargetId) {
        await PrototypeSafetyController.saveDemoDispatch(d);
      } else if (_server.containsKey(id)) {
        await _saveServerDispatch(id, d);
      }
    }
  }

  static DemoDispatch? _dispatchOf(Map<String, dynamic>? row) {
    final raw = row?['dispatch'];
    if (raw is! Map) return null;
    try {
      return DemoDispatch.fromJson(Map<String, dynamic>.from(raw));
    } on FormatException {
      return null;
    }
  }

  /// 서버 시연 주민에게 출동 기록 보내기 (그 주민 앱이 5초마다 받아 '방재단 출발 · 도착 예정'을 띄운다)
  Future<void> _saveServerDispatch(String targetId, DemoDispatch? d) async {
    await writeServerDispatch(this, targetId, d?.toJson());
    _server[targetId]?['dispatch'] = d?.toJson();
  }

  /// 시연 주민 대상의 배정·단계가 바뀌면 시민에게 보낸 출동 기록도 맞춘다: 방문 중 → 도착, 완료 → 끝, 배정 해제 → 지움.
  /// 이 기기의 시연 주민(demo-me)은 기기 저장소로, 서버 시연 주민(다른 계정)은 서버로 (2026-10-12)
  Future<void> _syncDispatch(String targetId, Map<String, dynamic> st) async {
    final local = targetId == meTargetId;
    if (!local && !_server.containsKey(targetId)) return;
    final d = local ? await PrototypeSafetyController.storedDemoDispatch() : _dispatchOf(_server[targetId]);
    Future<void> save(DemoDispatch? x) =>
        local ? PrototypeSafetyController.saveDemoDispatch(x) : _saveServerDispatch(targetId, x);
    if (st['assigned'] == null) {
      if (d != null) await save(null);
      return;
    }
    final stage = switch (st['work']) { 'visiting' || 'escorting' => 'visiting', 'done' => 'done', _ => 'en_route' };
    if (d == null) {
      // 출발 버튼 없이 배정 현황에서 단계만 바꾼 경우: 도착 예정을 모르면 '가는 중'은 보내지 않고, 도착(방문 중)부터 알린다
      final eta = DateTime.tryParse('${st['eta']}');
      if (stage == 'en_route' && eta == null) return;
      final now = DateTime.now();
      await save(DemoDispatch(departedAt: now, eta: eta ?? now, responder: '시연 방재단원', stage: stage));
    } else if (d.stage != stage) {
      await save(d.copyWith(stage: stage));
    }
  }

  /// 방문 기록 — 대피 완료 결과는 주민 상태를 대피 완료로 (서버 규칙과 같게), 업무 단계도 완료로 (2026-10-11)
  @override
  Future<Map<String, dynamic>> recordVisit(String incidentId, String targetId, Map<String, dynamic> body) async {
    final st = _targetState(targetId);
    final result = '${body['result']}';
    st['visit'] = {
      'visited_at': DateTime.now().toIso8601String(),
      'result': result,
      'note': body['note'],
      'responder': {'user_id': null, 'nickname': '시연 방재단원(나)'},
    };
    if (const {'evacuated_with_help', 'already_evacuated', 'transported'}.contains(result)) {
      st['status'] = 'evacuated';
      st['work'] = 'done';
    }
    await _syncDispatch(targetId, st);
    return {'id': 'demo-visit-${DateTime.now().microsecondsSinceEpoch}'};
  }

  Map<String, dynamic> _targetState(String targetId) {
    if (targetId == meTargetId || _server.containsKey(targetId)) return _stateFor(targetId, 1);
    final hid = targetId.replaceFirst('demo-target-', '');
    return _state[hid] ?? _stateFor(hid, 0);
  }

  /// 시연 기록 지우기 (테스트·시연 다시 시작)
  static void resetDemoIncident() {
    _state.clear();
    _server.clear();
  }

  /// 서버 시연 가구 표시명의 '[시연] ' 머리 떼기 (서버는 이 머리로 시연 가구를 가려내므로 서버 데이터는 그대로 둔다)
  static String stripDemoPrefix(String label) => label.startsWith('[시연]') ? label.substring('[시연]'.length).trimLeft() : label;

  /// 시연 모드에서 대리 등록한 가구 (앱을 끄면 사라짐)
  static final _added = <Map<String, dynamic>>[];

  /// 가구 목록 = 늘 앱 안 6곳 (시각·청각·지체 예시, 2026-10-11 사용자 요청). 서버 DB 시연 가구(와상·의료기기 등, 레인 A)는
  /// 장애 유형이 대리 등록과 달라 더 쓰지 않는다
  @override
  Future<List<Map<String, dynamic>>> adminHouseholds() async =>
      [for (final h in [..._households, ..._added]) Map<String, dynamic>.from(h)];

  @override
  Future<Map<String, dynamic>> adminOverview() async {
    final all = await adminHouseholds();
    final counts = <String, int>{};
    for (final h in all) {
      for (final n in h['needs'] as List) {
        counts['$n'] = (counts['$n'] ?? 0) + 1;
      }
    }
    return {
      'role': 'responder',
      'households_total': all.length,
      'needs_counts': counts,
      'with_app': all.where((h) => h['has_app'] == true).length,
      'active_incidents': const [],
      'server_time': DateTime.now().toIso8601String(),
    };
  }

  /// 대리 등록: 시연 목록에 바로 추가 (앱을 끄면 사라짐)
  @override
  Future<Map<String, dynamic>> createHousehold(Map<String, dynamic> body) async {
    final h = {
      ..._h(++_seq, '${body['label'] ?? '새 가구'}', '${body['address'] ?? '주소 미입력'}',
          ((body['location'] as Map?)?['lat'] as num? ?? 35.99).toDouble(), ((body['location'] as Map?)?['lng'] as num? ?? 129.55).toDouble(),
          (body['members'] as num? ?? 1).toInt(), [for (final n in body['needs'] as List? ?? const []) '$n'],
          note: body['note'] as String?),
      if (body['phone'] != null) 'phone': body['phone'],
    };
    _added.add(h);
    return Map<String, dynamic>.from(h);
  }

  @override
  Future<Map<String, dynamic>> claimRole(String code) async => {'role': 'responder', 'label': '시연 방재단'};
}
