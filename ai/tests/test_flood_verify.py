"""B3: 강수·침수 agent + 환각 검증. 완료 기준 — 틀린 답을 넣으면 검증에서 걸러진다 (DB·LLM 없이 실행)."""

from datetime import datetime, timedelta, timezone

import pytest

from guardian_ai import flood as F
from guardian_ai import graph as G
from guardian_ai.service import ChatRequest, ChatService
from guardian_ai.state import CheckResult, Evidence, Location, RiskLevel, Specialist, UserProfile
from guardian_ai.verify import check_numbers, extract_measures, make_hallucination_check

KST = timezone(timedelta(hours=9))
NOW = datetime.now(KST)
HOME = Location(lat=35.9905, lon=129.5560, label="집")


def heavy_rain_db(sql, params):
    """가짜 DB: 구룡포수협 지표면 수위계 침수심 160mm → 침수 경보, 호우주의보 발효, 1시간 강수량 42.5mm."""
    if "risk_assessments" in sql:
        return [{"id": 1, "hazard": "flood", "level": "warning", "label": "침수 경보", "rule_id": 9,
                 "basis": {"reason": "구룡포수협 지표면 수위계 침수심 160mm (기준 150mm)", "metric": "flood_depth",
                           "value": 160, "unit": "mm", "observed_at": NOW.isoformat()},
                 "computed_at": NOW, "distance_m": 0.0}]
    if "ingest_runs" in sql:
        return [{"t": NOW - timedelta(minutes=3)}]
    if "FROM observations" in sql and "flood_depth" in params["metrics"]:
        return [{"station_id": 10, "station_name": "구룡포수협_지표면 수위계", "station_kind": "road_flood",
                 "metric": "flood_depth", "value": 160.0, "unit": "mm", "source_level": 4,
                 "observed_at": NOW - timedelta(minutes=8), "distance_m": 140.2}]
    if "FROM observations" in sql:
        return [{"station_id": 22, "station_name": "구룡포 AWS", "station_kind": "weather", "metric": "rain_1h",
                 "value": 42.5, "unit": "mm", "source_level": None, "observed_at": NOW - timedelta(minutes=2),
                 "distance_m": 1123.0}]
    if "weather_warnings" in sql:
        return [{"hazard": "heavy_rain", "level": "advisory", "region_name": "포항시", "issued_at": NOW,
                 "effective_at": NOW, "released_at": None, "headline": "포항시 호우주의보"}]
    if "shelters" in sql:
        return [{"id": 3, "name": "구룡포초등학교", "shelter_types": ["tsunami"], "address": "구룡포읍",
                 "capacity": 300, "phone": None, "is_indoor": True, "is_accessible": None,
                 "lat": 35.99, "lon": 129.55, "distance_m": 420.4}]
    return []


def down_db(sql, params):
    raise ConnectionError("DB 꺼짐")


def flood_state(question="지금 침수 위험 있어요?"):
    return {"mode": "chat", "question": question, "user": UserProfile(user_id="u1", home=HOME)}


def evidence():
    return F.collect(HOME, True, fetch=heavy_rain_db).evidence


# --- 침수 agent -------------------------------------------------------------

def test_flood_agent_uses_engine_level_and_records_every_number_as_evidence():
    out = F.make_rain_flood_agent(fetch=heavy_rain_db)(flood_state())
    r = out["specialist_results"][0]
    assert r.agent == Specialist.RAIN_FLOOD and r.risk_level == RiskLevel.WARNING
    keys = {e.key: e.value for e in r.evidence}
    assert keys["구룡포수협 지표면 수위계 침수심"] == 160.0
    assert keys["구룡포 AWS 1시간 강수량"] == 42.5
    assert keys["가까운 대피소"] == "구룡포초등학교"           # 주의 이상 → 대피소
    assert keys["기준 위치"] == "집"                         # 검증기도 기준 위치를 알아야 "집" 언급이 오탐되지 않는다
    # 템플릿 답변(LLM 없음)도 근거 숫자만 쓰므로 숫자 검사를 통과한다
    assert "160mm" in r.summary and check_numbers(r.summary, r.evidence).ok


def test_flood_agent_without_location_says_reference_point():
    out = F.make_rain_flood_agent(fetch=heavy_rain_db)({"mode": "chat", "question": "비 와요?",
                                                       "user": UserProfile(user_id="u1")})
    assert "구룡포읍 중심(위치 정보 없음)" in out["specialist_results"][0].summary


def test_flood_agent_db_down_does_not_claim_safe():
    out = F.make_rain_flood_agent(fetch=down_db)(flood_state())
    summary = out["specialist_results"][0].summary
    assert "확인할 수 없는 정보" in summary and "안전" not in summary


def test_flood_agent_writer_failure_falls_back_to_template():
    def broken_writer(*a):
        raise TimeoutError("LLM 응답 없음")
    out = F.make_rain_flood_agent(writer=broken_writer, fetch=heavy_rain_db)(flood_state())
    assert "160mm" in out["specialist_results"][0].summary


