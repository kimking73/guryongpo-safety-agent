"""DB 직접 조회 (읽기 전용) — B3, 2026-10-01 결정.

AI는 A 레인의 FastAPI를 거치지 않고 PostgreSQL을 직접 읽는다 (기획서 "데이터베이스와 AI agent를 연결").
계정은 db/init/07_ai_readonly.sh가 만든 AI_DB_USER — SELECT 권한만 있고, 접속할 때도 읽기 전용 트랜잭션을 강제한다.
쓰기는 A의 수집기·판정 엔진만 한다.

접속 정보 (루트 .env):
  컨테이너 — compose가 AI_DB_HOST=db, AI_DB_PORT=5432를 넣는다.
  맥에서 직접(테스트) — localhost:DB_HOST_PORT(기본 5433).
DB가 꺼져 있어도 ai 서버는 뜬다. 조회 실패는 tools.py가 available=False로 바꿔 agent에 넘긴다.
"""

from __future__ import annotations

import atexit
import logging
import os
from typing import Any, Callable, Mapping

logger = logging.getLogger(__name__)

# 재난 중 답변이 DB 때문에 오래 멈추지 않게. 넘으면 그 조회만 실패 처리
STATEMENT_TIMEOUT_MS = 3000
CONNECT_TIMEOUT_S = 3

# tools.py가 받는 조회 함수 모양: (SQL, 파라미터) → 행(dict) 목록. 테스트는 가짜 함수를 넣는다.
Fetch = Callable[[str, Mapping[str, Any]], list[dict[str, Any]]]


def conninfo() -> str:
    """.env 값으로 접속 문자열을 만든다. 비밀번호는 로그에 남기지 않는다."""
    from psycopg.conninfo import make_conninfo

    return make_conninfo(
        host=os.environ.get("AI_DB_HOST") or "localhost",
        port=os.environ.get("AI_DB_PORT") or os.environ.get("DB_HOST_PORT") or "5433",
        dbname=os.environ.get("DB_NAME") or "guardian",
        user=os.environ.get("AI_DB_USER") or "guardian_ai",
        password=os.environ.get("AI_DB_PASSWORD") or "",
        connect_timeout=CONNECT_TIMEOUT_S,
        application_name="guardian_ai",
        # 계정 설정과 별개로 한 번 더: 모든 트랜잭션 읽기 전용 + 조회 시간 제한
        options=f"-c default_transaction_read_only=on -c statement_timeout={STATEMENT_TIMEOUT_MS}",
    )


class Database:
    """커넥션 풀을 처음 조회할 때 연다 (ai 서버 기동이 DB에 묶이지 않게)."""

    def __init__(self, dsn: str | None = None, max_size: int = 5):
        self._dsn, self._max_size, self._pool = dsn, max_size, None

    def _get_pool(self):
        if self._pool is None:
            from psycopg.rows import dict_row
            from psycopg_pool import ConnectionPool

            self._pool = ConnectionPool(self._dsn or conninfo(), min_size=1, max_size=self._max_size,
                                        kwargs={"row_factory": dict_row, "autocommit": True},
                                        timeout=CONNECT_TIMEOUT_S, open=False, name="guardian_ai")
            self._pool.open(wait=False)
        return self._pool

    def fetch_all(self, sql: str, params: Mapping[str, Any] | None = None) -> list[dict[str, Any]]:
        with self._get_pool().connection() as conn:
            return conn.execute(sql, params or {}).fetchall()

    def close(self) -> None:
        if self._pool is not None:
            self._pool.close()
            self._pool = None


_default: Database | None = None


def get_db() -> Database:
    global _default
    if _default is None:
        _default = Database()
        atexit.register(_default.close)   # 종료할 때 풀 스레드를 정리 (안 하면 5초씩 기다리며 경고)
    return _default


def default_fetch(sql: str, params: Mapping[str, Any] | None = None) -> list[dict[str, Any]]:
    return get_db().fetch_all(sql, params)
