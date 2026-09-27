"""주기 수집 스케줄러 (APScheduler 3.x, Asia/Seoul)

- 같은 작업이 겹쳐 돌지 않음 (max_instances=1), 밀린 실행은 1번으로 합침 (coalesce)
- 시작 직후 run_at_start 작업을 한 번씩 실행 → 서버를 켜자마자 대시보드에 값이 보이게
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta

from .jobs import JOBS, Job, execute

log = logging.getLogger("collector")
TZ = "Asia/Seoul"


def _add(sched, j: Job, stagger_sec: int) -> None:
    from apscheduler.triggers.cron import CronTrigger

    sched.add_job(execute, CronTrigger(timezone=TZ, **j.cron), args=[j], id=j.key, name=j.key,
                  max_instances=1, coalesce=True, misfire_grace_time=300, replace_existing=True)
    if j.run_at_start:
        # 시작 직후 1회 — 동시에 몰리지 않게 몇 초씩 띄움
        sched.add_job(execute, "date", run_date=datetime.now().astimezone() + timedelta(seconds=stagger_sec),
                      args=[j], id=j.key + ".start", name=j.key + " (start)", replace_existing=True)


def build(blocking: bool):
    from apscheduler.schedulers.background import BackgroundScheduler
    from apscheduler.schedulers.blocking import BlockingScheduler

    sched = (BlockingScheduler if blocking else BackgroundScheduler)(
        timezone=TZ, job_defaults={"max_instances": 1, "coalesce": True})
    for i, j in enumerate(JOBS):
        _add(sched, j, 2 + i * 3)
    return sched


_background = None


def start_background() -> None:
    """API 프로세스 안에서 돌릴 때 (ENABLE_SCHEDULER=true, 로컬 개발용)"""
    global _background
    if _background is None:
        _background = build(blocking=False)
        _background.start()
        log.info("background scheduler started: %d jobs", len(JOBS))


def stop_background() -> None:
    global _background
    if _background is not None:
        _background.shutdown(wait=False)
        _background = None