def test_writer_receives_retry_feedback():
    seen = {}

    def writer(question, ev, data, feedback):
        seen["feedback"] = feedback
        return "구룡포수협 지표면 수위계 침수심은 160mm입니다."
    F.make_rain_flood_agent(writer=writer, fetch=heavy_rain_db)({**flood_state(), "manager_feedback": "[hallucination] 300mm"})
    assert "300mm" in seen["feedback"]


# --- 숫자 검사 --------------------------------------------------------------

@pytest.mark.parametrize("draft", [
    "구룡포수협 지표면 수위계 침수심은 160mm입니다.",
    "침수심이 16cm로 기준 150mm를 넘었습니다.",               # 단위 변환
    "침수심 0.16m, 1시간 강수량 42.5mm.",
    "1시간에 43mm 가까운 비가 왔습니다.",                      # 반올림 허용 (42.5 → 43)
    "가까운 대피소는 구룡포초등학교(420m)입니다.",
    "지금 바로 119에 연락하세요. 12시간 뒤 다시 확인하세요.",   # 단위 없는 숫자는 숫자 검사 대상 아님
])
def test_numbers_supported_by_evidence_pass(draft):
    assert check_numbers(draft, evidence()).ok, draft


@pytest.mark.parametrize("draft, bad", [
    ("구룡포수협 지표면 수위계 침수심은 300mm입니다.", "300mm"),        # 틀린 값
    ("침수심이 30cm입니다.", "30cm"),                                  # 단위를 바꿔도 틀린 값
    ("1시간 강수량은 80mm로 매우 많습니다.", "80mm"),
    ("풍속 25m/s의 강풍이 붑니다.", "25m/s"),                           # 근거에 없는 종류의 수치
    ("대피소까지 2km입니다.", "2km"),
])
def test_wrong_numbers_are_caught(draft, bad):
    result = check_numbers(draft, evidence())
    assert not result.ok and bad in result.feedback


def test_extract_ignores_angles_and_counts():
    assert extract_measures("경사 30도, 대피소 3곳, 2시간") == []
    assert [m.text for m in extract_measures("기온 30도, 1,200m")] == ["30도", "1,200m"]


# --- 내용 검사 연결 ---------------------------------------------------------

def test_content_checker_runs_only_after_numbers_pass_and_its_failure_is_reported():
    calls = []

    def checker(draft, ev):
        calls.append(draft)
        return CheckResult(ok=False, feedback="근거와 다른 내용: 호우주의보를 호우경보로 말함")
    node = make_hallucination_check(checker)
    ev_result = F.make_rain_flood_agent(fetch=heavy_rain_db)(flood_state())["specialist_results"]

    wrong_number = node({"draft": "침수심 300mm", "specialist_results": ev_result})
    assert not wrong_number["checks"]["hallucination"].ok and calls == []   # 숫자에서 먼저 걸리면 LLM 안 부름
    wrong_claim = node({"draft": "포항시에 호우경보가 발효 중입니다.", "specialist_results": ev_result})
    assert "호우경보" in wrong_claim["checks"]["hallucination"].feedback


def test_content_checker_failure_keeps_number_result():
    def broken(draft, ev):
        raise TimeoutError
    ev_result = F.make_rain_flood_agent(fetch=heavy_rain_db)(flood_state())["specialist_results"]
    out = make_hallucination_check(broken)({"draft": "침수심 160mm", "specialist_results": ev_result})
    assert out["checks"]["hallucination"].ok


# --- 전체 흐름: 틀린 답 → 재시도 → 통과 / 계속 틀리면 안전 안내 --------------------

def service_with(writer):
    return ChatService(classifier=G.keyword_classify, overrides={
        Specialist.RAIN_FLOOD.value: F.make_rain_flood_agent(writer=writer, fetch=heavy_rain_db)})


def test_wrong_first_answer_is_rewritten_after_feedback():
    answers = iter(["침수심이 300mm로 매우 위험합니다.", "구룡포수협 지표면 수위계 침수심은 160mm입니다."])
    feedbacks = []

    def writer(question, ev, data, feedback):
        feedbacks.append(feedback)
        return next(answers)
    res = service_with(writer).chat(ChatRequest(user_id="u1", question="침수 위험 있어요?", profile=UserProfile(user_id="u1", home=HOME)))
    assert "160mm" in res.answer and "300mm" not in res.answer and not res.used_fallback
    assert feedbacks[0] == "" and "300mm" in feedbacks[1]


def test_always_wrong_answer_ends_in_safe_fallback():
    res = service_with(lambda *a: "침수심이 999mm입니다.").chat(
        ChatRequest(user_id="u1", question="침수 위험 있어요?", profile=UserProfile(user_id="u1", home=HOME)))
    assert res.used_fallback and "999mm" not in res.answer and "119" in res.answer


def test_evidence_unit_parsing_from_reason_text():
    ev = [Evidence(source="risk_assessments", key="판정 근거", value="침수심 160mm (기준 150mm)")]
    assert check_numbers("기준 150mm", ev).ok and not check_numbers("기준 200mm", ev).ok
