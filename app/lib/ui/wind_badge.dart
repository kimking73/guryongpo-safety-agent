import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 지도 위 바람 표식: 불어가는 쪽 화살표만, 조금 투명하게 (2026-10-11 사용자 요청 — 원형 배지 대신).
/// 단계(1 주의 · 2 경계 · 3 심각)가 높을수록 크고, 색 = 단계색. 숫자는 넣지 않는다 (누르면 상세, 2026-10-10 결정)
class WindBadge extends StatelessWidget {
  const WindBadge({super.key, required this.color, required this.level, this.towardDeg = 0, this.size});

  final Color color;
  final int level;
  /// 바람이 불어가는 쪽 (도, 북 0 · 시계 방향) = 풍향(불어오는 쪽) + 180
  final double towardDeg;
  /// 크기를 직접 정할 때 (범례). 없으면 단계로
  final double? size;

  /// 표식 칸 크기 (Marker width/height)
  static double boxFor(int level) => diameterFor(level) + 6;
  static double diameterFor(int level) => switch (level) { >= 3 => 38.0, 2 => 31.0, _ => 24.0 };

  /// 평균·순간 풍속 → 단계 (강풍주의보 평균 14·순간 20, 강풍경보 평균 21·순간 26)
  static int levelOf(double averageSpeed, double gustSpeed) =>
      averageSpeed >= 21 || gustSpeed >= 26 ? 3 : averageSpeed >= 14 || gustSpeed >= 20 ? 2 : 1;

  @override
  Widget build(BuildContext context) => Center(
        child: Transform.rotate(
          angle: towardDeg * math.pi / 180,
          child: Icon(Icons.navigation, color: color.withValues(alpha: .7), size: size ?? diameterFor(level)),
        ),
      );
}
