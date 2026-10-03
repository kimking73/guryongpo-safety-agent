"""수집기 — 저장된 원문(mock/external)으로 변환·작업 흐름 검증 (네트워크·DB 없음)"""
from datetime import datetime, timedelta, timezone

import pytest

KST = timezone(timedelta(hours=9))


@pytest.fixture
def replay(monkeypatch):
    from app.config import settings
    object.__setattr__(settings, "fetch_mode", "replay")
    yield
    object.__setattr__(settings, "fetch_mode", "live")


def test_kma_times():
    from collector.fetch import kma_times
    t = kma_times(datetime(2026, 9, 27, 14, 50, tzinfo=KST))
    assert (t["NCST_DATE"], t["NCST_TIME"]) == ("20260927", "1400")      # 정시 발표 +40분
    assert t["FCST_TIME"] == "1330"                                      # 14:05 기준 직전 30분 발표
    assert t["VIL_TIME"] == "1400"
    assert t["MID_TMFC"] == "202609270600"
    assert t["NOW_TM_UTC"] == "202609270545"                             # 태풍 API 는 UTC
    t = kma_times(datetime(2026, 9, 27, 0, 30, tzinfo=KST))
    assert (t["VIL_DATE"], t["VIL_TIME"]) == ("20260926", "2300")         # 자정 직후 → 전날 23시


@pytest.mark.parametrize("key", ["pohang_dt.water_level", "pohang_dt.air_realtime", "pohang_dt.uv",
                                 "pohang_dt.air_devices", "kma.warnings", "kma.aws", "kma.ncst", "kma.ultra_fcst",
                                 "kma.vilage_fcst", "kma.mid_fcst", "kma.typhoon",
                                 "safety24.disaster_messages", "nmc.er_beds"])
def test_jobs_replay(fake_db, replay, key):
    from collector import jobs
    fake_db.rows["INSERT INTO ingest_runs"] = [{"id": 1}]
    fake_db.rows["count(*) AS n FROM stations"] = [{"n": 24}]
    res = jobs.execute(jobs.BY_KEY[key])
    assert res["status"] == "success", res
    if key not in ("kma.warnings",):          # 저장된 특보 원문은 발효 특보 없음([])
        assert res["rows"] > 0


def test_job_failure_is_recorded(fake_db, monkeypatch):
    from app.config import settings
    from collector import jobs                # live 모드 + 키 없음 → 실패로 기록, 예외는 밖으로 안 나감
    object.__setattr__(settings, "kma_key", None)   # .env 에 키가 있어도 실제 호출하지 않게
    fake_db.rows["INSERT INTO ingest_runs"] = [{"id": 5}]
    res = jobs.execute(jobs.BY_KEY["kma.aws"])
    assert res["status"] == "failed" and "KMA_KEY" in res["error"]
    assert any("status = 'failed'" in sql for sql, _ in fake_db.executed)


def test_warning_release(fake_db):
    from collector import store
    store.upsert_warnings([], ["L1072400"])   # 목록이 비면 → 발효 중이던 특보 전부 해제 처리
    sql, params = fake_db.executed[-1]
    assert "released_at" in sql and params["seen"] == []


def test_ingest_components():
    from app.health import ingest_components
    from collector.jobs import JOBS
    now = datetime.now(KST)
    rows = [{"source_code": j.source, "job": j.job, "last_success_at": now} for j in JOBS]
    rows[0]["last_success_at"] = now - timedelta(hours=1)              # water_level 60분 전 (> 30분)
    comps = ingest_components(rows, JOBS, now)
    assert comps["ingest.pohang_dt"]["status"] == "degraded"
    assert comps["ingest.kma"]["status"] == "ok"
    assert ingest_components([], JOBS, now)["ingest.kma"]["status"] == "down"


