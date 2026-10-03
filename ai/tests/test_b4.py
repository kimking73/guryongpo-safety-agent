"""B4: 산사태·강풍태풍·생활안전 agent, 재난 단계 판정, 원문 기반 행동 권고 (DB·LLM 없이 실행)."""

from datetime import datetime, timedelta, timezone

from guardian_ai import action as A
from guardian_ai import graph as G
from guardian_ai import specialists as SP
from guardian_ai.service import ChatRequest, ChatService
from guardian_ai.state import (CheckResult, Location, Mobility, Phase, RiskLevel, Specialist, SpecialistResult,
                               UserProfile)
from guardian_ai.verify import make_hallucination_check

KST = timezone(timedelta(hours=9))
NOW = datetime.now(KST)
HERE = Location(lat=35.9907, lon=129.5526, label="현재 위치")


def risk_row(hazard, level, reason, distance=0.0):
    return {"id": 1, "hazard": hazard, "level": level, "label": f"{hazard} {level}", "rule_id": 1,
            "basis": {"reason": reason, "observed_at": NOW.isoformat()}, "computed_at": NOW, "distance_m": distance}


def obs(station, metric, value, unit, kind="weather", minutes=5):
    return {"station_id": 1, "station_name": station, "station_kind": kind, "metric": metric, "value": value, "unit": unit,
            "source_level": None, "observed_at": NOW - timedelta(minutes=minutes), "distance_m": 900.0}


GUIDES = [
    {"id": 11, "disaster": "typhoon", "phase": "during", "min_level": "advisory", "targets": ["all"], "priority": 10,
     "title": "태풍이 시작되면", "content": "이웃과 함께 신속히 안전한 곳으로 대피하고 외출을 삼갑니다.", "voice_text": None,
     "source_name": "포항시", "source_url": None},
    {"id": 12, "disaster": "typhoon", "phase": "during", "min_level": "advisory", "targets": ["fisher", "vessel_owner", "coastal"],
     "priority": 15, "title": "태풍주의보 발령 시 (해안지역)", "content": "해안저지대 주민은 경계를 강화하고 안전지대로 대피합니다.",
     "voice_text": None, "source_name": "포항시", "source_url": None},
    {"id": 13, "disaster": "typhoon", "phase": "before", "min_level": "watch", "targets": ["all"], "priority": 10,
     "title": "태풍이 예보되면", "content": "어떻게 대피할지 가족·주변 사람과 함께 준비합니다.", "voice_text": None,
     "source_name": "포항시", "source_url": None},
    {"id": 21, "disaster": "landslide", "phase": "during", "min_level": "watch", "targets": ["all"], "priority": 15,
     "title": "호우·태풍이 올 때 (산사태)", "content": "경사도가 30° 이상인 곳은 미리 안전한 곳으로 대피합니다.", "voice_text": None,
     "source_name": "포항시", "source_url": None},
]
LEVELS = ["normal", "watch", "advisory", "warning", "critical"]


class FakeDB:
    """SQL 문자열로 어떤 조회인지 구분하는 가짜 DB. 시나리오별로 값만 바꾼다."""

    def __init__(self, risk=(), zones=(), observations=(), warnings=(), guides=GUIDES, down=False, hazard_labels=None):
        self.risk, self.zones, self.observations, self.warnings, self.guides, self.down = \
            list(risk), list(zones), list(observations), list(warnings), list(guides), down
        self.hazard_labels = hazard_labels      # 사용자 위치가 들어 있는 위험 영역 (hazards_at)
        self.guide_calls = []

    def __call__(self, sql, params):
        if self.down:
            raise ConnectionError("DB 꺼짐")
        if "FROM action_guides" in sql:
            self.guide_calls.append(params)
            level = LEVELS.index(params["level"])
            return [g for g in self.guides if g["disaster"] == params["hazard"] and g["phase"] == params["phase"]
                    and LEVELS.index(g["min_level"]) <= level and set(g["targets"]) & set(params["targets"])]
        if "AS labels" in sql:
            return [{"labels": self.hazard_labels}]
        if "FROM hazard_zones" in sql:
            return self.zones
        if "FROM weather_warnings" in sql:
            return self.warnings
        if "ingest_runs" in sql:
            return [{"t": NOW - timedelta(minutes=3)}]
        if "FROM observations" in sql:
            return [o for o in self.observations if o["metric"] in params["metrics"]]
        if "risk_assessments" in sql:
            return self.risk
        return []


