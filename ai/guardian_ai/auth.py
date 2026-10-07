"""앱 로그인 확인 (2026-10-07): Authorization: Bearer <Firebase ID 토큰> → uid.

서버(A, server/app/auth.py)와 같은 규칙:
- API_AUTH_MODE=dev 면 'Bearer dev:<uid>' 도 통과 (로컬·테스트). 배포 VM 은 firebase.
- 그 밖에는 Firebase ID 토큰을 Google 공개키로 검증한다 (google-auth — 음성 기능 때문에 이미 쓰는 라이브러리, firebase_admin 불필요).
  프로젝트 id = FIREBASE_PROJECT_ID, 없으면 FIREBASE_CREDENTIALS(서비스 계정 json, compose 가 ./secrets 를 /srv/secrets 로 연결)의 project_id.
지금은 '내 기억' API(/api/ai/me/memory)만 쓴다. 채팅은 예전처럼 요청 본문의 user_id 를 쓴다.
"""

from __future__ import annotations

import json
import logging
import os
from functools import lru_cache
from pathlib import Path

from fastapi import Header, HTTPException

logger = logging.getLogger(__name__)


@lru_cache
def firebase_project_id() -> str | None:
    if os.environ.get("FIREBASE_PROJECT_ID"):
        return os.environ["FIREBASE_PROJECT_ID"]
    path = os.environ.get("FIREBASE_CREDENTIALS")
    if not path:
        return None
    p = Path(path)
    if not p.is_absolute():
        p = Path(__file__).resolve().parents[1] / p     # 컨테이너 /srv/secrets/…, 로컬 ai/secrets/… (없으면 None)
        if not p.exists():
            p = Path(__file__).resolve().parents[2] / path
    try:
        return json.loads(p.read_text(encoding="utf-8")).get("project_id")
    except (OSError, ValueError):
        return None


def verify_token(token: str) -> str:
    """토큰 → uid. 실패하면 HTTPException(401)."""
    token = (token or "").strip()
    if not token:
        raise HTTPException(401, "로그인이 필요합니다.")
    if token.startswith("dev:"):
        uid = token[4:].strip()
        if (os.environ.get("API_AUTH_MODE") or "firebase") != "dev" or not uid:
            raise HTTPException(401, "개발용 토큰은 쓸 수 없습니다.")
        return uid
    project = firebase_project_id()
    if not project:
        raise HTTPException(503, "로그인 확인 설정이 없습니다 (FIREBASE_CREDENTIALS).")
    try:
        from google.auth.transport import requests as g_requests
        from google.oauth2 import id_token
        claims = id_token.verify_firebase_token(token, g_requests.Request(), audience=project, clock_skew_in_seconds=10)
    except ValueError as e:
        raise HTTPException(401, "로그인이 만료되었거나 올바르지 않습니다. 다시 시도해 주세요.") from e
    except Exception as e:  # noqa: BLE001 — 공개키를 못 받는 등
        logger.warning("Firebase 토큰 확인 실패 (%s)", type(e).__name__)
        raise HTTPException(503, "로그인을 지금 확인할 수 없습니다.") from e
    uid = (claims or {}).get("user_id") or (claims or {}).get("sub")
    if not uid:
        raise HTTPException(401, "로그인 정보를 확인하지 못했습니다.")
    return uid


def current_uid(authorization: str | None = Header(default=None)) -> str:
    """FastAPI 의존성: Authorization 헤더의 Bearer 토큰 → uid."""
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer":
        raise HTTPException(401, "로그인이 필요합니다.")
    return verify_token(token)
