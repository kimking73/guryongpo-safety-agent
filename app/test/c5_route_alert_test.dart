import 'package:flutter_test/flutter_test.dart';
import 'package:guryongpo_safety/models/domain_models.dart';
import 'package:guryongpo_safety/repositories/remote_repository.dart';

void main() {
  test('route check reroute response replaces route with returned profile data',
      () {
    final result = routeCheckResultFromJson(
      {
        'reroute': true,
        'reasons': ['off_route', 'hazard_on_route'],
        'off_route_m': 55,
        'hazards_ahead': ['flood-001'],
        'arrived': false,
        'route': {
          'profile': 'elderly',
          'distance_m': 380,
          'duration_s': 330,
          'max_slope_pct': 8,
          'avoided': ['flood-001'],
          'still_inside': [],
          'hazards_ok': true,
          'geometry': '_p~iF~ps|U',
        },
      },
      facilityId: 'shelter-1',
      routeType: RouteType.safest,
      names: const {'flood-001': '항구 뒷길 침수 구역'},
    );

    expect(result.reroute, isTrue);
    expect(result.reasons, ['off_route', 'hazard_on_route']);
    expect(result.offRouteMeters, 55);
    expect(result.hazardsAhead, ['flood-001']);
    expect(result.route?.profile, 'elderly');
    expect(result.route?.maxSlopePercent, 8);
    expect(result.route?.encodedGeometry, '_p~iF~ps|U');
    expect(result.route?.riskAvoidanceSummary, contains('항구 뒷길 침수 구역'));
  });

  test(
      'alert poll response parses cursor, dynamic interval, mode and read state',
      () {
    final result = alertPollResultFromJson({
      'alerts': [
        {
          'id': 'alert-1',
          'title': '침수 경고',
          'body': '저지대에서 이동하세요.',
          'risk': {'level': 'warning'},
          'created_at': '2026-10-04T09:30:00',
          'read_at': null,
        },
        {
          'id': 'alert-2',
          'title': '강풍 경고',
          'body': '해안가 접근을 피하세요.',
          'risk': {'level': 'advisory'},
          'created_at': '2026-10-04T09:20:00',
          'read_at': '2026-10-04T09:25:00',
        },
      ],
      'server_time': '2026-10-04T09:30:10Z',
      'next_poll_sec': 15,
      'mode': 'emergency',
      'evacuation': {'status': 'evacuating'},
    });

    expect(result.alerts.map((a) => a.id), ['alert-1', 'alert-2']);
    expect(result.alerts.first.level, '경계');
    expect(result.alerts.first.read, isFalse);
    expect(result.alerts.last.read, isTrue);
    expect(result.nextPollSeconds, 15);
    expect(result.mode, 'emergency');
    expect(result.evacuation?['status'], 'evacuating');
    expect(result.serverTime, DateTime.parse('2026-10-04T09:30:10Z'));
  });

  test('FCM and polling alerts deduplicate by ID and polling data wins', () {
    const push = AlertItem(
      id: 'same-id',
      title: '푸시 미리보기',
      level: '경보',
      time: '09:30',
      summary: 'FCM body',
      guide: 'FCM body',
    );
    const polled = AlertItem(
      id: 'same-id',
      title: '서버 알림 상세',
      level: '경계',
      time: '09:30',
      summary: '최신 API body',
      guide: '행동 요령',
      read: true,
    );
    const other = AlertItem(
      id: 'other',
      title: '다른 경고',
      level: '주의',
      time: '09:25',
      summary: '본문',
      guide: '요령',
    );

    final merged = mergeAlertsById([push], [polled, other]);

    expect(merged, hasLength(2));
    expect(merged.first.title, '서버 알림 상세');
    expect(merged.first.read, isTrue);
  });
}
