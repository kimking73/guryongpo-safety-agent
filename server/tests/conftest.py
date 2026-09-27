"""pytest 공통 설정 — DB 없이 API·수집기 로직을 검증 (DB 통합 테스트는 TEST_DATABASE_URL 있을 때만)

실행 (server/ 에서):  python3 -m venv .venv && .venv/bin/pip install -e ".[dev]" && .venv/bin/python -m pytest -q
"""
import os
import sys
from pathlib import Path

SERVER = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER))

# app.config 가 import 시점에 읽으므로 먼저 설정
os.environ["API_AUTH_MODE"] = "dev"                 # 루트 .env 값과 상관없이 테스트는 dev
os.environ.setdefault("MOCK_DIR", str(SERVER / "mock"))
os.environ.setdefault("REPLAY_DIR", str(SERVER / "mock" / "external"))
os.environ["DT_CONFIG"] = "/nonexistent"          # 테스트가 실제 키를 읽지 않게
os.environ.pop("API_INTERNAL_TOKEN", None)
os.environ.pop("INTERNAL_TOKEN", None)
os.environ.pop("COLLECTOR_FETCH_MODE", None)
if os.environ.get("TEST_DATABASE_URL"):
    os.environ["DATABASE_URL"] = os.environ["TEST_DATABASE_URL"]

import pytest  # noqa: E402

AUTH = {"Authorization": "Bearer dev:test-uid"}


class FakeDB:
    """app.db 헬퍼 대체 — SQL 앞부분으로 어떤 쿼리인지 판단해 준비된 행을 돌려줌"""

    def __init__(self):
        self.rows: dict[str, list[dict]] = {}
        self.fail = False
        self.executed: list[tuple[str, object]] = []

    def _match(self, sql):
        if self.fail:
            raise ConnectionError("db down")
        for key, rows in self.rows.items():
            if key in sql:
                return rows
        return []

    def fetch_all(self, sql, params=None):
        return list(self._match(sql))

    def fetch_one(self, sql, params=None):
        if "SELECT now()" in sql and not self.fail:
            from datetime import datetime, timezone
            return {"now": datetime.now(timezone.utc)}
        r = self._match(sql)
        return r[0] if r else None

    def execute(self, sql, params=None):
        self._match(sql)
        self.executed.append((sql, params))
        return 1

    def execute_many(self, sql, rows):
        rows = list(rows)
        self.executed.append((sql, rows))
        return len(rows)


@pytest.fixture
def fake_db(monkeypatch):
    from app import db
    f = FakeDB()
    for name in ("fetch_all", "fetch_one", "execute", "execute_many"):
        monkeypatch.setattr(db, name, getattr(f, name))
    return f


@pytest.fixture
def client(fake_db):
    from fastapi.testclient import TestClient
    from app.main import app
    return TestClient(app)          # with 블록 없이 → lifespan(DB 풀·Firebase) 실행 안 함
