"""설정 — 환경 변수 (저장소 루트 .env → compose env_file) + 로컬 개발용 server/dt_config.txt

우선순위: 실제 환경 변수 > server/dt_config.txt (로컬에서 tools/·수집기를 직접 돌릴 때)
빈 값은 '설정 안 함'으로 취급한다. 키 값은 절대 커밋하지 않는다 (.env.example 만 공유).
키 이름은 루트 .env.example 규칙(영역 접두사)을 따르고, 1주차 이름(DT_KEY 등)도 계속 읽는다.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

SERVER_DIR = Path(__file__).resolve().parent.parent          # server/
REPO_DIR = SERVER_DIR.parent


def _read_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            v = re.split(r"\s+#", v, maxsplit=1)[0]          # 값 뒤 ' # 설명' 주석 제거
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def _env() -> dict[str, str]:
    env = _read_env_file(Path(os.environ.get("DT_CONFIG", SERVER_DIR / "dt_config.txt")))
    env.update({k: v for k, v in os.environ.items() if v != ""})
    return env


def _get(e: dict[str, str], *names: str, default: Optional[str] = None) -> Optional[str]:
    """새 이름 → 1주차 이름 순서로 찾음"""
    for n in names:
        if e.get(n):
            return e[n]
    return default


def _bool(v: Optional[str], default: bool = False) -> bool:
    if v is None or v == "":
        return default
    return v.strip().lower() in ("1", "true", "yes", "on")


def _existing_path(p: Optional[str]) -> Optional[str]:
    """상대 경로면 현재 폴더 → 저장소 루트 순으로 찾음 (.env 의 secrets/firebase-admin.json)"""
    if not p:
        return None
    for cand in (Path(p), REPO_DIR / p):
        if cand.is_file():
            return str(cand)
    return p


@dataclass(frozen=True)
class Settings:
    database_url: str = "postgresql://guardian:guardian-local-only@localhost:5433/guardian"
    # 인증: firebase = ID 토큰 검증 / dev = 'Bearer dev:<uid>' 도 허용 (로컬·목업 개발용, 운영 금지)
    auth_mode: str = "firebase"
    firebase_credentials: Optional[str] = None  # 서비스 계정 JSON 경로 (없으면 GOOGLE_APPLICATION_CREDENTIALS / 기본 자격)
    firebase_project_id: Optional[str] = None
    internal_token: Optional[str] = None        # /internal/* 호출용 (X-Internal-Token). 없으면 dev 모드에서만 허용
    mock_dir: Path = SERVER_DIR / "mock"
    # 수집기
    fetch_mode: str = "live"                    # live = 실제 API 호출 / replay = replay_dir 의 저장된 원문 사용
    replay_dir: Path = SERVER_DIR / "mock" / "external"
    enable_scheduler: bool = False              # API 프로세스 안에서 스케줄러 실행 (로컬 편의용. 보통은 collector 컨테이너)
    http_timeout: float = 20.0
    dt_base_url: str = "https://genix.pohang-eum.kr/dpg"
    dt_key: Optional[str] = None
    kma_key: Optional[str] = None
    data_go_kr_key: Optional[str] = None       # 공공데이터포털 (국립중앙의료원 응급실 가용병상)
    safetydata_key: Optional[str] = None       # 재난안전데이터공유플랫폼 (긴급재난문자) — 등록 IP 에서만 동작
    # 다른 서비스 상태 확인 (설정된 것만 /health 에 표시)
    route_health_url: Optional[str] = None
    ai_health_url: Optional[str] = None
    version: str = "0.3.0"
    cors_origins: list[str] = field(default_factory=lambda: ["*"])


def load_settings() -> Settings:
    e = _env()
    return Settings(
        database_url=_get(e, "DATABASE_URL", default=Settings.database_url),
        auth_mode=_get(e, "API_AUTH_MODE", "AUTH_MODE", default="firebase").lower(),
        firebase_credentials=_existing_path(_get(e, "FIREBASE_CREDENTIALS")),
        firebase_project_id=_get(e, "FIREBASE_PROJECT_ID", "GCP_PROJECT_ID"),
        internal_token=_get(e, "API_INTERNAL_TOKEN", "INTERNAL_TOKEN"),
        mock_dir=Path(_get(e, "MOCK_DIR", default=str(SERVER_DIR / "mock"))),
        fetch_mode=_get(e, "COLLECTOR_FETCH_MODE", "FETCH_MODE", default="live").lower(),
        replay_dir=Path(_get(e, "REPLAY_DIR", default=str(SERVER_DIR / "mock" / "external"))),
        enable_scheduler=_bool(_get(e, "COLLECTOR_IN_API", "ENABLE_SCHEDULER")),
        http_timeout=float(_get(e, "COLLECTOR_HTTP_TIMEOUT", "HTTP_TIMEOUT", default="20")),
        dt_base_url=_get(e, "POHANG_TWIN_BASE_URL", "DT_BASE_URL", default=Settings.dt_base_url).rstrip("/"),
        dt_key=_get(e, "POHANG_TWIN_API_KEY", "DT_KEY"),
        kma_key=_get(e, "KMA_API_KEY", "KMA_KEY"),
        data_go_kr_key=_get(e, "DATA_GO_KR_API_KEY", "DATA_GO_KR_KEY"),
        safetydata_key=_get(e, "SAFETY24_API_KEY", "SAFETYDATA_KEY"),
        route_health_url=_get(e, "ROUTE_HEALTH_URL"),
        ai_health_url=_get(e, "AI_HEALTH_URL"),
        cors_origins=[x.strip() for x in _get(e, "API_CORS_ORIGINS", "CORS_ORIGINS", default="*").split(",") if x.strip()],
    )


settings = load_settings()
