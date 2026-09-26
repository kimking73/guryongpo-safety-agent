"""사용자 유형(profile)별 경로 규칙 (B7). GraphHopper custom_model 문장으로 쓴다.

유형은 성인·노약자 두 가지다 (휠체어는 제외, 사용자 결정 2026-09-26).
- priority: 그 길을 얼마나 덜 고를지 (1 = 그대로, 0.5 = 두 배 비싸게, 0 = 아예 안 감). 여러 줄이 맞으면 곱해진다.
- speed: 걷는 속도 배수 (예상 소요 시간에 반영)
- average_slope: 도로 구간의 평균 경사(%). 오르막·내리막 모두 부담이라 양쪽을 본다.
숫자는 시작값이다. 5m DEM을 받으면 실제 경로를 보며 조정한다.
"""

from __future__ import annotations

from typing import Any

# 노약자 계단 배수. 급경사(≥10%) 도로 배수보다 커야 "같은 경사면 계단을 더 선호"가 된다.
ELDERLY_STEPS = 0.3
ELDERLY_STEEP_10 = 0.2
ELDERLY_STEEP_6 = 0.5

PROFILE_RULES: dict[str, dict[str, list[dict[str, Any]]]] = {
    # 성인: 경사를 반영하지 않는다 (사용자 결정). 도보 기본 모델 그대로 = 가장 빠른 길.
    "adult": {"priority": [], "speed": []},

    # 노약자: 걸음이 느리고 급경사가 부담. 같은 경사라면 비탈길보다 계단을 선호한다 (손잡이·단이 있어 덜 미끄럽다).
    # 그래서 경사 벌점은 계단이 아닌 도로에만 주고, 계단은 ELDERLY_STEPS 하나만 받는다.
    # 계단은 대개 10%보다 훨씬 가파르므로 비교 대상은 ≥10% 도로(×0.2)이고, 계단(×0.3)이 그보다 싸다.
    "elderly": {
        "priority": [
            {"if": "road_class == STEPS", "multiply_by": str(ELDERLY_STEPS)},
            {"else_if": "average_slope >= 10 || average_slope <= -10", "multiply_by": str(ELDERLY_STEEP_10)},
            {"else_if": "average_slope >= 6 || average_slope <= -6", "multiply_by": str(ELDERLY_STEEP_6)},
        ],
        "speed": [{"if": "true", "multiply_by": "0.75"}],   # 보행 약 5km/h → 약 3.8km/h
    },
}
