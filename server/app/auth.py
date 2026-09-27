"""Firebase ID 토큰 검증 (명세 5장)

앱: FirebaseAuth.instance.signInAnonymously() → currentUser.getIdToken()
    모든 요청 헤더  Authorization: Bearer <idToken>   (만료 1시간, SDK 가 자동 갱신)
서버: firebase_admin.auth.verify_id_token() → uid  (→ users.firebase_uid, 사용자 테이블 연결은 A5)

라우터에서 사용
    uid 필수   : user: AuthUser = Depends(current_user)
    uid 선택   : user: Optional[AuthUser] = Depends(optional_user)
    /internal  : Depends(require_internal)

AUTH_MODE=dev 이면 'Bearer dev:<아무 uid>' 도 통과 (Firebase 없이 C·B 가 목업 API 를 호출할 때).
운영(배포 VM)에서는 반드시 AUTH_MODE=firebase.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Optional

from fastapi import Header, Request

from .config import settings
from .errors import ApiError

log = logging.getLogger(__name__)
_firebase_app = None
_firebase_failed_at = 0.0          # 초기화 실패 시 60초 동안 재시도하지 않음 (요청마다 경고 로그 방지)


@dataclass(frozen=True)
class AuthUser:
    uid: str
    is_anonymous: bool = True
    provider: str = "anonymous"
    dev: bool = False


def init_firebase() -> bool:
    """앱 시작 시 1회. 성공 여부 반환 (실패해도 서버는 뜨고, 인증 요청만 401)."""
    global _firebase_app, _firebase_failed_at
    import time
    if _firebase_app is not None:
        return True
    if time.monotonic() - _firebase_failed_at < 60 and _firebase_failed_at:
        return False
    try:
        import firebase_admin
        from firebase_admin import credentials

        cred = credentials.Certificate(settings.firebase_credentials) if settings.firebase_credentials \
            else credentials.ApplicationDefault()
        opts = {"projectId": settings.firebase_project_id} if settings.firebase_project_id else None
        _firebase_app = firebase_admin.initialize_app(cred, opts)
        log.info("Firebase Admin 초기화 완료")
        return True
    except Exception as e:  # noqa: BLE001
        log.warning("Firebase Admin 초기화 실패 (%s) — AUTH_MODE=%s", e, settings.auth_mode)
        _firebase_failed_at = time.monotonic()
        return False


def _verify_firebase(token: str) -> AuthUser:
    if _firebase_app is None and not init_firebase():
        raise ApiError("UNAUTHORIZED", detail="firebase_not_configured")
    from firebase_admin import auth

    try:
        claims = auth.verify_id_token(token, app=_firebase_app, clock_skew_seconds=10)
    except auth.ExpiredIdTokenError:
        raise ApiError("UNAUTHORIZED", "로그인이 만료되었습니다. 다시 시도해 주세요.", detail="token_expired")
    except (auth.RevokedIdTokenError, auth.UserDisabledError):
        raise ApiError("UNAUTHORIZED", detail="token_revoked")
    except (auth.InvalidIdTokenError, ValueError):
        raise ApiError("UNAUTHORIZED", detail="token_invalid")
    except auth.CertificateFetchError:
        raise ApiError("UPSTREAM_UNAVAILABLE", detail="firebase_cert_fetch_failed")
    provider = (claims.get("firebase") or {}).get("sign_in_provider", "")
    return AuthUser(uid=claims["uid"], is_anonymous=provider == "anonymous", provider=provider)


def verify_token(token: str) -> AuthUser:
    """토큰 문자열 → AuthUser. 실패 시 ApiError(UNAUTHORIZED)."""
    token = (token or "").strip()
    if not token:
        raise ApiError("UNAUTHORIZED", detail="missing_token")
    if token.startswith("dev:"):
        uid = token[4:].strip()
        if settings.auth_mode != "dev" or not uid:
            raise ApiError("UNAUTHORIZED", detail="dev_token_not_allowed")
        return AuthUser(uid=uid, provider="dev", dev=True)
    return _verify_firebase(token)


def _bearer(authorization: Optional[str]) -> Optional[str]:
    if not authorization:
        return None
    scheme, _, token = authorization.partition(" ")
    return token.strip() if scheme.lower() == "bearer" and token.strip() else None


def current_user(request: Request, authorization: Optional[str] = Header(default=None)) -> AuthUser:
    token = _bearer(authorization)
    if token is None:
        raise ApiError("UNAUTHORIZED", detail="missing_token")
    user = verify_token(token)
    request.state.uid = user.uid
    return user


def optional_user(request: Request, authorization: Optional[str] = Header(default=None)) -> Optional[AuthUser]:
    token = _bearer(authorization)
    return current_user(request, authorization) if token else None


def require_internal(x_internal_token: Optional[str] = Header(default=None)) -> None:
    """/internal/* — INTERNAL_TOKEN 이 설정돼 있으면 X-Internal-Token 일치 필요, 없으면 dev 모드에서만 허용"""
    if settings.internal_token:
        if x_internal_token != settings.internal_token:
            raise ApiError("UNAUTHORIZED", detail="internal_token")
    elif settings.auth_mode != "dev":
        raise ApiError("UNAUTHORIZED", detail="internal_token_not_configured")
