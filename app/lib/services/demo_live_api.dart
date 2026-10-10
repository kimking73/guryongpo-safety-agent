import 'dart:math' as math;

import 'live_api.dart';

/// 시연 모드용 방재단 데이터 (2026-10-05). 시연 모드에서 방재단 화면(patrol_screens.dart, C8)이 [LiveApi] 대신 이 클래스를 쓴다.
/// 가구 목록: 앱 안 6곳 (시각·청각·지체 예시). 예전엔 서버 DB의 시연 가구(GET /api/v1/demo/households)를
/// 먼저 썼지만 장애 유형이 대리 등록(시각·청각·지체)과 달라 뺐다 (2026-10-11). 이름·주소·전화는 모두 가상이다.
/// 대피 상황 (2026-10-09): 앱 안 예시 대피 상황 하나 — 가구별 응답·배정·업무 단계는 이 앱 메모리에만 있고 서버로 보내지 않는다
/// (실제 응답·배정 데이터와 분리). '대피 경보 팝업' 시연 경보가 진행 중이면 '앱 사용자 (나 · 시연)'가 대상에 들어가고
/// 상태 = 팝업에서 고른 시연 응답.
class DemoLiveApi extends LiveApi {
  DemoLiveApi();

  /// 앱 안 시연 가구 6곳 (2026-10-10 사용자 요청: 시연 데이터를 줄이고 이름의 '[시연]' 표시는 뗀다 — 독거노인 분류도 서비스 대상 아님).
  /// 장애 유형은 시각·청각·지체만 (2026-10-11 사용자 요청 — 가구 대리 등록이 묻는 유형과 같게. 지체 = mobility_limited).
  /// 앞 4곳은 구룡포항 둘레 대피 경보 지역 안 (우선 확인 가구에 나온다)
  static final _households = <Map<String, dynamic>>[
    _h(1, '구룡포리 지체장애 어르신 댁', '구룡포읍 구룡포리 (가상 주소)', 35.9862, 129.5519, 2, ['elderly', 'mobility_limited'],
        note: '대문 옆 초인종 고장 — 문을 두드려 주세요'),
    _h(2, '병포리 지체장애 주민 댁', '구룡포읍 병포리 (가상 주소)', 35.9808, 129.5482, 3, ['mobility_limited'],
        note: '휠체어 사용 · 경사로 없음, 2인 이동 필요'),
    _h(3, '구룡포리 청각장애 주민 댁', '구룡포읍 구룡포리 (가상 주소)', 35.9881, 129.5536, 1, ['hearing'],
        note: '청각 — 문자보다 방문 확인 우선'),
    _h(4, '병포리 시각장애 어르신 댁', '구룡포읍 병포리 (가상 주소)', 35.9822, 129.5455, 2, ['elderly', 'vision'],
        caregiver: '생활지원사 (가상)', landslide: '산사태위험지도 2등급 비탈 60m'),
    _h(5, '하정리 청각장애 어르신 댁', '구룡포읍 하정리 (가상 주소)', 35.9928, 129.5602, 2, ['elderly', 'hearing'],
        note: '보청기 사용 — 문을 크게 두드려 주세요'),
    _h(6, '석병리 해안 시각장애 주민 댁', '구룡포읍 석병리 (가상 주소)', 35.9649, 129.5684, 1, ['vision'],
        landslide: '산사태위험지도 1등급 비탈 40m', hasApp: true, source: 'self'),
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
  static const meTargetId = 'demo-me';
  /// 가구별 시연 상태 (응답·담당·업무 단계·마지막 방문). 처음 보는 가구는 아래 순서표로 채운다
  static final _state = <String, Map<String, dynamic>>{};
  static const _pattern = <(String, String?, String?)>[
    ('need_help', '방재단원 A (예시)', 'en_route'),
    ('no_response', null, null),
    ('need_help', null, null),
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
        'in_area': lat == null || lng == null || _distM(lat, lng) <= _radiusM,
      });
    }
    if (myAlertActive) {
      final st = _stateFor(meTargetId, 1);
      st['status'] = myResponse ?? 'no_response';
      out.add({
        'id': meTargetId,
        'kind': 'app_user',
        'household_id': null,
        'label': '앱 사용자 (나 · 시연)',
        'address': '예시 위치 (시연)',
        'location': {'lat': 35.9893, 'lng': 129.5541},
        'phone': null,
        'needs': const [],
        'has_app': true,
        'status': st['status'],
        'minutes_since_alert': 0,
        'reminder_count': 0,
        'escalated': false,
        'assigned_to': st['assigned'],
        'work_status': st['work'],
        'last_visit': st['visit'],
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
    return {..._incidentRow(targets), 'area': _area(), 'targets': targets, 'next_poll_sec': 10};
  }

  /// 담당 지정(assigned_to: me|null) · 업무 단계(work_status) · 상태 — 앱 메모리에만
  @override
  Future<Map<String, dynamic>> patchTarget(String incidentId, String targetId, Map<String, dynamic> body) async {
    final st = _targetState(targetId);
    if (body.containsKey('assigned_to')) {
      if (body['assigned_to'] == 'me') {
        st['assigned'] = {'user_id': null, 'nickname': '시연 방재단원(나)', 'is_me': true};
        st['work'] = 'en_route';
      } else {
        st['assigned'] = null;
        st['work'] = null;
      }
    }
    if (body['work_status'] != null) st['work'] = body['work_status'];
    if (body['status'] != null) st['status'] = body['status'];
    return {'id': targetId};
  }

  /// 방문 기록 — 앞의 세 결과는 주민 상태를 대피 완료로 (서버 규칙과 같게). 업무 단계는 바꾸지 않는다
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
    if (const {'evacuated_with_help', 'already_evacuated', 'transported'}.contains(result)) st['status'] = 'evacuated';
    return {'id': 'demo-visit-${DateTime.now().microsecondsSinceEpoch}'};
  }

  Map<String, dynamic> _targetState(String targetId) {
    if (targetId == meTargetId) return _stateFor(meTargetId, 1);
    final hid = targetId.replaceFirst('demo-target-', '');
    return _state[hid] ?? _stateFor(hid, 0);
  }

  /// 시연 기록 지우기 (테스트·시연 다시 시작)
  static void resetDemoIncident() => _state.clear();

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
