"""지원·복구 안내 agent (recovery.py, 2026-10-08) — DB(support_programs 9건)를 가짜 fetch로."""

import pytest

from guardian_ai import graph as G
from guardian_ai import tools as T
from guardian_ai.recovery import (collect_recovery, hazard_of, job_targets, make_recovery_support_agent,
                                  recovery_template)
from guardian_ai.service import ChatRequest, ChatService
from guardian_ai.state import Phase, Specialist, UserProfile

ALL = ["typhoon", "heavy_rain", "flood", "strong_wind", "high_seas", "landslide"]
PROGRAMS = [   # db/init/04_seed_knowledge.sql 의 9건 (요약은 줄임)
    {"category": "insurance", "hazards": ["typhoon", "heavy_rain", "flood", "strong_wind", "high_seas"], "targets": ["resident"],
     "name": "풍수해·지진재해보험", "summary": "보험료의 55% 이상을 정부·지자체가 지원. 주택 침수 시 보험금 최대 1,070만원."},
    {"category": "fishery", "hazards": ["typhoon", "strong_wind", "high_seas"], "targets": ["fisher"],
     "name": "양식수산물재해보험", "summary": "양식수산물·시설물 피해 보상.", "contact": "Sh수협은행 1588-4119"},
    {"category": "insurance", "hazards": ["typhoon", "heavy_rain", "strong_wind"], "targets": ["farmer"],
     "name": "농작물재해보험", "summary": "농작물 피해 보상."},
    {"category": "insurance", "hazards": ["typhoon", "heavy_rain", "strong_wind"], "targets": ["farmer"],
     "name": "가축재해보험", "summary": "가축 피해 보상."},
    {"category": "insurance", "hazards": ALL, "targets": ["resident"], "name": "포항시민안전보험 (2026)", "summary": "자동 가입."},
    {"category": "recovery", "hazards": ALL, "targets": ["all"], "name": "재난 사망·실종·부상 구호금", "summary": "사망 시 2,000만원."},
    {"category": "livelihood", "hazards": ["typhoon", "heavy_rain", "flood", "landslide"], "targets": ["all"],
     "name": "이재민 응급·장기 구호", "summary": "구호물품·구호비.", "how_to_apply": "읍면동에 피해 신고"},
    {"category": "recovery", "hazards": ["typhoon", "heavy_rain", "flood", "landslide"], "targets": ["resident"],
     "name": "세입자 보조", "summary": "300만원 한도."},
    {"category": "livelihood", "hazards": ["typhoon", "heavy_rain", "flood", "strong_wind", "high_seas"], "targets": ["fisher", "farmer"],
     "name": "생계지원 (농·어업인)", "summary": "주생계수단 50% 이상 피해 가구 생계비."},
]


def db(sql, params=None):
    h = (params or {}).get("h")
    return [p for p in PROGRAMS if h is None or h in p["hazards"]]


def sections(occupation=None, question="지원받을 수 있는 거 있어?", **user):
    state = {"question": question, "user": UserProfile(user_id="u1", occupation=occupation, **user)}
    d = collect_recovery(state, fetch=db)
    return {k: [p["name"] for p in v] for k, v in d.facts["sections"].items()}, d


def test_fisher_gets_three_sections():
    s, d = sections("어업 종사자·뱃사람")
    assert s["공통 보험"] == ["풍수해·지진재해보험", "포항시민안전보험 (2026)"]
    assert set(s["공통 피해 신고·복구"]) == {"재난 사망·실종·부상 구호금", "이재민 응급·장기 구호", "세입자 보조"}
    assert set(s["내 직업 지원·복구"]) == {"양식수산물재해보험", "생계지원 (농·어업인)"}
    keys = [e.key for e in d.evidence]
    assert "[공통 보험] 풍수해·지진재해보험" in keys and "[내 직업 지원·복구] 양식수산물재해보험" in keys
    assert any("1588-4119" in str(e.value) for e in d.evidence)                  # 연락처도 근거로