def warning(hazard, level, headline, released=None, issued_hours=1):
    return {"hazard": hazard, "level": level, "region_name": "포항시", "issued_at": NOW - timedelta(hours=issued_hours),
            "effective_at": NOW, "released_at": released, "headline": headline}


def state(question="태풍 오면 어떻게 해?", **user):
    return {"mode": "chat", "question": question, "current_location": HERE,
            "user": UserProfile(user_id="u1", **user), "phase": Phase.DURING}


# --- 재난 agent 3종 -------------------------------------------------------------------

def test_landslide_inside_zone_with_engine_level_and_rain():
    db = FakeDB(risk=[risk_row("landslide", "warning", "호우경보 중 산사태 취약지역")],
                zones=[{"id": 7, "hazard": "landslide", "name": "구룡포리 산 12", "grade": "1등급", "contains_point": True, "distance_m": 0.0}],
                observations=[obs("구룡포 AWS", "rain_1h", 42.5, "mm")])
    out = SP.make_landslide_agent(fetch=db)(state("산사태 위험 있어?"))["specialist_results"][0]
    ev = {e.key: e.value for e in out.evidence}
    assert out.agent == Specialist.LANDSLIDE and out.risk_level == RiskLevel.WARNING
    assert ev["산사태 위험 단계"] == "경보" and "취약지역 안 (구룡포리 산 12, 1등급)" in ev["산사태 취약지역"]
    assert ev["구룡포 AWS 1시간 강수량"] == 42.5
    assert "'경보'" in out.summary and "취약지역 안" in out.summary and "42.5mm" in out.summary


def test_landslide_normal_reports_nearest_zone_distance():
    db = FakeDB(zones=[{"id": 8, "hazard": "landslide", "name": "병포리", "grade": None, "contains_point": False, "distance_m": 420.4}])
    out = SP.make_landslide_agent(fetch=db)(state("산사태 위험 있어?"))["specialist_results"][0]
    assert out.risk_level == RiskLevel.NORMAL
    assert {e.key: e.value for e in out.evidence}["가장 가까운 산사태 취약지역까지 거리"] == 420


def test_landslide_says_normal_when_only_heavy_rain_is_judged():
    db = FakeDB(risk=[risk_row("heavy_rain", "warning", "강우 경보")])
    ev = {e.key: e.value for e in SP.collect_landslide(state("산사태?"), fetch=db).evidence}
    assert ev["산사태 위험 단계"] == "정상" and ev["호우 위험 단계"] == "경보"


def test_wind_typhoon_uses_engine_warnings_and_wind():
    db = FakeDB(risk=[risk_row("typhoon", "advisory", "제14호 태풍 강풍반경(15m/s) 안 · 구룡포 중심 거리 210km")],
                observations=[obs("구룡포 AWS", "wind_speed", 12.3, "m/s"), obs("구룡포 AWS", "wind_gust", 21.0, "m/s")],
                warnings=[warning("typhoon", "advisory", "포항시 태풍주의보")])
    out = SP.make_wind_typhoon_agent(fetch=db)(state())["specialist_results"][0]
    ev = {e.key: e.value for e in out.evidence}
    assert out.risk_level == RiskLevel.ADVISORY
    assert ev["태풍 위험 단계"] == "주의" and "210km" in ev["태풍 판정 근거"]
    assert ev["구룡포 AWS 풍속"] == 12.3 and ev["포항시 특보"] == "포항시 태풍주의보 (발효 중)"
    assert "12.3m/s" in out.summary


def test_fisher_gets_high_seas_first():
    db = FakeDB(risk=[risk_row("typhoon", "advisory", "태풍"), risk_row("high_seas", "warning", "풍랑경보")])
    d = SP.collect_wind_typhoon(state(occupation="어업(선박 보유)"), fetch=db)
    assert d.facts["items"][0] == ("풍랑", "경보") and d.level == RiskLevel.WARNING


def test_life_safety_uv_grade_and_dust_unavailable():
    db = FakeDB(observations=[obs("구룡포 자외선", "uv_index", 7.0, None, kind="uv")])
    out = SP.make_life_safety_agent(fetch=db)(state("오늘 자외선 어때?"))["specialist_results"][0]
    ev = {e.key: e.value for e in out.evidence}
    assert ev["자외선 등급"] == "높음" and out.risk_level == RiskLevel.ADVISORY
    assert "미세먼지(아직 수집하지 않음)" in out.summary
    assert "미세먼지(아직 수집하지 않음)" in ev["확인할 수 없는 정보"]          # 검증기도 보도록 근거에


