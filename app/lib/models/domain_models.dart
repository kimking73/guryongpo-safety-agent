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
      this.hazard = 'flood'});
  final String level, label;

  /// flood, landslide, heavy_rain …
  final String hazard;
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
      this.isExample = false});
  final String id, level, source;
  final double south, west, north, east;
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

enum RouteType { safest, nearest }

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
    this.hazardsOk = true,
    this.encodedGeometry,
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
  final bool hazardsOk;
  final String? encodedGeometry;
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
