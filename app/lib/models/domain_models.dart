import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

enum UserMode { visitor, resident }
/// place: AI가 안내한 일반 목적지(구룡포항·집 등)
enum FacilityType { shelter, medical, place }

/// 사용자 유형별 출발 위치 (GPS 연동 전까지 구룡포 예시 좌표). 위험도 조회·경로·AI 질문이 같은 값을 쓴다.
LatLng originFor(UserMode mode) => mode == UserMode.resident
    ? const LatLng(35.9918, 129.5507)
    : const LatLng(35.9907, 129.5526);

class Facility {
  const Facility({required this.id, required this.name, required this.type, required this.position, required this.address, required this.description, required this.distanceKm, required this.walkMinutes, required this.accessible, this.open = true, this.phone});
  final String id, name, address, description;
  final FacilityType type;
  final LatLng position;
  final double distanceKm;
  final int walkMinutes;
  final bool accessible, open;
  final String? phone;
}

class AlertItem {
  const AlertItem({required this.id, required this.title, required this.level, required this.time, required this.summary, required this.guide, this.read = false});
  final String id, title, level, time, summary, guide;
  final bool read;
}

class RiskStatus {
  const RiskStatus({required this.level, required this.title, required this.summary, required this.updatedAt, required this.guide, this.details = const [], this.stale = false});
  final String level, title, summary, updatedAt, guide;
  /// 판정 항목별 한 줄 근거 (예: "침수 경보 — 수위계 침수심 230mm"). 목업은 비어 있음.
  final List<String> details;
  /// 판정 엔진이 30분 넘게 갱신되지 않음
  final bool stale;
  Color get color => switch (level) { '심각' => Colors.red.shade800, '경계' => Colors.orange.shade800, '주의' => Colors.amber.shade800, _ => Colors.teal.shade700 };
}

/// 지도에 칠할 현재 위험 영역 (/risk/areas). 폴리곤마다 바깥 고리만 쓴다.
class RiskArea {
  const RiskArea({required this.level, required this.label, required this.polygons, this.hazard = 'flood'});
  final String level, label;
  /// flood, landslide, heavy_rain …
  final String hazard;
  final List<List<LatLng>> polygons;
  bool contains(LatLng p) => polygons.any((ring) => _inRing(p, ring));
}

/// 점이 다각형 고리 안인지 (반직선 교차 수)
bool _inRing(LatLng p, List<LatLng> ring) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i], b = ring[j];
    if ((a.latitude > p.latitude) != (b.latitude > p.latitude) &&
        p.longitude < (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude) {
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
  final active = areas.where((a) => (a.hazard == 'flood' || a.hazard == 'landslide') && const {'주의', '경계', '심각'}.contains(a.level));
  final hit = active.where((a) => a.contains(f.position)).map((a) => a.label).toSet();
  if (hit.isNotEmpty) return '위험 영역 안(${hit.join(', ')})';
  if (f.name.contains('지하') && active.any((a) => a.hazard == 'flood')) return '침수 중 지하 시설';
  return null;
}

enum RouteType { safest, nearest }

/// AI 답변 한 개. 경로 안내가 있으면 route·목적지가 함께 온다 ("지도에서 경로 보기").
class ChatAnswer {
  const ChatAnswer(this.text, {this.route, this.destinationName, this.destinationPos, this.destinationKind});
  final String text;
  final SafetyRoute? route;
  final String? destinationName, destinationKind;
  final LatLng? destinationPos;
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
  const SavedPlace({required this.id, required this.name, required this.type, required this.position, this.alert = true});
  final String id, name, type;
  final LatLng position;
  final bool alert;
  Map<String, Object> toJson() => {'id': id, 'name': name, 'type': type, 'lat': position.latitude, 'lon': position.longitude, 'alert': alert};
  factory SavedPlace.fromJson(Map<String, dynamic> j) => SavedPlace(id: '${j['id']}', name: '${j['name']}', type: '${j['type']}',
      position: LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()), alert: j['alert'] != false);
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
}
