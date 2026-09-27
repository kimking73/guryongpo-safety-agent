"""정적 데이터 적재 실행

  docker compose run --rm loader              # 컨테이너 (db/init 을 /srv/db/init 으로 연결)
  docker compose run --rm loader --dry-run    # 적용해 보고 되돌림 (행 수만 확인)
  docker compose run --rm loader --check      # 적용 없이 행 수만 확인 (최소 행 수 미달이면 종료 코드 1)
  python -m loader --dir ../db/init           # 로컬 venv (DATABASE_URL 또는 기본값 localhost:5433)

종료 코드: 0 정상 / 1 최소 행 수 미달·스키마 불일치 / 2 DB 연결·SQL 오류
"""
from __future__ import annotations

import argparse
import sys
import time

from app.config import settings

from .core import REQUIRED, apply, counts, find_seed_dir


def _connect(url: str, wait_sec: int):
    import psycopg
    deadline = time.monotonic() + wait_sec
    while True:
        try:
            return psycopg.connect(url, connect_timeout=5)
        except psycopg.OperationalError as e:
            if time.monotonic() >= deadline:
                raise
            print(f"DB 대기 중… ({type(e).__name__})", flush=True)
            time.sleep(2)


def _table(cnt: dict[str, int]) -> None:
    for t, n in cnt.items():
        mark = "" if n >= REQUIRED[t] else f"   ← 최소 {REQUIRED[t]} 미달"
        print(f"  {t:20s} {n:>6}{mark}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m loader", description="db/init 스키마·시드 적용 (재실행 안전)")
    ap.add_argument("--dir", help="시드 폴더 (기본: SEED_DIR → /srv/db/init → 저장소 db/init)")
    ap.add_argument("--dry-run", action="store_true", help="적용 후 되돌림")
    ap.add_argument("--check", action="store_true", help="적용하지 않고 행 수만 확인")
    ap.add_argument("--wait", type=int, default=60, help="DB 가 뜰 때까지 기다릴 초 (기본 60)")
    a = ap.parse_args(argv)

    import psycopg
    print(f"DB={settings.database_url.rsplit('@', 1)[-1]}")
    try:
        conn = _connect(settings.database_url, a.wait)
    except psycopg.Error as e:
        print("DB 연결 실패:", type(e).__name__, str(e).splitlines()[0] if str(e) else "")
        return 2

    with conn:
        if a.check:
            try:
                cnt = counts(conn)
            except psycopg.Error as e:
                print("확인 실패 (스키마 없음?):", str(e).splitlines()[0])
                return 1
            _table(cnt)
            return 0 if all(n >= REQUIRED[t] for t, n in cnt.items()) else 1

        seed_dir = find_seed_dir(a.dir)
        print(f"시드 폴더: {seed_dir}" + ("  (dry-run: 끝나면 되돌림)" if a.dry_run else ""))
        try:
            rep = apply(conn, seed_dir, dry_run=a.dry_run)
        except RuntimeError as e:
            print("중단:", e)
            return 1
        except psycopg.Error as e:
            diag = getattr(e, "diag", None)
            print("SQL 오류 — 전부 되돌림:", type(e).__name__, str(e).splitlines()[0])
            if diag is not None and diag.context:
                print("  위치:", diag.context.splitlines()[0])
            return 2

    print()
    _table(rep.counts)
    state = "되돌림(dry-run)" if rep.dry_run else "적재 완료"
    print(f"\n{state}: 파일 {len(rep.applied)}개, {rep.sec}s" + ("  · 스키마 새로 생성" if rep.created_schema else ""))
    if rep.short:
        print("경고: 최소 행 수 미달 테이블", ", ".join(rep.short))
    return 0 if rep.ok else 1


if __name__ == "__main__":
    sys.exit(main())
