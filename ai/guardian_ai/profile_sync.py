"""대화에서 들은 사용자 정보 → 서버 프로필 (2026-10-08 사용자 결정: 프로필 하나만 쓴다).

사용자 프로필은 서버 DB 한 곳(user_profiles·user_places)에만 있다. 앱 프로필 화면도, AI 답변도 여기를 읽는다.
AI는 답한 뒤 백그라운드로 이번 문답에서 사용자가 자기에 대해 말한 것을 뽑아(llm.OpenAIMemoryExtractor)
서버 API(PATCH /api/v1/user, /api/v1/user/places)로 바로 고친다 — **사용자 본인의 로그인 토큰**으로 부르므로
AI에 DB 쓰기 권한을 따로 주지 않고, 앱 프로필 화면에서 고칠 때와 같은 검증·저장 규칙을 탄다.
규칙: 프로필 값과 다르면 덮어쓴다(가장 최근에 말한 것·고친 것이 이긴다). 자주 가는 곳은 같은 이름이 없을 때만 더한다.
장기 기억 저장소(ai_memory.store)는 더 이상 읽지도 쓰지도 않는다 (예전 데이터는 DB에 그대로 남겨 둠).
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

import httpx

logger = logging.getLogger(__name__)
KST = timezone(timedelta(hours=9))
DEFAULT_API_URL = "http://localhost:8000"   # 컨테이너 안에서는 compose가 API_URL=http://api:8000

# 사용자가 말한 직업 → 서버 코드 (앱 프로필 화면 직업 칩과 같은 코드, app AccountSync.jobCode). 못 찾으면 말한 그대로
JOB_KEYWORDS = [
    ("fisher", ("어업", "어부", "어민", "선원", "뱃사람", "선장", "수산", "해녀", "어선", "배를 ", "배 타")),
    ("farmer", ("농업", "농사", "농부", "농민", "과수")),
    ("merchant", ("자영업", "장사", "상인", "가게", "식당", "사장")),
    ("office", ("직장인", "회사원", "공무원", "사무")),
    ("student", ("학생",)),
]
MOBILITY = {"walk": "walk", "car": "car", "wheelchair": "wheelchair", "public_transport": "public_transit"}


def job_code(text: str) -> str:
    t = (text or "").strip()
    for code, words in JOB_KEYWORDS:
        if any(w in t for w in words):
            return code
    return t


def _bool(value: Any) -> bool:
    return str(value).strip().lower() in ("true", "1", "yes", "예", "네")


def to_patch(facts, today: datetime | None = None) -> dict[str, Any]:
    """추출한 사실 → PATCH /api/v1/user 본문 (서버 ProfileInput). 해석 못 한 값은 뺀다."""
    out: dict[str, Any] = {}
    year = (today or datetime.now(KST)).year
    for f in facts:
        v = str(f.value).strip()
        if not v:
            continue
        try:
            if f.field == "age":
                age = int(float(v))
                if 0 < age < 120:
                    out["birth_year"] = year - age
            elif f.field == "walking_impaired":
                out["walking_ability"] = "limited" if _bool(v) else "normal"
            elif f.field in ("has_dependents", "vision_impaired", "hearing_impaired"):
                out[f.field] = _bool(v)
            elif f.field == "mobility" and v in MOBILITY:
                out["mobility"] = MOBILITY[v]
            elif f.field == "occupation":
                out["occupation"] = job_code(v)
                out["owns_vessel"] = out["occupation"] == "fisher"    # 앱과 같은 규칙 (어업이면 배 보유)
        except (TypeError, ValueError):
            continue
    return out


def place_facts(facts) -> list[tuple[str, str]]:
    """[(place_type, 말한 장소)] — 집 주소는 하나(마지막 것), 자주 가는 곳은 여러 개"""
    homes = [str(f.value).strip() for f in facts if f.field == "home_address" and str(f.value).strip()]
    others = [str(f.value).strip() for f in facts if f.field == "frequent_place" and str(f.value).strip()]
    return ([("home", homes[-1])] if homes else []) + [("frequent", p) for p in dict.fromkeys(others)]


class ProfileWriter:
    """서버 프로필을 사용자 토큰으로 고친다. client: 테스트에서 가짜 api 서버를 넣을 때만."""

    def __init__(self, client: httpx.Client | None = None, locate: Callable[[str], dict | None] | None = None):
        self.http = client or httpx.Client(base_url=os.environ.get("API_URL") or DEFAULT_API_URL, timeout=10)
        self.locate = locate

    def apply(self, token: str, facts, today: datetime | None = None) -> dict[str, Any]:
        """사실 목록을 서버 프로필에 반영. 돌려줌: {"profile": 바꾼 칸, "places": 더하거나 바꾼 장소}
        POST /user (uid 기준 멱등 — 사용자가 아직 없으면 만들고, 보낸 칸만 저장, 장소 목록까지 돌려줌)"""
        done: dict[str, Any] = {"profile": {}, "places": []}
        patch = to_patch(facts, today)
        wanted = place_facts(facts)
        if not patch and not wanted:
            return done
        r = self.http.post("/api/v1/user", json=patch, headers=_auth(token))
        r.raise_for_status()
        done["profile"] = patch
        places = r.json().get("places") or []
        for kind, said in wanted:
            where = self.locate(said) if self.locate else None
            if not where:
                logger.info("장소 좌표를 찾지 못해 프로필에 넣지 않음: %s", said)
                continue
            body = {"place_type": kind, "label": "집" if kind == "home" else said[:40],
                    "address": (where.get("address") or said)[:300],
                    "location": {"lat": where["lat"], "lng": where["lon"]}, "notify": True}
            home = next((p for p in places if p.get("place_type") == "home"), None) if kind == "home" else None
            if kind == "frequent" and any(p.get("label") == body["label"] for p in places):
                continue
            if home:
                body["label"] = home.get("label") or "집"
                r = self.http.patch(f"/api/v1/user/places/{home['id']}", json=body, headers=_auth(token))
            else:
                r = self.http.post("/api/v1/user/places", json=body, headers=_auth(token))
            r.raise_for_status()
            done["places"].append(body["label"] if kind == "frequent" else f"집({said})")
        return done


def describe(profile) -> list[str]:
    """추출기에 알려 줄 '지금 프로필' (이미 아는 것은 다시 뽑지 않게)"""
    lines = []
    if profile.age is not None:
        lines.append(f"나이: {profile.age}")
    if profile.walking_impaired is not None:
        lines.append(f"보행 불편: {profile.walking_impaired}")
    if profile.has_dependents is not None:
        lines.append(f"보호가 필요한 동반자: {profile.has_dependents}")
    if profile.mobility is not None:
        lines.append(f"이동수단: {profile.mobility.value}")
    if profile.occupation:
        lines.append(f"직업: {profile.occupation}")
    if profile.home is not None:
        lines.append(f"집: {profile.home.label or '등록됨'}")
    lines += [f"자주 가는 곳: {p.label}" for p in profile.frequent_places if p.label]
    return lines


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}
