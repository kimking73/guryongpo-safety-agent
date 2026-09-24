"""구룡가디언 FastAPI 서버 (B8 최소 골격).

지금은 헬스체크만 있다. 엔드포인트 구조는 A가 A2에서 확장한다.
모든 경로는 /api 아래에 둔다 — 배포 시 Caddy가 /api를 이 서버로 넘긴다 (B10).
"""

import os

import psycopg
from fastapi import FastAPI

app = FastAPI(title="구룡가디언 API")


@app.get("/api/health")
def health() -> dict:
    """서버와 DB 연결 상태. 로컬 확인, 컨테이너 헬스체크, 배포 후 외부 확인(B10)에 쓴다."""
    try:
        with psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=3) as conn:
            conn.execute("SELECT 1")
        db = "ok"
    except Exception:
        db = "error"
    return {"status": "ok", "db": db}
