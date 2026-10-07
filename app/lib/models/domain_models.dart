import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

enum UserMode { user }

/// place: AI가 안내한 일반 목적지(구룡포항·집 등)
enum FacilityType { shelter, medical, place }

/// 사용자 위치를 확인하지 못했을 때 쓰는 구룡포 기본 예시 좌표.
LatLng originFor(UserMode _) => const LatLng(35.9918, 129.5507);

class Facility {
  const Facility(
      {required this.id,
      required this.name,
      required this.type,
      required this.position,
      required this.address,
      required this.description,
      required this.distanceKm,
      required this.walkMinutes,
      required this.accessible,
      this.open = true,
      this.phone});
  final String id, name, address, description;
  final FacilityType type;
  final LatLng position;
  final double distanceKm;
  final int walkMinutes;
  final bool accessible, open;
  final String? phone;
}

class AlertItem {
  const AlertItem(
      {required this.id,
      required this.title,
      required this.level,
      required this.time,
      required this.summary,
      required this.guide,
      this.read = false,
      this.responseRequired = false,
      this.myStatus});
  final String id, title, level, time, summary, guide;
  final bool read;
  final bool responseRequired;
  final String? myStatus;

  AlertItem copyWith({bool? read, String? myStatus}) => AlertItem(
        id: id,
        title: title,
        level: level,
        time: time,
        summary: summary,
        guide: guide,
        read: read ?? this.read,
        responseRequired: responseRequired,
        myStatus: myStatus ?? this.myStatus,
      );
}

List<AlertItem> mergeAlertsById(
    Iterable<AlertItem> existing, Iterable<AlertItem> incoming) {
  final merged = <String, AlertItem>{
    for (final alert in existing) alert.id: alert,
  };
  for (final alert in incoming) {
    merged[alert.id] = alert;
  }
  return merged.values.toList();
}

class RiskStatus {
  const RiskStatus(
      {required this.level,
      required this.title,
      required this.summary,
      required this.updatedAt,
      required this.guide,
      this.details = const [],
      this.stale = false});
  final String level, title, summary, updatedAt, guide;

  /// 판정 항목별 한 줄 근거 (예: "침수 경보 — 수위계 침수심 230mm"). 목업은 비어 있음.
  final List<String> details;

  /// 판정 엔진이 30분 넘게 갱신되지 않음
  final bool stale;
  Color get color => switch (level) {
        '심각' => Colors.red.shade800,
        '경계' => Colors.orange.shade800,
        '주의' => Colors.amber.shade800,
        _ => Colors.teal.shade700
      };
}

/// 지도에 칠할 현재 위험 영역 (/risk/areas). 폴리곤마다 바깥 고리만 쓴다.
class RiskArea {
  const RiskArea(
      {required this.level,
      required this.label,
      required this.polygons,
      this.hazard = 'flood',
      this.sensor,
      this.reason,
      this.observedAt});
  final String level, label;

  /// flood, landslide, heavy_rain …
  final String hazard;

  /// 판정 원인 센서 좌표 (침수 = 수위계·맨홀, 영역은 이 점 중심 원). 서버 properties.location, 없으면 null
  final LatLng? sensor;

  /// 판정 근거 문장 (예: "구룡포환승센터 지표면 수위계 침수심 230mm …"), 측정 시각
  final String? reason, observedAt;
  final List<List<LatLng>> polygons;
  bool contains(LatLng p) => polygons.any((ring) => _inRing(p, ring));
}

/// A grid cell backed by a risk assessment. Null measurements stay unknown;
/// the risk level is independent from the optional measured flood depth.
class FloodGrid {
  const FloodGrid(
      {required this.id,
      required this.level,
      required this.south,
      required this.west,
      required this.north,
      required this.east,
      this.depthCm,
      this.observedAt,
      this.source = '',
      this.isExample = false,
      this.rings = const []});
  final String id, level, source;
  final double south, west, north, east;
  /// 서버 격자 칸을 위험 영역 모양대로 자른 실제 모양 (2026-10-05). 비어 있으면 네모 칸(south·west·north·east)
  final List<List<LatLng>> rings;
  /// 지도에 그릴 모양: 잘린 모양이 있으면 그것, 없으면 네모
  List<List<LatLng>> get shapes => rings.isNotEmpty
      ? rings
      : [
          [LatLng(south, west), LatLng(south, east), LatLng(north, east), LatLng(north, west)]
        ];
  final double? depthCm;
  final String? observedAt;
  final bool isExample;
  bool get hasRisk => const {'주의', '경계', '심각'}.contains(level);
  LatLng get center => LatLng((south + north) / 2, (west + east) / 2);
}