def test_db_down_and_writer_failure_fall_back_to_template():
    def broken(*a):
        raise TimeoutError
    out = SP.make_wind_typhoon_agent(writer=broken, fetch=FakeDB(down=True))(state())["specialist_results"][0]
    assert "지금 확인할 수 없는 정보" in out.summary and "위험 판정" in out.summary


def test_writer_gets_evidence_and_feedback():
    seen = {}

    def writer(question, evidence, data, feedback):
        seen.update(question=question, evidence=evidence, feedback=feedback)
        return "LLM 문장"
    db = FakeDB(risk=[risk_row("landslide", "advisory", "산사태 주의")])
    out = SP.make_landslide_agent(writer=writer, fetch=db)({**state("산사태?"), "manager_feedback": "[hallucination] x"})
    assert out["specialist_results"][0].summary == "LLM 문장"
    assert "산사태 위험 단계: 주의" in seen["evidence"] and seen["feedback"] == "[hallucination] x"


# --- 재난 단계 ---------------------------------------------------------------------

def test_phase_rules():
    assert A.decide_phase(state(), fetch=FakeDB(warnings=[warning("typhoon", "advisory", "태풍주의보")])) == Phase.DURING
    assert A.decide_phase(state(), fetch=FakeDB(risk=[risk_row("flood", "advisory", "침수 주의")])) == Phase.DURING
    assert A.decide_phase(state(), fetch=FakeDB(warnings=[warning("typhoon", "watch", "태풍 예비특보")])) == Phase.BEFORE
    assert A.decide_phase(state(), fetch=FakeDB(warnings=[warning("typhoon", "advisory", "해제", released=NOW - timedelta(hours=3))])) == Phase.AFTER
    assert A.decide_phase(state(), fetch=FakeDB()) == Phase.NONE
    assert A.decide_phase(state(), fetch=FakeDB(risk=[risk_row("uv", "warning", "자외선 매우높음")])) == Phase.NONE   # 생활안전은 재난 아님
    assert A.decide_phase(state(), fetch=FakeDB(down=True)) == Phase.DURING                                          # 안전 쪽


def test_manager_puts_phase_and_survives_phase_failure():
    m = G.make_manager(G.keyword_classify, phase_of=lambda s: Phase.BEFORE)
    assert m(state("태풍?"))["phase"] == Phase.BEFORE

    def boom(s):
        raise RuntimeError
    assert G.make_manager(G.keyword_classify, phase_of=boom)(state("태풍?"))["phase"] == Phase.DURING


# --- 행동 권고 ---------------------------------------------------------------------

def result(agent, level, summary="요약", route=None):
    return SpecialistResult(agent=agent, summary=summary, risk_level=level, route=route)


def advisor_state(results, phase=Phase.DURING, **user):
    return {**state(), "phase": phase, "user": UserProfile(user_id="u1", **user), "specialist_results": results}


def test_targets():
    assert A.targets_for(UserProfile(user_id="u", user_type="tourist")) == ["tourist"]
    assert A.targets_for(UserProfile(user_id="u", occupation="어업(선박 보유)", mobility=Mobility.CAR)) == \
        ["resident", "fisher", "vessel_owner", "coastal", "driver"]


def test_picks_highest_disaster_and_target_specific_guides_first():
    db = FakeDB()
    main, guides = A.pick_guides([result(Specialist.LANDSLIDE, RiskLevel.WATCH), result(Specialist.WIND_TYPHOON, RiskLevel.ADVISORY)],
                                 Phase.DURING, UserProfile(user_id="u", occupation="어업"), fetch=db)
    assert main.agent == Specialist.WIND_TYPHOON
    assert [g["id"] for g in guides] == [12, 11]          # 어업인 대상 원문 먼저
    assert "fisher" in db.guide_calls[0]["targets"]


def test_calm_question_uses_before_guides():
    _, guides = A.pick_guides([result(Specialist.WIND_TYPHOON, RiskLevel.NORMAL)], Phase.NONE, None, fetch=FakeDB())
    assert [g["id"] for g in guides] == [13]


def test_template_steps_quote_guides_verbatim_and_evidence_carries_them():
    out = A.make_action_advisor(fetch=FakeDB())(advisor_state([result(Specialist.WIND_TYPHOON, RiskLevel.ADVISORY, "태풍 주의")]))
    plan = out["action_plan"]
    assert plan.guide_ids == [11] and "지금 할 일:\n1. 태풍이 시작되면: 이웃과 함께" in out["draft"]
    assert any(e.source == "action_guides" for e in plan.evidence)