def test_empty_warning_response_is_failure(fake_db, replay, monkeypatch, tmp_path):
    """빈 응답을 '특보 없음'으로 처리하면 발효 중 특보가 전부 해제됨 → 실패로 기록하고 해제하지 않아야 함"""
    from app.config import settings
    from collector import jobs
    (tmp_path / "kma_wrn_now.txt").write_text("", encoding="utf-8")
    original = settings.replay_dir
    object.__setattr__(settings, "replay_dir", tmp_path)
    fake_db.rows["INSERT INTO ingest_runs"] = [{"id": 9}]
    try:
        res = jobs.execute(jobs.BY_KEY["kma.warnings"])
    finally:
        object.__setattr__(settings, "replay_dir", original)
    assert res["status"] == "failed"
    assert not any("released_at = %(now)s" in sql for sql, _ in fake_db.executed)


def test_safety_msg_normalize():
    from pathlib import Path
    from collector.converters import safety_msg
    text = (Path(__file__).resolve().parent.parent / "mock/external/safety_msg_pohang.json").read_text(encoding="utf-8")
    rows, skipped = safety_msg.normalize(text)
    assert len(rows) == 5 and not skipped
    r = next(x for x in rows if x["category"] == "풍랑")
    assert r["hazard"] == "high_seas" and r["alert_class"] == "안전안내" and r["sender"] == "동해지방해양경찰청"
    assert r["sent_at"].endswith("+09:00") and "포항시 남구" in r["region_name"]


def test_safety_msg_errors():
    from collector.converters import safety_msg
    with pytest.raises(safety_msg.SafetyMsgError, match="32"):   # 미등록 IP → 실패로 기록돼야 함 (0건 성공 아님)
        safety_msg.normalize('{"header":{"resultCode":"32","resultMsg":"UNREGISTERED IP ERROR"},"body":null}')
    rows, skipped = safety_msg.normalize('{"header":{"resultCode":"00"},"body":[{"SN":1,"CRT_DT":"2026/09/27 10:00:00",'
                                         '"MSG_CN":"x","RCPTN_RGN_NM":"경기도 김포시 "}]}')
    assert rows == [] and len(skipped) == 1                       # 포항 외 지역 제외


def test_freshness_rules():
    from risk.freshness import freshness, judge_source
    now = datetime(2026, 9, 28, 15, 0, tzinfo=KST)
    f = freshness("2026-09-28T14:20:00+09:00", "kma", "weather", "aws_816", now)
    assert f["age_min"] == 40 and f["stale"] and "14:20 기준 · 40분 전 자료 (오래된 자료)" == f["label"]
    assert not freshness("2026-09-28T14:20:00+09:00", "kma", "weather", "grid_105_94", now)["stale"]   # 격자는 90분
    assert freshness(None, "kma", "weather", "aws_816", now)["label"] == "자료 없음"
    rows = [{"source_code": "kma", "external_id": "aws_816", "kind": "weather", "metric": "wind_speed", "value": 3,
             "observed_at": "2026-09-28T14:10:00+09:00"},                       # AWS 50분 전 → 무효
            {"source_code": "kma", "external_id": "grid_105_94", "kind": "weather", "metric": "wind_speed", "value": 4,
             "observed_at": "2026-09-28T14:00:00+09:00"}]                       # 격자 60분 전 → 유효
    j = judge_source("wind_speed", rows, now)
    assert j["external_id"] == "grid_105_94" and j["fallback_rank"] == 1         # AWS 실패 → 격자로 대체
    assert judge_source("wind_gust", rows, now) is None                          # 순간풍속은 대체 출처 없음 → 판단 불가


def test_nmc_er_beds():
    from pathlib import Path
    from collector.converters import nmc_er
    text = (Path(__file__).resolve().parent.parent / "mock/external/nmc_er_beds_pohang.txt").read_text(encoding="utf-8")
    rows = nmc_er.availability(text)
    assert len(rows) == 5 and all(r["observed_at"].endswith("+09:00") for r in rows)
    assert {r["external_id"] for r in rows} >= {"A2700016", "A2700002"}          # 성모·세명기독
    with pytest.raises(nmc_er.NmcError, match="12"):                             # 오퍼레이션 철자 오류 응답
        nmc_er.availability('<OpenAPI_ServiceResponse><cmmMsgHeader><returnReasonCode>12</returnReasonCode>'
                            '<returnAuthMsg>NO_OPENAPI_SERVICE_ERROR</returnAuthMsg></cmmMsgHeader></OpenAPI_ServiceResponse>')
