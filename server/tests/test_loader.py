"""A7 loader — 시드 파일 재적용 안전성(정적 검사) + 적용 흐름(가짜 연결) + 실제 PostGIS (TEST_DATABASE_URL 있을 때)"""
import os
import re
from pathlib import Path

import pytest

from loader import REQUIRED, apply, split_files
from loader.core import migration_files, schema_tables

SEED_DIR = Path(__file__).resolve().parents[2] / "db" / "init"


def _statements(sql: str) -> list[str]:
    """문자열 리터럴·주석을 지운 뒤 ; 로 나눔 (행동요령 본문 안의 ; 에 속지 않게)"""
    sql = re.sub(r"'(?:[^']|'')*'", "''", sql)
    sql = re.sub(r"--[^\n]*", "", sql)
    return [s.strip() for s in sql.split(";") if s.strip()]


def test_split_files():
    schema, seeds = split_files(SEED_DIR)
    assert [f.name[:3] for f in schema] == ["00_", "01_"]
    assert seeds and all(f.name[:2] >= "02" for f in seeds)
    assert {"shelters", "medical_facilities", "hazard_zones", "manholes", "action_guides"} <= set(schema_tables(schema))
    assert set(REQUIRED) <= set(schema_tables(schema))
    assert not any(f.name.startswith("01m_") for f in seeds)        # 스키마 추가분은 시드가 아님


def test_migrations_rerunnable_and_care_schema():
    """01m_* 는 기존 DB 에 매번 적용 → 모든 CREATE 는 IF NOT EXISTS, ENUM 은 duplicate_object 무시.
    민감정보 테이블은 care 스키마 (AI 읽기 전용 계정은 public 만 SELECT)"""
    migs = migration_files(SEED_DIR)
    assert [f.name for f in migs] == ["01m_v0_3.sql", "01m_v0_4_households.sql", "01m_v0_5_visits.sql"]
    sql = migs[0].read_text(encoding="utf-8")
    for st in _statements(sql):
        if re.match(r"CREATE (TABLE|INDEX|UNIQUE INDEX|SCHEMA)", st):
            assert "IF NOT EXISTS" in st, st[:80]
        if st.startswith("ALTER TABLE"):
            assert "ADD COLUMN IF NOT EXISTS" in st, st[:80]
    assert sql.count("CREATE TYPE") == sql.count("WHEN duplicate_object")
    tables = schema_tables(migs)
    assert {"care.households", "care.incidents", "care.incident_targets", "care.evacuation_responses",
            "care.visit_logs", "care.invite_codes", "ports"} <= set(tables)


def test_seeds_are_rerunnable():
    """02~ 의 모든 INSERT 는 ON CONFLICT 가 있거나, 앞에서(같은 파일 또는 이전 파일) TRUNCATE 한 테이블이어야 함
    → loader 를 여러 번 돌려도 중복 행·키 충돌이 없음"""
    _, seeds = split_files(SEED_DIR)
    truncated: set[str] = set()
    bad = []
    for f in seeds:
        for st in _statements(f.read_text(encoding="utf-8")):
            m = re.match(r"TRUNCATE\s+(.+?)(?:\s+RESTART IDENTITY)?(?:\s+CASCADE)?$", st, re.S | re.I)
            if m:
                truncated |= {t.strip() for t in m.group(1).split(",")}
                continue
            m = re.match(r"INSERT INTO\s+(\w+)", st, re.I)
            if m and "ON CONFLICT" not in st.upper() and m.group(1) not in truncated:
                bad.append(f"{f.name}: {m.group(1)}")
    assert not bad, bad


def test_risk_rule_ids_fixed():
    """risk_assessments.rule_id 와 문서가 번호로 부르는 기준 — 9 = 침수 15cm, 21~28 = 포항 DT 등급"""
    sql = (SEED_DIR / "02_seed.sql").read_text(encoding="utf-8")
    ids = [int(x) for x in re.findall(r"^  \((\d+), '", sql, re.M)]
    assert ids == list(range(1, 31))
    assert re.search(r"^  \(9, 'flood', 'advisory', '침수 발생', 'flood_depth'", sql, re.M)
    assert re.search(r"^  \(21, 'flood', 'watch', '침수 보통 \(포항 DT 2단계\)'", sql, re.M)
    assert "setval(pg_get_serial_sequence('risk_rules', 'id')" in sql