def test_writer_personalizes_from_guides():
    seen = {}

    def writer(question, situation, guides, feedback):
        seen.update(situation=situation, guides=guides)
        return ["바로 안전한 곳으로 대피하세요."]
    out = A.make_action_advisor(writer=writer, fetch=FakeDB())(
        advisor_state([result(Specialist.WIND_TYPHOON, RiskLevel.ADVISORY)], age=72, walking_impaired=True))
    assert out["action_plan"].steps == ["바로 안전한 곳으로 대피하세요."]
    assert "72세" in seen["situation"] and "보행 불편" in seen["situation"] and "태풍이 시작되면" in seen["guides"]


# --- 판단 로직 분기 (사용자 정의 트리) -------------------------------------------------

def tree_state(phase, can_move="unknown", damage="unknown", **user):
    return {**state(), "phase": phase, "can_move": can_move, "damage": damage, "user": UserProfile(user_id="u1", **user)}


def test_before_asks_dependents_then_checklist():
    d = A.decide(tree_state(Phase.BEFORE), fetch=FakeDB())
    assert d.path == ["재난 전", "사용자 정보 확인"] and d.question == A.QUESTIONS["dependents"]
    assert A.decide(tree_state(Phase.NONE, has_dependents=False), fetch=FakeDB()).path == ["평시(대비)", "체크리스트"]


def test_during_safe_when_outside_hazard_areas():
    d = A.decide(tree_state(Phase.DURING), fetch=FakeDB(hazard_labels=None))
    assert d.path == ["재난 중", "안전"] and not d.need_route


def test_during_danger_healthy_user_can_move_gets_route():
    d = A.decide(tree_state(Phase.DURING, age=30), fetch=FakeDB(hazard_labels="침수 경보"))
    assert d.path == ["재난 중", "위험 지역", "이동 가능"] and d.need_route and not d.question


def test_during_danger_unknown_mobility_asks_one_question_but_still_guides():
    d = A.decide(tree_state(Phase.DURING, age=80, walking_impaired=True), fetch=FakeDB(hazard_labels="침수 경보"))
    assert d.path[-1] == "이동 가능 여부 확인" and d.question == A.QUESTIONS["can_move"] and d.need_route


def test_during_danger_cannot_move_is_119():
    d = A.decide(tree_state(Phase.DURING, can_move="no"), fetch=FakeDB(hazard_labels="침수 경보"))
    assert d.path == ["재난 중", "위험 지역", "이동 불가능"] and d.emergency


def test_hazard_check_unavailable_counts_as_danger():
    d = A.decide(tree_state(Phase.DURING, age=30), fetch=FakeDB(down=True))
    assert d.path[:2] == ["재난 중", "위험 지역"]


def test_after_damage_branches():
    assert A.decide(tree_state(Phase.AFTER), fetch=FakeDB()).question == A.QUESTIONS["damage"]
    assert A.decide(tree_state(Phase.AFTER, damage="no"), fetch=FakeDB()).path == ["재난 후", "피해 없음"]
    d = A.decide(tree_state(Phase.AFTER, damage="yes"), fetch=FakeDB())
    assert d.path == ["재난 후", "피해 존재"] and {n.key for n in d.notes} >= {"통제 도로", "보험·법률 정보"}


def test_cannot_move_puts_119_first_in_answer():
    out = A.make_action_advisor(fetch=FakeDB(hazard_labels="침수 경보"))(
        {**tree_state(Phase.DURING, can_move="no"), "specialist_results": [result(Specialist.RAIN_FLOOD, RiskLevel.WARNING, "침수 경보")]})
    assert out["draft"].startswith(A.EMERGENCY_STEP) and out["action_plan"].call_emergency
    assert out["action_plan"].decision_path == ["재난 중", "위험 지역", "이동 불가능"]


def test_can_move_branch_uses_location_route_and_asks_when_unknown():
    route = {"destination": {"name": "충혼탑 앞", "lat": 35.99, "lon": 129.56, "kind": "shelter"}, "distance_m": 902,
             "duration_s": 650, "still_inside": [], "geometry": "abc", "profile": "adult"}
    out = A.make_action_advisor(fetch=FakeDB(hazard_labels="침수 경보"))(
        {**tree_state(Phase.DURING, age=80, walking_impaired=True),
         "specialist_results": [result(Specialist.RAIN_FLOOD, RiskLevel.WARNING, "침수 경보"),
                                result(Specialist.LOCATION_ROUTE, RiskLevel.NORMAL, "경로", route=route)]})
    assert "충혼탑 앞(으)로 대피하세요. 902m, 도보 약 11분" in out["draft"]
    assert out["draft"].endswith("확인할게요: " + A.QUESTIONS["can_move"])


