import 'live_api.dart';

/// 시연 모드용 방재단 데이터 (2026-10-05). 시연 모드에서 방재단 화면(patrol_screens.dart, C8)이 [LiveApi] 대신 이 클래스를 쓴다.
/// 가구 목록: 서버 DB의 시연 가구(GET /api/v1/demo/households — '/internal/simulate demo_households'가 넣은 '[시연] …' 14곳)를
/// 먼저 쓰고, 서버에 없거나 연결이 안 되면 아래 앱 안 12곳. 대피 상황은 없다. 이름·주소·전화는 모두 가상이다.
class DemoLiveApi extends LiveApi {
  DemoLiveApi();

  static final _households = <Map<String, dynamic>>[
    _h(1, '[시연] 구룡포리 어르신 댁 1', '구룡포읍 구룡포리 (가상 주소)', 35.9881, 129.5536, 1, ['elderly', 'living_alone'],
        note: '대문 옆 초인종 고장 — 문을 두드려 주세요'),
    _h(2, '[시연] 구룡포리 어르신 댁 2', '구룡포읍 구룡포리 (가상 주소)', 35.9862, 129.5519, 2, ['elderly', 'mobility_limited']),
    _h(3, '[시연] 병포리 휠체어 가구', '구룡포읍 병포리 (가상 주소)', 35.9808, 129.5482, 3, ['wheelchair'],
        note: '경사로 없음, 2인 이동 필요'),
    _h(4, '[시연] 병포리 와상 어르신 댁', '구룡포읍 병포리 (가상 주소)', 35.9822, 129.5455, 2, ['elderly', 'bedridden'],
        caregiver: '생활지원사 (가상)', landslide: '산사태위험지도 2등급 비탈 60m'),
    _h(5, '[시연] 삼정리 독거 어르신 댁', '구룡포읍 삼정리 (가상 주소)', 36.0012, 129.5698, 1, ['elderly', 'living_alone', 'hearing'],
        note: '청각 — 문자보다 방문 확인 우선'),
    _h(6, '[시연] 삼정리 영유아 가구', '구룡포읍 삼정리 (가상 주소)', 35.9986, 129.5664, 4, ['infant']),
    _h(7, '[시연] 석병리 해안 어르신 댁', '구룡포읍 석병리 (가상 주소)', 35.9649, 129.5684, 1, ['elderly', 'vision'],
        landslide: '산사태위험지도 1등급 비탈 40m'),
    _h(8, '[시연] 눌태리 산비탈 가구', '구룡포읍 눌태리 (가상 주소)', 35.9732, 129.5391, 2, ['elderly', 'cognitive'],
        caregiver: '생활지원사 (가상)', landslide: '산사태위험지도 1등급 비탈 25m'),
    _h(9, '[시연] 하정리 의료기기 사용 가구', '구룡포읍 하정리 (가상 주소)', 35.9928, 129.5602, 2, ['medical_device'],
        note: '산소발생기 사용 — 정전 시 우선 확인'),
    _h(10, '[시연] 구평리 반려동물 가구', '구룡포읍 구평리 (가상 주소)', 36.0108, 129.5751, 1, ['elderly', 'pet']),
    _h(11, '[시연] 성동리 보행 불편 가구', '구룡포읍 성동리 (가상 주소)', 35.9779, 129.5268, 2, ['mobility_limited']),
    _h(12, '[시연] 장길리 어촌 어르신 댁', '구룡포읍 장길리 (가상 주소)', 35.9558, 129.5734, 1, ['elderly', 'living_alone'],
        hasApp: true, source: 'self'),
  ];
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

  @override
  Future<List<Map<String, dynamic>>> adminIncidents() async => const [];

  /// 시연 모드에서 대리 등록한 가구 (앱을 끄면 사라짐)
  static final _added = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> adminHouseholds() async {
    try {
      final server = await demoHouseholds();
      if (server.isNotEmpty) return [...server, for (final h in _added) Map<String, dynamic>.from(h)];
    } catch (_) {}
    return [for (final h in [..._households, ..._added]) Map<String, dynamic>.from(h)];
  }

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
      ..._h(++_seq, '[시연] ${body['label'] ?? '새 가구'}', '${body['address'] ?? '주소 미입력'}',
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
