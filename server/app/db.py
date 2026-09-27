"""DB 접근 — psycopg 3 커넥션 풀 + 얇은 헬퍼

API(동기 라우터, FastAPI 스레드풀에서 실행)와 수집기가 같은 헬퍼를 쓴다.
SQL 파라미터는 psycopg 형식(%(name)s). 행은 dict 로 반환.
"""
from __future__ import annotations

import logging
from contextlib import contextmanager
from typing import Any, Iterable, Iterator, Mapping, Sequence

log = logging.getLogger(__name__)

_pool = None


def init_pool(database_url: str, min_size: int = 1, max_size: int = 10) -> None:
    """앱/수집기 시작 시 1회. 연결 실패해도 예외를 내지 않음 (/health 가 db: down 으로 보고)."""
    global _pool
    if _pool is not None:
        return
    from psycopg.rows import dict_row
    from psycopg_pool import ConnectionPool

    _pool = ConnectionPool(
        database_url, min_size=min_size, max_size=max_size, open=False,
        kwargs={"row_factory": dict_row, "autocommit": False}, name="guryong",
    )
    _pool.open(wait=False)      # wait 는 open() 의 인자 — DB 가 늦게 떠도 서버는 먼저 기동
    log.info("DB pool opened")


def close_pool() -> None:
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None


@contextmanager
def connection() -> Iterator[Any]:
    """트랜잭션 1개 = with 블록 1개. 정상 종료 시 commit, 예외 시 rollback."""
    if _pool is None:
        raise RuntimeError("DB pool 이 초기화되지 않음 (init_pool 먼저 호출)")
    with _pool.connection(timeout=5) as conn:   # 풀의 context manager 가 commit/rollback 처리
        yield conn


def fetch_all(sql: str, params: Mapping[str, Any] | Sequence[Any] | None = None) -> list[dict]:
    with connection() as conn:
        return list(conn.execute(sql, params).fetchall())


def fetch_one(sql: str, params: Mapping[str, Any] | Sequence[Any] | None = None) -> dict | None:
    with connection() as conn:
        return conn.execute(sql, params).fetchone()


def execute(sql: str, params: Mapping[str, Any] | Sequence[Any] | None = None) -> int:
    with connection() as conn:
        return conn.execute(sql, params).rowcount


def execute_many(sql: str, rows: Iterable[Mapping[str, Any]]) -> int:
    """같은 SQL 을 여러 행에 실행 (한 트랜잭션). 반환: 넘긴 행 수"""
    rows = list(rows)
    if not rows:
        return 0
    with connection() as conn:
        with conn.cursor() as cur:
            cur.executemany(sql, rows)
    return len(rows)
