"""사용자 유형(profile)별 경로 규칙 (B7). GraphHopper custom_model 문장으로 쓴다.

기획서: 건강한 성인은 최단 시간 경로, 노약자·이동 제약이 있는 사용자는 급한 오르막(과 계단)을 우회한다.
- priority: 그 길을 얼마나 덜 고를지 (1 = 그대로, 0.5 = 두 배 비싸게, 0 = 아예 안 감)
- speed: 걷는 속도 배수 (예상 소요 시간에 반영)
- average_slope: 도로 구간의 평균 경사(%). 오르막·내리막 모두 부담이라 양쪽을 본다.
  고도 데이터가 구간 경사를 정하므로 국토지리정보원 DEM이면 더 정확하다 (graphhopper/build_dem.sh).
숫자는 시작값이다. 시연 전 실제 경로를 보며 조정한다.
"""

from __future__ import annotations

from typing import Any

PROFILE_RULES: dict[str, dict[str, list[dict[str, Any]]]] = {
    # 건강한 성인: 도보 기본 모델 그대로 (가장 빠른 길)
    "adult": {"priority": [], "speed": []},

    # 노약자: 걸음이 느리고 급경사·계단이 부담. 경사로 기준(휠체어 8%)보다 조금 느슨하게 둔다.
    "elderly": {
        "priority": [
            {"if": "road_class == STEPS", "multiply_by": "0.3"},
            {"if": "average_slope >= 10 || average_slope <= -10", "multiply_by": "0.2"},
            {"else_if": "average_slope >= 6 || average_slope <= -6", "multiply_by": "0.5"},
        ],
        "speed": [{"if": "true", "multiply_by": "0.75"}],   # 보행 약 5km/h → 약 3.8km/h
    },

    # 휠체어: 계단은 못 간다. 경사로 기준(1/12 ≈ 8%)을 넘는 길은 거의 피하고, 5% 넘는 길도 되도록 피한다.
    # 산길(PATH·TRACK)은 노면이 고르지 않아 피한다.
    "wheelchair": {
        "priority": [
            {"if": "road_class == STEPS", "multiply_by": "0"},
            {"if": "road_class == PATH || road_class == TRACK", "multiply_by": "0.1"},
            {"if": "average_slope >= 8 || average_slope <= -8", "multiply_by": "0.05"},
            {"else_if": "average_slope >= 5 || average_slope <= -5", "multiply_by": "0.3"},
        ],
        "speed": [{"if": "true", "multiply_by": "0.7"}],    # 약 3.5km/h
    },
}
