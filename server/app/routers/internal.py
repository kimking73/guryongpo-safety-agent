"""내부용 — 수집 작업 수동 실행, 시연 시나리오 주입, 초대 코드 발급 (X-Internal-Token)"""
from fastapi import APIRouter, BackgroundTasks, Depends

from ..auth import require_internal
from ..errors import ApiError
from ..schemas import InviteInput, SimulateRequest

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


@router.post("/simulate", status_code=202, summary="시연 시나리오 주입 (heavy_rain_flood · clear · demo_households · demo_households_clear)")
def simulate(body: SimulateRequest):
    """모의 관측값을 넣고 즉시 판정. 모의값은 6시간 동안 실측보다 우선, clear 로 해제"""
    from risk import simulate as sim
    return sim.apply(body.scenario)


# 헷갈리는 글자(0·O·1·I·L) 뺀 32자
INVITE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"


def new_invite_code() -> str:
    import secrets
    part = lambda: "".join(secrets.choice(INVITE_ALPHABET) for _ in range(4))  # noqa: E731
    return f"GRY-{part()}-{part()}"


@router.post("/invites", status_code=201, summary="초대 코드 발급 (원문은 이 응답에서 한 번만)")
def create_invite(body: InviteInput):
    from .. import db
    from .user import code_hash
    code = new_invite_code()
    row = db.fetch_one("""
        INSERT INTO care.invite_codes (code_hash, role, label, max_uses, expires_at)
        VALUES (%(h)s, %(role)s::user_role, %(label)s, %(max_uses)s, now() + make_interval(days => %(days)s))
        RETURNING expires_at""", {"h": code_hash(code), "role": body.role, "label": body.label,
                                  "max_uses": body.max_uses, "days": body.expires_in_days})
    from ..mocks import iso
    return {"code": code, "role": body.role, "label": body.label, "max_uses": body.max_uses,
            "expires_at": iso(row["expires_at"]) if row else None}


@router.get("/invites", summary="초대 코드 목록 (원문 없음 — 번호·역할·이름·사용 횟수·만료·회수)")
def list_invites():
    from .. import db
    from ..mocks import iso
    rows = db.fetch_all("""
        SELECT id, role::text AS role, label, max_uses, used_count, expires_at, revoked_at, created_at
        FROM care.invite_codes ORDER BY id""")
    return [{**r, **{k: iso(r[k]) for k in ("expires_at", "revoked_at", "created_at")}} for r in rows]


@router.delete("/invites/{invite_id}", status_code=204, summary="초대 코드 회수 (이미 받은 역할은 그대로 — 필요하면 따로 내려놓기)")
def revoke_invite(invite_id: int):
    from fastapi import Response
    from .. import db
    row = db.fetch_one("UPDATE care.invite_codes SET revoked_at = coalesce(revoked_at, now()) WHERE id = %(id)s RETURNING id",
                       {"id": invite_id})
    if not row:
        raise ApiError("NOT_FOUND", detail={"invite_id": invite_id})
    return Response(status_code=204)
