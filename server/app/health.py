"""/health 계산 — DB 연결 + 수집 작업 신선도 + (설정된 경우) route·ai 서비스

수집 판정 (README 5-1: API 호출 실패가 30분 이상 이어지면 degraded)
  작업별 마지막 성공 시각이 stale_after_min 보다 오래됨 → 그 작업 stale
  source(pohang_dt, kma) 단위로 묶어서
    ok       : 모든 작업이 최근에 성공
    degraded : 일부 작업이 stale 이거나 한 번도 성공하지 못함
    down     : 모든 작업이 stale (최근 성공 없음)
전체 status: DB down → down / 하나라도 degraded·down → degraded / 그 외 ok
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import httpx

from . import db
from .config import settings

KST = timezone(timedelta(hours=9))

LAST_SUCCESS_SQL = """
SELECT source_code, job, max(finished_at) FILTER (WHERE status = 'success') AS last_success_at,
       (array_agg(status ORDER BY started_at DESC))[1] AS last_status
FROM ingest_runs WHERE started_at > now() - interval '3 days'
GROUP BY source_code, job
"""


def _iso(t: datetime | None) -> str | None:
    return t.astimezone(KST).isoformat(timespec="seconds") if t else None


def ingest_components(rows: list[dict], jobs: list, now: datetime) -> dict[str, dict]:
    """rows: LAST_SUCCESS_SQL 결과, jobs: collector.jobs.JOBS → {'ingest.kma': {...}, ...}"""
    last = {(r["source_code"], r["job"]): r for r in rows}
    out: dict[str, dict] = {}
    for source in dict.fromkeys(j.source for j in jobs):
        fresh, stale, last_ok = [], [], None
        for j in (j for j in jobs if j.source == source):
            t = (last.get((source, j.job)) or {}).get("last_success_at")
            if t and (last_ok is None or t > last_ok):
                last_ok = t
            (fresh if t and now - t <= timedelta(minutes=j.stale_after_min) else stale).append(j.job)
        status = "ok" if not stale else ("down" if not fresh else "degraded")
        comp = {"status": status, "last_success_at": _iso(last_ok)}
        if stale:
            comp["stale_jobs"] = stale
        out[f"ingest.{source}"] = comp
    return out


def _ping(url: str) -> dict:
    try:
        r = httpx.get(url, timeout=2.0)
        ok = r.status_code < 400
    except httpx.HTTPError:
        ok = False
    return {"status": "ok" if ok else "down", "last_success_at": _iso(datetime.now(KST)) if ok else None}


def compute() -> dict:
    from collector.jobs import JOBS

    now = datetime.now(KST)
    comps: dict[str, dict] = {}
    try:
        r = db.fetch_one("SELECT now() AS now")
        comps["db"] = {"status": "ok", "last_success_at": _iso(r["now"])}
        comps.update(ingest_components(db.fetch_all(LAST_SUCCESS_SQL), JOBS, now))
    except Exception as e:  # noqa: BLE001
        comps["db"] = {"status": "down", "last_success_at": None, "error": type(e).__name__}
    if settings.route_health_url:
        comps["route"] = _ping(settings.route_health_url)
    if settings.ai_health_url:
        comps["ai"] = _ping(settings.ai_health_url)

    if comps["db"]["status"] == "down":
        status = "down"
    elif any(c["status"] != "ok" for c in comps.values()):
        status = "degraded"
    else:
        status = "ok"
    # "db": B8 골격 때부터 쓰던 간단 형식 ({"status":"ok","db":"ok"}) — README·배포 확인 스크립트 호환
    return {"status": status, "db": "ok" if comps["db"]["status"] == "ok" else "error",
            "version": settings.version, "server_time": _iso(now), "components": comps}
