"""수집기 실행
  python -m collector                 # 스케줄러 (운영: collector 컨테이너)
  python -m collector --once          # 전체 작업 1회 실행 후 종료 (결과 표 출력)
  python -m collector --once pohang_dt.water_level kma.aws
  python -m collector --list          # 작업 목록·주기
  FETCH_MODE=replay python -m collector --once   # 네트워크 없이 저장된 원문(mock/external)으로 적재
"""
from __future__ import annotations

import argparse
import logging
import sys

from app import db
from app.config import settings
from .jobs import BY_KEY, JOBS, execute


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m collector")
    ap.add_argument("--once", nargs="*", metavar="SOURCE.JOB", help="1회 실행 (작업 이름 생략 시 전체)")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--health", action="store_true", help="컨테이너 healthcheck: 최근 30분 안에 성공한 수집이 있으면 0")
    a = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # httpx 는 요청 URL 전체(인증키 포함)를 INFO 로 남김 → 키 노출 방지
    logging.getLogger("httpx").setLevel(logging.WARNING)

    if a.list:
        for j in JOBS:
            print(f"{j.key:28s} cron={j.cron}  stale>{j.stale_after_min}m")
        return 0

    if a.health:
        import psycopg
        try:
            with psycopg.connect(settings.database_url, connect_timeout=3) as conn:
                n = conn.execute("SELECT count(*) FROM ingest_runs WHERE status = 'success' AND source_code <> 'loader' "
                                 "AND finished_at > now() - interval '30 minutes'").fetchone()[0]
        except Exception as e:  # noqa: BLE001
            print("unhealthy:", type(e).__name__)
            return 1
        print("ok" if n else "unhealthy: 30분 동안 성공한 수집 없음", n)
        return 0 if n else 1

    db.init_pool(settings.database_url, max_size=3)
    print(f"DB={settings.database_url.rsplit('@', 1)[-1]}  FETCH_MODE={settings.fetch_mode}")
    if a.once is not None:
        keys = a.once or [j.key for j in JOBS]
        bad = [k for k in keys if k not in BY_KEY]
        if bad:
            print("모르는 작업:", bad, "\n--list 로 확인")
            return 2
        results = [execute(BY_KEY[k]) for k in keys]
        print()
        for r in results:
            print(f"{r['status']:8s} {r['job']:28s} rows={r.get('rows', '-'):<6} {r['sec']:>6}s  {r.get('error') or r.get('reason') or ''}")
        db.close_pool()
        return 0 if all(r["status"] != "failed" for r in results) else 1

    from .scheduler import build
    sched = build(blocking=True)
    print(f"scheduler: {len(JOBS)} jobs (Ctrl+C 로 종료)")
    try:
        sched.start()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        db.close_pool()
    return 0


if __name__ == "__main__":
    sys.exit(main())
