"""B13 방문 우선순위 (app/priority.py) — 사용자 규칙 2026-10-08"""
import random

from app import priority

ORIGIN = (35.9900, 129.5600)


def T(id, status, needs=(), kind="household", lat=35.99, lng=129.56, minutes=0, **kw):
    return {"id": id, "kind": kind, "status": status, "needs": list(needs), "location": {"lat": lat, "lng": lng},
            "minutes_since_alert": minutes, **kw}


def order(targets, origin=None):
    return [t["id"] for t in priority.rank([dict(t) for t in targets], origin)]


def test_six_tiers_in_user_order():
    ts = [T("done", "evacuated"), T("moving", "evacuating"), T("nr", "no_response"),
          T("nr-dis", "no_response", ["wheelchair"]), T("help", "need_help"), T("help-dis", "need_help", ["vision"])]
    assert order(ts) == ["help-dis", "help", "nr-dis", "nr", "moving", "done"]


def test_disability_means_vision_hearing_physical_only():
    for n in ("vision", "hearing", "wheelchair", "bedridden", "mobility_limited"):
        assert priority.disabilities(T("x", "no_response", [n])), n
    # 고령·독거·영유아·의료기기 등은 장애로 보지 않음 → 응답 없음(4)
    t = T("x", "no_response", ["elderly", "living_alone", "infant", "medical_device", "cognitive"])
    assert priority.disabilities(t) == [] and priority.tier(t) == 4


def test_app_user_disability_from_server_profile():
    assert priority.disabilities(T("u", "need_help", kind="app_user", up_vision=True)) == ["시각장애"]
    assert priority.disabilities(T("u", "need_help", kind="app_user", up_mobility="wheelchair")) == ["휠체어"]
    assert priority.disabilities(T("u", "need_help", kind="app_user", up_walking="limited")) == ["보행 불편"]
    assert priority.disabilities(T("u", "need_help", kind="app_user", up_walking="normal", up_mobility="walk")) == []


def test_outside_area_removed():
    ts = [T("in", "no_response"), T("out", "need_help", ["vision"], in_area=False)]
    assert order(ts) == ["in"]
    kept = priority.rank([dict(t) for t in ts], keep_outside=True)
    assert [t["id"] for t in kept] == ["in", "out"] and kept[1]["priority_reasons"][-1]["label"] == "위험지역 밖"


def test_same_tier_nearest_first_with_location():
    far = T("far", "no_response", lat=36.0000, lng=129.5600)      # 약 1.1km
    near = T("near", "no_response", lat=35.9910, lng=129.5600)    # 약 110m
    assert order([far, near], ORIGIN) == ["near", "far"]
    # 순위가 거리보다 먼저: 멀어도 도움 필요가 앞
    assert order([near, T("help-far", "need_help", lat=36.01, lng=129.56)], ORIGIN) == ["help-far", "near"]


def test_same_tier_longest_waiting_without_location():
    ts = [T("new", "no_response", minutes=2), T("old", "no_response", minutes=15)]
    assert order(ts) == ["old", "new"]


def test_same_input_same_order_and_reasons():
    ts = [T(f"t{i}", random.Random(i).choice(["need_help", "no_response", "evacuating", "evacuated"]),
            random.Random(i).choice([[], ["hearing"], ["elderly"]]), lat=35.98 + i * 0.001, minutes=i % 4) for i in range(20)]
    first = priority.rank([dict(t) for t in ts], ORIGIN)
    for seed in range(5):
        shuffled = [dict(t) for t in ts]
        random.Random(seed).shuffle(shuffled)
        again = priority.rank(shuffled, ORIGIN)
        assert [(t["id"], t["priority_reasons"]) for t in again] == [(t["id"], t["priority_reasons"]) for t in first]


def test_rank_score_and_reasons_shape():
    out = priority.rank([T("a", "need_help", ["wheelchair", "hearing"]), T("b", "no_response")], ORIGIN)
    assert [t["priority_rank"] for t in out] == [1, 2]
    assert out[0]["priority_score"] > out[1]["priority_score"]
    labels = [r["label"] for r in out[0]["priority_reasons"]]
    assert labels[0] == "도움 요청" and labels[1] == "청각장애·휠체어" and labels[2].endswith("m")
