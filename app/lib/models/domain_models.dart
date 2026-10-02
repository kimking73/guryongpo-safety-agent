import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

enum UserMode { visitor, resident }
enum FacilityType { shelter, medical }

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
  const RiskArea({required this.level, required this.label, required this.polygons});
  final String level, label;
  final List<List<LatLng>> polygons;
}

enum RouteType { safest, nearest }

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
