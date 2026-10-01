"""사용자 유형(profile)별 경로 규칙 (B7). GraphHopper custom_model 문장으로 쓴다.

유형은 성인·노약자 두 가지다 (휠체어는 제외, 사용자 결정 2026-09-26).
- priority: 그 길을 얼마나 덜 고를지 (1 = 그대로, 0.5 = 두 배 비싸게, 0 = 아예 안 감). 여러 줄이 맞으면 곱해진다.
- speed: 걷는 속도 배수 (예상 소요 시간에 반영)
- average_slope: 도로 구간의 평균 경사(%). 오르막·내리막 모두 부담이라 양쪽을 본다.
경사 기준선은 공식 자료를 따른다 (2026-10-02, 아래 SLOPE_* 주석). 배수(×0.5·×0.2·속도 ×0.75·계단 ×0.5)는 아직 시작값이며
근거 조사 중이다. 5m DEM을 받으면 실제 경로를 보며 조정한다.
"""

from __future__ import annotations

from typing import Any

# 노약자 배수. 구간 비용(GraphHopper) = 걸리는 초 ÷ 선호도, 선호도 = 기본 선호도(foot_priority) × 아래 배수.
# "같은 경사면 계단 선호"가 되려면 계단 1m 비용 < 급경사(1/12 초과) 도로 1m 비용이어야 한다.
# 그런데 기본 도보 모델은 계단을 3km/h, 도로를 5km/h로 계산해 계단이 원래 5/3배 느리다. 기본 선호도는 계단 1.2,
# 도로 0.8~1.2(구룡포 실측: service·residential 1.2, unclassified·cycleway 1.0, secondary 0.8). 따라서
#   계단 배수 > 급경사 배수 × (5/3) × (도로 선호도 ÷ 계단 선호도) = 0.2 × 5/3 × 1.2/1.2 ≈ 0.33
# 여유를 두어 0.5로 한다 (도로 선호도가 1.5까지 올라가도 성립). 1/18~1/12 도로(×0.5)보다는 비싸므로
# 완만한 길이 있으면 그 길이 먼저다. tests/test_profiles_check.py가 이 부등식을 검사한다.
ELDERLY_STEPS = 0.5
ELDERLY_OVER_ACCESSIBLE = 0.2     # 교통약자 한계(1/12) 초과 도로
ELDERLY_OVER_SIDEWALK = 0.5      # 보도 권장(1/18) 초과 도로

# 경사 기준선 (%). 출처: 국토해양부 「보도 설치 및 관리 지침」(2011.07)
#   - "보도의 종단경사는 18분의 1 이하가 되도록 한다. 단, 지형 상 곤란한 경우에는 12분의 1까지 완화할 수 있으나,
#      이 경우에는 30m마다 휴식 참을 설치해야 한다."
#   - "교통약자가 통행할 수 있는 보도의 최대 기울기로 종단경사 1/12(8%)" (교통약자이동편의증진법 기준 인용),
#     "기존 보도의 종단선형경사가 1/12을 초과하는 불량한 곳" → 낙상 방지 안전시설 검토
# GraphHopper average_slope는 정수(%)로 저장되므로 실제로는 1/18 초과 = 6% 이상, 1/12 초과 = 9% 이상과 같다.
SLOPE_SIDEWALK_MAX = round(100 / 18, 2)   # 5.56 — 보도 종단경사 권장 상한 (1/18)
SLOPE_ACCESSIBLE_MAX = round(100 / 12, 2)  # 8.33 — 교통약자 통행 가능 최대 (1/12)

PROFILE_RULES: dict[str, dict[str, list[dict[str, Any]]]] = {
    # 성인: 경사를 반영하지 않는다 (사용자 결정). 도보 기본 모델 그대로 = 가장 빠른 길.
    "adult": {"priority": [], "speed": []},

    # 노약자: 걸음이 느리고 급경사가 부담. 같은 경사라면 비탈길보다 계단을 선호한다 (손잡이·단이 있어 덜 미끄럽다).
    # 그래서 경사 벌점은 계단이 아닌 도로에만 주고, 계단은 ELDERLY_STEPS 하나만 받는다.
    # 계단은 대개 1/12(8.3%)보다 훨씬 가파르므로 비교 대상은 1/12 초과 도로(×0.2)이고, 기본 속도 차이를 감안해도 계단이 싸다(위 설명).
    "elderly": {
        "priority": [
            {"if": "road_class == STEPS", "multiply_by": str(ELDERLY_STEPS)},
            {"else_if": f"average_slope > {SLOPE_ACCESSIBLE_MAX} || average_slope < -{SLOPE_ACCESSIBLE_MAX}",
             "multiply_by": str(ELDERLY_OVER_ACCESSIBLE)},
            {"else_if": f"average_slope > {SLOPE_SIDEWALK_MAX} || average_slope < -{SLOPE_SIDEWALK_MAX}",
             "multiply_by": str(ELDERLY_OVER_SIDEWALK)},
        ],
        "speed": [{"if": "true", "multiply_by": "0.75"}],   # 보행 약 5km/h → 약 3.8km/h
    },
}
