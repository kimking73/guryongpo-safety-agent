"""외부 API 호출 (live) 또는 저장된 원문 재생 (replay)

- live  : httpx 로 호출. 이미 인코딩된 키(%2B 등)는 한 번 디코딩 후 인코딩 (이중 인코딩 시 포항 DT 40102)
- replay: settings.replay_dir/<name>.json|.txt 를 그대로 반환 (네트워크 없는 곳에서 개발·시연·테스트)
응답 본문은 문자열로 돌려주고, 파싱은 converters 가 한다 (포항 DT 의 '{' 누락 보정 포함).
"""
from __future__ import annotations

import time
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import httpx

from app.config import settings

KST = timezone(timedelta(hours=9))
KMA = "https://apihub.kma.go.kr/api"


class FetchError(Exception):
    pass


@dataclass
class Response:
    name: str
    status: int
    text: str
    url: str          # 키를 가린 URL (로그·ingest_runs.error 용)


def _decode(b: bytes) -> str:
    for enc in ("utf-8", "cp949"):     # 기상청 typ01 텍스트는 EUC-KR 인 경우가 있음
        try:
            return b.decode(enc)
        except UnicodeDecodeError:
            pass
    return b.decode("utf-8", errors="replace")


def _mask(url: str) -> str:
    for k in ("serviceKey", "authKey"):
        if k + "=" in url:
            head, _, tail = url.partition(k + "=")
            url = head + k + "=***" + ("&" + tail.split("&", 1)[1] if "&" in tail else "")
    return url


def get(name: str, url: str, params: dict[str, str], timeout: float | None = None, retries: int = 1) -> Response:
    """name 은 replay 파일 이름과 같다 (1주차 fetch_dt.py 의 dt_apis.json name 과 동일).
    시간 초과·연결 오류는 retries 번 더 시도 (기상청 typ01 텍스트 API 가 가끔 20초 넘게 응답 없음)"""
    if settings.fetch_mode == "replay":
        for ext in (".json", ".txt"):
            p = settings.replay_dir / f"{name}{ext}"
            if p.is_file():
                return Response(name, 200, p.read_text(encoding="utf-8"), f"replay:{p.name}")
        raise FetchError(f"replay 파일 없음: {settings.replay_dir}/{name}.json|.txt")

    q = urllib.parse.urlencode({k: urllib.parse.unquote(str(v)) for k, v in params.items()})
    full = f"{url}?{q}" if q else url
    for attempt in range(retries + 1):
        try:
            r = httpx.get(full, timeout=timeout or settings.http_timeout,
                          headers={"User-Agent": "guryong-collector/1.0"})
            break
        except (httpx.TimeoutException, httpx.NetworkError) as e:
            if attempt < retries:
                time.sleep(3)
                continue
            raise FetchError(f"{type(e).__name__} ({attempt + 1}회 시도): {e} ({_mask(full)})") from e
        except httpx.HTTPError as e:
            raise FetchError(f"{type(e).__name__}: {e} ({_mask(full)})") from e
    if r.status_code >= 400:
        raise FetchError(f"HTTP {r.status_code} ({_mask(full)}): {r.text[:200]}")
    return Response(name, r.status_code, _decode(r.content), _mask(full))


# ------------------------------------------------------------------ 호출 시각 계산 (fetch_dt.kma_times 이식)
def kma_times(now: datetime | None = None) -> dict[str, str]:
    """기상청 발표 시각 자동 계산 (KST, 발표 후 반영 지연 고려)
    초단기실황 매시 정각(+40분) · 초단기예보 매시 30분(+45분) · 단기예보 02·05·…·23시(+10분, 여유 15분)
    중기예보 06·18시(+20분) · AWS 매분(3분 전) · 태풍 API 는 UTC"""
    now = (now or datetime.now(KST)).astimezone(KST)
    t = now - timedelta(minutes=40)
    ncst = t.replace(minute=0)
    t = now - timedelta(minutes=45)
    fcst = t.replace(minute=30) if t.minute >= 30 else t.replace(minute=30) - timedelta(hours=1)
    t = now - timedelta(minutes=15)
    h = max([x for x in (2, 5, 8, 11, 14, 17, 20, 23) if x <= t.hour], default=None)
    vil = t.replace(hour=h, minute=0) if h is not None else (t - timedelta(days=1)).replace(hour=23, minute=0)
    t = now - timedelta(minutes=20)
    mid = (t.replace(hour=18, minute=0) if t.hour >= 18 else t.replace(hour=6, minute=0) if t.hour >= 6
           else (t - timedelta(days=1)).replace(hour=18, minute=0))
    out = {
        "MID_TMFC": mid.strftime("%Y%m%d%H%M"),
        "AWS_TM": (now - timedelta(minutes=3)).strftime("%Y%m%d%H%M"),
        "AWS_TM_PREV": (now - timedelta(minutes=5)).strftime("%Y%m%d%H%M"),
        "YEAR": now.strftime("%Y"),
        "NOW_TM_UTC": (now - timedelta(minutes=5)).astimezone(timezone.utc).strftime("%Y%m%d%H%M"),
    }
    for k, d in (("NCST", ncst), ("FCST", fcst), ("VIL", vil)):
        out[k + "_DATE"], out[k + "_TIME"] = d.strftime("%Y%m%d"), d.strftime("%H%M")
    return out