/// Full-extent illustrative fixture for the demo map. Empty cells are
/// explicitly unassessed and must never be rendered with a risk color.
List<FloodGrid> demoFloodGrid(int timeIndex) {
  const south = 35.93, west = 129.50, north = 36.05, east = 129.60;
  const rows = 32, cols = 32;
  final dLat = (north - south) / rows, dLng = (east - west) / cols;
  final result = <FloodGrid>[];
  for (var row = 0; row < rows; row++) {
    for (var col = 0; col < cols; col++) {
      // Sparse clusters represent scenario cells. All other cells are unknown.
      final harborCluster = row >= 11 && row <= 16 && col >= 15 && col <= 21;
      final southCluster = row >= 5 && row <= 9 && col >= 17 && col <= 23;
      final inlandCluster = row >= 23 && row <= 26 && col >= 9 && col <= 13;
      final active = harborCluster || southCluster || inlandCluster;
      String level = '미확인';
      double? depth;
      if (active) {
        if ((row + col + timeIndex) % 17 == 0) {
          depth = 0; // Explicit zero-depth fixture: no risk fill is drawn.
        } else {
          final score = (row * 7 + col * 11 + timeIndex * 3) % 10;
          level = score >= 7
              ? '심각'
              : score >= 4
                  ? '경계'
                  : '주의';
          // Example depths are display fixtures, not thresholds for these levels.
          depth = (6 + ((row * 13 + col * 7 + timeIndex * 5) % 46)).toDouble();
        }
      }
      result.add(FloodGrid(
        id: '구룡포-${row + 1}-${col + 1}',
        level: level,
        south: south + row * dLat,
        west: west + col * dLng,
        north: south + (row + 1) * dLat,
        east: west + (col + 1) * dLng,
        depthCm: depth,
        observedAt: active ? '14:00' : null,
        source: active ? '화면 검토용 시나리오' : '',
        isExample: true,
      ));
    }
  }
  return result;
}

/// 점이 다각형 고리 안인지 (반직선 교차 수)
bool _inRing(LatLng p, List<LatLng> ring) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i], b = ring[j];
    if ((a.latitude > p.latitude) != (b.latitude > p.latitude) &&
        p.longitude <
            (b.longitude - a.longitude) *
                    (p.latitude - a.latitude) /
                    (b.latitude - a.latitude) +
                a.longitude) {
      inside = !inside;
    }
  }
  return inside;
}

/// 대피 후보에서 뺄 이유 (없으면 null). AI 위치·경로 agent(ai/guardian_ai/tools.py get_safe_shelters)와 같은 규칙:
/// ① 발효 중인 침수·산사태 영역(주의 이상) 안 ② 침수 영역이 하나라도 있을 때 지하 시설.
/// 호우 영역은 읍 전체라 쓰지 않는다.
String? shelterExclusion(Facility f, List<RiskArea> areas) {
  if (f.type != FacilityType.shelter) return null;
  final active = areas.where((a) =>
      (a.hazard == 'flood' || a.hazard == 'landslide') &&
      const {'주의', '경계', '심각'}.contains(a.level));
  final hit =
      active.where((a) => a.contains(f.position)).map((a) => a.label).toSet();
  if (hit.isNotEmpty) return '위험 영역 안(${hit.join(', ')})';
  if (f.name.contains('지하') && active.any((a) => a.hazard == 'flood'))
    return '침수 중 지하 시설';
  return null;
}

/// 경로 종류 (2026-10-07 세 가지): 가까운 = 위험 회피 없는 최단 거리, 안전 = 위험 구역 회피(기본), 오르막 회피 = 위험 회피 + 오르막 회피.
/// 걸음 속도는 셋 다 사용자 유형(성인·노약자)대로. 경로 서버 strategy: shortest · safest · flat (route/guardian_route/profiles.py)
enum RouteType { safest, nearest, flat }

extension RouteTypeInfo on RouteType {
  /// 화면에 나오는 순서
  static const ordered = [RouteType.nearest, RouteType.safest, RouteType.flat];
  String get label => switch (this) {
        RouteType.nearest => '가까운 경로',
        RouteType.safest => '안전 경로',
        RouteType.flat => '오르막 회피 경로',
      };
  String get shortLabel => switch (this) {
        RouteType.nearest => '가까운',
        RouteType.safest => '안전',
        RouteType.flat => '오르막 회피',
      };
  String get description => switch (this) {
        RouteType.nearest => '최단 거리 · 위험 구역을 피하지 않음 (지나는 구역은 경고)',
        RouteType.safest => '확인된 침수·산사태 위험 구역을 피함',
        RouteType.flat => '위험 구역 회피 + 오르막(경사 1/18 초과)을 피함 · 내리막은 그대로',
      };
  String get strategy => switch (this) {
        RouteType.nearest => 'shortest',
        RouteType.safest => 'safest',
        RouteType.flat => 'flat',
      };
}