def test_chat_response_exposes_path_follow_up_and_emergency():
    svc = ChatService(classifier=G.keyword_classify, overrides={
        Specialist.RAIN_FLOOD.value: lambda s: {"specialist_results": [result(Specialist.RAIN_FLOOD, RiskLevel.WARNING, "침수 경보")]},
        G.ACTION_ADVISOR: A.make_action_advisor(fetch=FakeDB(hazard_labels="침수 경보"))})
    res = svc.chat(ChatRequest(user_id="u1", question="비 와요, 집에 갇혔어요", current_location=HERE))
    assert res.decision_path == "재난 중 > 위험 지역 > 이동 불가능" and res.call_emergency and res.follow_up is None


def test_keyword_situation_fallback():
    assert G.keyword_situation("물이 들어와서 못 나가요") == ("no", "yes")
    assert G.keyword_situation("피해는 없어요") == ("unknown", "no")


def test_no_guides_means_no_todo_list():
    out = A.make_action_advisor(fetch=FakeDB(guides=[]))(advisor_state([result(Specialist.LIFE_SAFETY, RiskLevel.ADVISORY, "자외선 높음")]))
    assert out["draft"] == "자외선 높음" and out["action_plan"].steps == []


def test_invented_action_is_caught_then_rewritten():
    """원문에 없는 행동('창문에 테이프')을 쓰면 내용 검사가 걸러 다시 쓰게 한다 (가짜 checker)."""
    answers = iter([["창문에 X자로 테이프를 붙이세요."], ["이웃과 함께 안전한 곳으로 대피하세요."]])

    def checker(draft, evidence):
        return CheckResult(ok="테이프" not in draft, feedback="원문에 없는 행동: 테이프")
    svc = ChatService(classifier=G.keyword_classify, overrides={
        Specialist.WIND_TYPHOON.value: SP.make_wind_typhoon_agent(fetch=FakeDB(risk=[risk_row("typhoon", "advisory", "태풍")])),
        G.ACTION_ADVISOR: A.make_action_advisor(writer=lambda *a: next(answers), fetch=FakeDB()),
        G.HALLUCINATION_CHECK: make_hallucination_check(checker=checker)})
    res = svc.chat(ChatRequest(user_id="u1", question="태풍 오면 어떡해?", current_location=HERE))
    assert "대피하세요" in res.answer and "테이프" not in res.answer and not res.used_fallback


def test_tourist_place_specific_guide_is_not_put_first():
    beach = {**GUIDES[0], "id": 14, "priority": 15, "targets": ["tourist"], "title": "호우·태풍이 올 때 (해수욕장·낚시터·야영장)"}
    _, guides = A.pick_guides([result(Specialist.WIND_TYPHOON, RiskLevel.ADVISORY)], Phase.DURING,
                              UserProfile(user_id="u", user_type="tourist"), fetch=FakeDB(guides=[GUIDES[0], beach]))
    assert [g["id"] for g in guides] == [11, 14]          # 우선순위대로 (관광객 장소별 원문을 앞에 두지 않음)


def test_forecast_evidence_names_today_and_tomorrow():
    from guardian_ai.flood import forecast_evidence
    tomorrow = (NOW + timedelta(days=1)).strftime("%m-%d")
    ev = forecast_evidence({"available": True, "periods": [{"date": tomorrow, "max_pop": 60, "rain_types": ["비"], "rain_hours": 5,
                                                            "max_rain": "2.0mm", "max_wind": 5.4, "max_wave": 0.5}]})
    keys = {e.key: e.value for e in ev}
    assert keys[f"내일({tomorrow}) 예보 최고 강수확률"] == 60 and keys[f"내일({tomorrow}) 예보 강수"] == "비 5시간, 1시간 최대 2.0mm"


def test_calm_info_question_gets_no_action_list_or_question():
    out = A.make_action_advisor(fetch=FakeDB())(
        {**tree_state(Phase.NONE), "question": "내일 비 와?", "specialist_results": [result(Specialist.RAIN_FLOOD, RiskLevel.NORMAL, "내일 비 예보")]})
    assert out["draft"] == "내일 비 예보" and out["action_plan"].decision_path == ["평시", "정보 안내"]
