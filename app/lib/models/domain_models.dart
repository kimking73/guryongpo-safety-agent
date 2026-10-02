import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

enum UserMode { visitor, resident }
enum FacilityType { shelter, medical }

class Facility {
  const Facility({required this.id, required this.name, required this.type, required this.position, required this.address, required this.description, required this.distanceKm, required this.walkMinutes, required this.accessible, this.open = true});
  final String id, name, address, description;
  final FacilityType type;
  final LatLng position;
  final double distanceKm;
  final int walkMinutes;
  final bool accessible, open;
}

class AlertItem {
  const AlertItem({required this.id, required this.title, required this.level, required this.time, required this.summary, required this.guide, this.read = false});
  final String id, title, level, time, summary, guide;
  final bool read;
}

class RiskStatus {
  const RiskStatus({required this.level, required this.title, required this.summary, required this.updatedAt, required this.guide});
  final String level, title, summary, updatedAt, guide;
  Color get color => switch (level) { '심각' => Colors.red.shade800, '경계' => Colors.orange.shade800, '주의' => Colors.amber.shade800, _ => Colors.teal.shade700 };
}

enum RouteType { safest, nearest }

class MockRoute {
  const MockRoute({
    required this.shelterId,
    required this.routeType,
    required this.polylinePoints,
    required this.distanceMeters,
    required this.estimatedMinutes,
    required this.riskAvoidanceSummary,
  });

  final String shelterId;
  final RouteType routeType;
  final List<LatLng> polylinePoints;
  final int distanceMeters;
  final int estimatedMinutes;
  final String riskAvoidanceSummary;
}
