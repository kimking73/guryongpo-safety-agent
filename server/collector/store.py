"""DB 적재 — converters 가 만든 행을 그대로 upsert (SQL 도 converters 의 것을 재사용)"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

from app import db
from .converters import kma_typhoon, kma_vilage, kma_warn_aws
from .converters.pohang_dt_water import INSERT_OBSERVATION_SQL, UPSERT_STATION_SQL

KST = timezone(timedelta(hours=9))


# ------------------------------------------------------------------ ingest_runs
def start_run(source_code: str, job: str) -> int:
    if source_code == "risk":     # 판정 엔진은 외부 출처가 아님 — seed 에 없던 DB 를 위해 자동 등록
        db.execute("INSERT INTO data_sources (code, name, provider, note) VALUES ('risk', '위험 판정 엔진', "
                   "'구룡포는구룡', '관측값 + risk_rules → risk_assessments') ON CONFLICT (code) DO NOTHING")
    row = db.fetch_one(
        "INSERT INTO ingest_runs (source_code, job) VALUES (%(s)s, %(j)s) RETURNING id",
        {"s": source_code, "j": job})
    return int(row["id"])


def finish_run(run_id: int, row_count: int) -> None:
    db.execute("UPDATE ingest_runs SET finished_at = now(), status = 'success', row_count = %(n)s WHERE id = %(id)s",
               {"n": row_count, "id": run_id})


def fail_run(run_id: int, error: str) -> None:
    db.execute("UPDATE ingest_runs SET finished_at = now(), status = 'failed', error = %(e)s WHERE id = %(id)s",
               {"e": error[:2000], "id": run_id})


# ------------------------------------------------------------------ 관측
def upsert_stations(stations: list[dict]) -> int:
    rows = [{**s, "meta": json.dumps(s.get("meta") or {}, ensure_ascii=False)} for s in stations
            if s.get("lat") is not None and s.get("lng") is not None]
    return db.execute_many(UPSERT_STATION_SQL, rows)


def insert_observations(obs: list[dict], run_id: int) -> int:
    return db.execute_many(INSERT_OBSERVATION_SQL, [{**o, "ingest_run_id": run_id} for o in obs])


def count_stations(source_code: str, kind: str) -> int:
    r = db.fetch_one("SELECT count(*) AS n FROM stations WHERE source_code = %(s)s AND kind = %(k)s",
                     {"s": source_code, "k": kind})
    return int(r["n"]) if r else 0


# ------------------------------------------------------------------ 예보·특보·태풍
def upsert_forecasts(rows: list[dict]) -> int:
    return db.execute_many(kma_vilage.UPSERT_FORECAST_SQL, rows)


def upsert_warnings(rows: list[dict], regions: list[str], now: datetime | None = None) -> int:
    """이번 목록을 upsert 하고, 목록에서 사라진 (= 해제된) 특보는 released_at 기록"""
    n = db.execute_many(kma_warn_aws.UPSERT_WARNING_SQL,
                        [{**r, "raw": json.dumps(r["raw"], ensure_ascii=False)} for r in rows])
    db.execute(kma_warn_aws.RELEASE_MISSING_SQL, {
        "now": (now or datetime.now(KST)).isoformat(), "regions": regions,
        "seen": [f'{r["external_id"]}|{r["region_code"]}' for r in rows],
    })
    return n


def upsert_typhoon_tracks(rows: list[dict]) -> int:
    return db.execute_many(kma_typhoon.UPSERT_TRACK_SQL, rows)


def upsert_disaster_messages(rows: list[dict]) -> int:
    from .converters import safety_msg
    return db.execute_many(safety_msg.UPSERT_MESSAGE_SQL,
                           [{**r, "raw": json.dumps(r["raw"], ensure_ascii=False)} for r in rows])
