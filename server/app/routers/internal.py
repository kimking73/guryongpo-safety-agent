"""내부용 — 수집 작업 수동 실행, 시연 시나리오 주입 (X-Internal-Token)"""
from fastapi import APIRouter, BackgroundTasks, Depends

from ..auth import require_internal
from ..errors import ApiError
from ..schemas import SimulateRequest

router = APIRouter(prefix="/internal", tags=["internal"], dependencies=[Depends(require_internal)])


@router.get("/ingest", summary="수집 작업 목록과 최근 실행")
def list_ingest():
    from .. import db
    from collector.jobs import JOBS

    last = {(r["source_code"], r["job"]): r for r in db.fetch_all("""
        SELECT DISTINCT ON (source_code, job) source_code, job, id, status, started_at, finished_at, row_count, error
        FROM ingest_runs ORDER BY source_code, job, started_at DESC""")}
    return [{"source": j.source, "job": j.job, "cron": j.cron, "stale_after_min": j.stale_after_min,
             "last_run": last.get((j.source, j.job))} for j in JOBS]


@router.post("/ingest/{source}/{job}", status_code=202, summary="수집 작업 수동 실행")
def run_ingest(source: str, job: str, background: BackgroundTasks):
    from collector import jobs, store

    j = jobs.find(source, job)
    if j is None:
        raise ApiError("NOT_FOUND", detail=f"unknown job {source}/{job}")
    run_id = store.start_run(j.source, j.job)
    background.add_task(jobs.execute, j, run_id)
    return {"ingest_run_id": run_id}


@router.post("/simulate", status_code=202, summary="시연 시나리오 주입 (heavy_rain_flood · clear)")
def simulate(body: SimulateRequest):
    """모의 관측값을 넣고 즉시 판정. 모의값은 6시간 동안 실측보다 우선, clear 로 해제"""
    from risk import simulate as sim
    return sim.apply(body.scenario)