class FakeConn:
    def __init__(self, tables=(), fail_on=None):
        self.tables = set(tables)
        self.sql: list[str] = []
        self.fail_on = fail_on
        self.committed = self.rolled_back = False

    def execute(self, sql, params=None):
        self.sql.append(sql)
        if self.fail_on and self.fail_on in sql:
            raise RuntimeError("boom")
        if sql.startswith("-- DB 컨테이너를 처음") or "CREATE TABLE" in sql:
            self.tables |= set(re.findall(r"^CREATE TABLE\s+(?:IF NOT EXISTS\s+)?((?:\w+\.)?\w+)", sql, re.M))
        if "FROM pg_tables" in sql:     # (schemaname, tablename)
            rows = [tuple(t.split(".", 1)) if "." in t else ("public", t) for t in self.tables]
        else:
            rows = [(999,)]
        return type("Cur", (), {"fetchall": lambda s: rows, "fetchone": lambda s: rows[0]})()

    def commit(self):
        self.committed = True

    def rollback(self):
        self.rolled_back = True


def _all_tables():
    return schema_tables(split_files(SEED_DIR)[0] + migration_files(SEED_DIR))


def test_apply_empty_db_creates_schema():
    c = FakeConn()
    rep = apply(c, SEED_DIR, log=lambda *_: None)
    assert rep.created_schema and rep.applied[:3] == ["00_extensions.sql", "01_schema.sql", "01m_v0_3.sql"] and rep.ok
    assert c.committed and any("INSERT INTO ingest_runs" in s for s in c.sql)


def test_apply_existing_db_skips_schema_and_dry_run_rolls_back():
    c = FakeConn(_all_tables())
    rep = apply(c, SEED_DIR, dry_run=True, log=lambda *_: None)
    assert not rep.created_schema and rep.applied[:3] == ["01m_v0_3.sql", "01m_v0_4_households.sql", "01m_v0_5_visits.sql"] and rep.applied[3].startswith("02_")
    assert c.rolled_back and not c.committed
    assert not any("INSERT INTO ingest_runs" in s for s in c.sql)


def test_apply_existing_db_without_v03_gets_migration():
    """v0.2 까지 만든 DB (care 스키마 없음) → loader 가 01m 을 먼저 적용해 스키마 확인을 통과"""
    c = FakeConn([t for t in _all_tables() if not t.startswith("care.") and t != "ports"])
    rep = apply(c, SEED_DIR, log=lambda *_: None)
    assert rep.ok and "01m_v0_3.sql" in rep.applied and "care.households" in c.tables


def test_apply_outdated_schema_stops():
    c = FakeConn([t for t in _all_tables() if t != "manholes"])
    with pytest.raises(RuntimeError, match="manholes"):
        apply(c, SEED_DIR, log=lambda *_: None)
    assert c.rolled_back and not c.committed


def test_apply_sql_error_rolls_back_everything():
    c = FakeConn(_all_tables(), fail_on="INSERT INTO shelters")
    with pytest.raises(RuntimeError, match="boom"):
        apply(c, SEED_DIR, log=lambda *_: None)
    assert c.rolled_back and not c.committed


@pytest.mark.skipif(not os.environ.get("TEST_DATABASE_URL"), reason="TEST_DATABASE_URL 없음")
def test_real_db_twice_same_result():
    """실제 PostGIS: 두 번 적용해도 행 수·기준 id 가 같음 (A7 완료 기준의 재실행 부분)"""
    import psycopg
    from loader import counts
    with psycopg.connect(os.environ["TEST_DATABASE_URL"]) as conn:
        first = apply(conn, SEED_DIR, log=lambda *_: None)
        second = apply(conn, SEED_DIR, log=lambda *_: None)
        assert first.ok and second.ok, (first.short, second.short)
        assert first.counts == second.counts == counts(conn)
        ids = [r[0] for r in conn.execute("SELECT id FROM risk_rules WHERE id <= 30 ORDER BY id").fetchall()]
        assert ids == list(range(1, 31))
        assert conn.execute("SELECT label FROM risk_rules WHERE id = 9").fetchone()[0] == "침수 발생"
        ag = conn.execute("SELECT min(id), max(id), count(*) FROM action_guides").fetchone()
        assert ag[0] == 1 and ag[1] == ag[2]                      # TRUNCATE ... RESTART IDENTITY → id 1부터 유지
        assert conn.execute("SELECT count(*) FROM public_hotlines WHERE phone = '119'").fetchone()[0] == 1