def test_farmer_and_livestock():
    assert set(sections("농업 종사자")[0]["내 직업 지원·복구"]) == {"농작물재해보험", "가축재해보험", "생계지원 (농·어업인)"}
    assert "가축재해보험" in sections("축산업 종사자")[0]["내 직업 지원·복구"]


@pytest.mark.parametrize("occupation", ["자영업자", None])
def test_no_job_program_says_so(occupation):
    s, d = sections(occupation)
    assert s["내 직업 지원·복구"] == []
    note = next(e for e in d.evidence if e.key == "[내 직업 지원·복구]")
    assert "DB에 등록된 제도 없음" in note.value
    text = recovery_template(d)
    assert "[공통 보험]" in text and "DB에 등록된 제도 없음" in text
    assert ("프로필에 직업을 입력" in text) == (occupation is None)


def test_tourist_gets_no_resident_programs():
    s, _ = sections("어업 종사자·뱃사람", user_type="tourist")
    assert s["공통 보험"] == [] and "세입자 보조" not in s["공통 피해 신고·복구"]
    assert "재난 사망·실종·부상 구호금" in s["공통 피해 신고·복구"]


def test_question_hazard_filters_programs():
    assert hazard_of("태풍 피해 지원 있어?") == "typhoon" and hazard_of("보험 뭐 있어?") is None
    s, d = sections("농업 종사자", question="산사태 피해 났는데 지원돼?")
    assert d.facts["hazard"] == "landslide"
    assert "농작물재해보험" not in s["내 직업 지원·복구"] and "포항시민안전보험 (2026)" in s["공통 보험"]


def test_job_targets_from_names_and_codes():
    assert job_targets("어업 종사자·뱃사람, 기타") == {"fisher"} and job_targets("양식업 종사자·수산물 양식") == {"fisher"}
    assert job_targets("fisher, farmer") == {"fisher", "farmer"} and job_targets("학생") == set()


def test_db_failure():
    def broken(*a, **k):
        raise ConnectionError("db down")
    d = collect_recovery({"question": "보험", "user": UserProfile(user_id="u1")}, fetch=broken)
    assert "지원·복구 제도 목록" in d.unavailable and "확인할 수 없습니다" in recovery_template(d)


def test_tool_shape():
    res = T.get_support_programs(hazard="landslide", fetch=db)
    assert res["available"] and all("landslide" in p["hazards"] for p in res["items"])


def test_keyword_routing_and_advisor_does_not_ask_back():
    assert G.keyword_classify({"question": "보험 뭐 있어?"}) == [Specialist.RECOVERY_SUPPORT]
    svc = ChatService(classifier=G.keyword_classify,
                      overrides={Specialist.RECOVERY_SUPPORT.value: make_recovery_support_agent(fetch=db)})
    res = svc.chat(ChatRequest(user_id="u1", question="피해 복구 지원 뭐 있어?",
                               profile=UserProfile(user_id="u1", occupation="어업 종사자·뱃사람")))
    assert res.selected_agents == [Specialist.RECOVERY_SUPPORT]
    assert res.decision_path == "지원·복구 > 정보 안내" and res.follow_up is None
    assert "[내 직업 지원·복구]" in res.answer and "양식수산물재해보험" in res.answer
    assert not res.used_fallback


def test_with_disaster_agent_drops_unconfirmed_insurance_note():
    from guardian_ai.action import decide, make_action_advisor
    from guardian_ai.state import SpecialistResult
    state = {"phase": Phase.AFTER, "damage": "yes", "question": "태풍 피해 지원",
             "user": UserProfile(user_id="u1"),
             "specialist_results": [SpecialistResult(agent=Specialist.WIND_TYPHOON, summary="강풍 정상"),
                                    SpecialistResult(agent=Specialist.RECOVERY_SUPPORT, summary="[공통 보험] …")]}
    assert any(n.key == "보험·법률 정보" for n in decide(state, use_data=False).notes)
    plan = make_action_advisor(use_guides=False)(state)["action_plan"]
    assert not any(e.key == "보험·법률 정보" for e in plan.evidence)
    assert not any("보험·법률" in step for step in plan.steps)