/// 65세 이상, 휠체어 사용자 또는 보행 불편 사용자는 접근성 경로를 사용한다.
String deriveRouteProfile(int? age, String? transport,
        {bool walkingImpaired = false}) =>
    (age != null && age >= 65) || transport == '휠체어' || walkingImpaired
        ? 'elderly'
        : 'adult';

/// AI 답변 한 개. 경로 안내가 있으면 route·목적지가 함께 온다 ("지도에서 경로 보기").
/// voiceText = 음성으로 읽을 짧은 문장(서버 voice_text), audio = 음성 질문의 답 음성(mp3)
class ChatAnswer {
  const ChatAnswer(this.text,
      {this.route,
      this.destinationName,
      this.destinationPos,
      this.destinationKind,
      this.voiceText,
      this.audio,
      this.isError = false});
  final String text;
  final String? voiceText;
  final Uint8List? audio;
  final SafetyRoute? route;
  final String? destinationName, destinationKind;
  final LatLng? destinationPos;
  final bool isError;
}

/// 음성 질문 결과: 받아쓴 질문 + 답 (답 음성은 answer.audio)
class VoiceAnswer {
  const VoiceAnswer(this.transcript, this.answer);
  final String transcript;
  final ChatAnswer answer;
}

/// 채팅 화면의 말풍선 하나
class ChatMessage {
  const ChatMessage(this.text, this.mine, {this.answer});
  final String text;
  final bool mine;
  final ChatAnswer? answer;
}

/// 사용자가 등록한 장소 (기기에 저장, AccountService). type: 집·직장·기타
class SavedPlace {
  const SavedPlace(
      {required this.id,
      required this.name,
      required this.type,
      required this.position,
      this.address = '',
      this.alert = true});
  final String id, name, type;
  final String address;
  final LatLng position;
  final bool alert;
  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'address': address,
        'lat': position.latitude,
        'lon': position.longitude,
        'alert': alert
      };
  factory SavedPlace.fromJson(Map<String, dynamic> j) => SavedPlace(
      id: '${j['id']}',
      name: '${j['name']}',
      type: '${j['type']}',
      position:
          LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
      address: '${j['address'] ?? ''}',
      alert: j['alert'] != false);
}

class SafetyRoute {
  const SafetyRoute({
    required this.shelterId,
    required this.routeType,
    required this.polylinePoints,
    required this.distanceMeters,
    required this.estimatedMinutes,
    required this.riskAvoidanceSummary,
    this.avoided = const [],
    this.stillInside = const [],
    this.profile = 'adult',
    this.maxSlopePercent = 0,
    this.maxUphillPercent = 0,
    this.hazardsOk = true,
    this.encodedGeometry,
    this.seaPoints = const [],
  });

  final String shelterId;
  final RouteType routeType;
  final List<LatLng> polylinePoints;
  final int distanceMeters;
  final int estimatedMinutes;
  final String riskAvoidanceSummary;

  /// 이 경로가 피한 위험 구역 이름
  final List<String> avoided;

  /// 다른 길이 없어 이 경로도 지나는 위험 구역 이름
  final List<String> stillInside;

  /// Profile and route diagnostics returned by the route API.
  final String profile;
  final int maxSlopePercent;

  /// 진행 방향 기준 가장 급한 오르막 (경로 서버 max_uphill_pct)
  final int maxUphillPercent;
  final bool hazardsOk;
  final String? encodedGeometry;

  /// AI에게 바다 위에서 물었을 때 항구까지 바닷길 (점선으로 그림). polylinePoints는 항구 → 목적지 도보 경로
  final List<LatLng> seaPoints;
}

class RouteCheckResult {
  const RouteCheckResult({
    required this.reroute,
    required this.reasons,
    required this.offRouteMeters,
    required this.hazardsAhead,
    required this.arrived,
    this.route,
  });

  final bool reroute;
  final List<String> reasons;
  final int offRouteMeters;
  final List<String> hazardsAhead;
  final bool arrived;
  final SafetyRoute? route;
}

class AlertPollResult {
  const AlertPollResult({
    required this.alerts,
    required this.serverTime,
    required this.nextPollSeconds,
    required this.mode,
    this.evacuation,
  });

  final List<AlertItem> alerts;
  final DateTime? serverTime;
  final int nextPollSeconds;
  final String mode;
  final Map<String, dynamic>? evacuation;
}
