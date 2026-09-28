"""loader 본체 — 파일 분류, 스키마 확인, 시드 적용, 적재 결과 집계"""
from __future__ import annotations

import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

# 00_extensions · 01_schema : 스키마 (빈 DB 에서만 실행). 02~ : 시드 (매번 실행, 재적용 안전)
SCHEMA_PREFIXES = ("00_", "01_")

# 적재 후 비어 있으면 안 되는 정적 테이블 → 최소 행 수 (시연 데이터 기준, 줄어들면 원천·생성 스크립트 확인)
REQUIRED: dict[str, int] = {
    "data_sources": 10,
    "risk_rules": 30,
    "stations": 10,          # 포항 DT 수위계·강우량계 초기값 (수집기가 이후 대기·기상청 지점 추가)
    "manholes": 3,           # 포항 DT 스마트맨홀
    "hazard_zones": 400,     # 산사태 취약지역 (포항시 488)
    "shelters": 15,          # 구룡포 지진해일 긴급대피장소 + 민방위대피시설
    "medical_facilities": 3, # 포항 응급의료기관
    "action_guides": 40,
    "support_programs": 5,
    "public_hotlines": 10,
}


def find_seed_dir(explicit: str | None = None) -> Path:
    """--dir > SEED_DIR > 컨테이너(/srv/db/init) > 저장소(server/../db/init)"""
    for c in (explicit, os.environ.get("SEED_DIR"), "/srv/db/init",
              str(Path(__file__).resolve().parents[2] / "db" / "init")):
        if c and Path(c).is_dir() and any(Path(c).glob("*.sql")):
            return Path(c)
    raise FileNotFoundError("시드 폴더(db/init)를 찾지 못함 — --dir 또는 SEED_DIR 로 지정")


def split_files(seed_dir: Path) -> tuple[list[Path], list[Path]]:
    files = sorted(seed_dir.glob("*.sql"))
    schema = [f for f in files if f.name.startswith(SCHEMA_PREFIXES)]
    seeds = [f for f in files if f not in schema]
    return schema, seeds


def schema_tables(schema_files: list[Path]) -> list[str]:
    names: list[str] = []
    for f in schema_files:
        names += re.findall(r"^CREATE TABLE\s+(?:IF NOT EXISTS\s+)?(\w+)", f.read_text(encoding="utf-8"), re.M)
    return names


@dataclass
class Report:
    created_schema: bool = False
    applied: list[str] = field(default_factory=list)
    missing_tables: list[str] = field(default_factory=list)   # 스키마 파일엔 있는데 DB 엔 없는 테이블 (스키마 변경 미반영)
    counts: dict[str, int] = field(default_factory=dict)
    short: dict[str, tuple[int, int]] = field(default_factory=dict)   # 테이블 → (실제, 최소)
    sec: float = 0.0
    dry_run: bool = False

    @property
    def ok(self) -> bool:
        return not self.missing_tables and not self.short


def counts(conn, tables=REQUIRED) -> dict[str, int]:
    out = {}
    for t in tables:
        # 테이블 이름은 REQUIRED 상수에서만 옴 (외부 입력 아님)
        out[t] = conn.execute(f"SELECT count(*) FROM {t}").fetchone()[0]
    return out


def _existing_tables(conn) -> set[str]:
    rows = conn.execute("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").fetchall()
    return {r[0] for r in rows}


def apply(conn, seed_dir: Path, dry_run: bool = False, log=print) -> Report:
    """한 트랜잭션으로 적용. 실패하면 전부 되돌리고 예외 (DB 는 적용 전 상태 그대로).

    conn: psycopg.Connection (autocommit=False)
    """
    t0 = time.monotonic()
    rep = Report(dry_run=dry_run)
    schema_files, seed_files = split_files(seed_dir)
    wanted = schema_tables(schema_files)
    try:
        existing = _existing_tables(conn)
        if not existing & set(wanted):
            log(f"빈 DB → 스키마 생성: {', '.join(f.name for f in schema_files)}")
            for f in schema_files:
                conn.execute(f.read_text(encoding="utf-8"))
                rep.applied.append(f.name)
            rep.created_schema = True
            existing = _existing_tables(conn)
        rep.missing_tables = [t for t in wanted if t not in existing]
        if rep.missing_tables:
            raise RuntimeError(
                "DB 스키마가 01_schema.sql 보다 오래됨 (없는 테이블: " + ", ".join(rep.missing_tables) + ") — "
                "로컬은 `docker compose down -v` 후 다시 올리고, 배포 DB 는 해당 CREATE 문을 직접 적용")
        for f in seed_files:
            log(f"적용: {f.name}")
            conn.execute(f.read_text(encoding="utf-8"))
            rep.applied.append(f.name)
        rep.counts = counts(conn)
        rep.short = {t: (n, REQUIRED[t]) for t, n in rep.counts.items() if n < REQUIRED[t]}
        rep.sec = round(time.monotonic() - t0, 2)
        if not dry_run:
            conn.execute(
                "INSERT INTO ingest_runs (source_code, job, finished_at, status, row_count, error) "
                "VALUES ('loader', 'static_seed', now(), %s, %s, %s)",
                ("success" if rep.ok else "failed", sum(rep.counts.values()),
                 None if rep.ok else f"최소 행 수 미달: {rep.short}"))
    except BaseException:
        conn.rollback()
        raise
    if dry_run:
        conn.rollback()
    else:
        conn.commit()
    return rep
