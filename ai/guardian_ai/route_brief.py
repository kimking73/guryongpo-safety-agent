"""AI 경로 설명 (2026-10-11): 대시보드 지도에 그린 경로의 주의할 점·위험 요소를 짧게 풀어 준다 — POST /api/ai/route-brief.

대화 그래프(graph.py)를 돌리지 않는다. 경로를 바꿀 때마다 불리므로 가볍게:
  ① 근거는 코드가 모은다 — 앱이 보낸 경로 서버 응답 + 출발·도착 지점 위험(hazards_at) + 특보·비·바람(tools.py)
  ② 문장은 LLM 한 번 (llm.OpenAIRouteBriefWriter). 근거에 없는 길 이름·수치를 쓰지 못하게 한다
  ③ 숫자는 규칙으로 검사(verify.check_numbers). 틀리거나 LLM이 실패하면 코드가 만든 문장(template_brief)으로 대체
상태·대화 기억 없음. 같은 요청은 CACHE_S 동안 다시 계산하지 않는다 (화면 다시 그리기·왕복 전환).
"""

from __future__ import annotations

import hashlib
import logging
import math
import threading
import time
from typing import Any, Callable, Literal

from pydantic import BaseModel, Field

from . import demo, tools, tracing
from .flood import evidence_lines
from .state import Evidence
from .verify import check_numbers

logger = logging.getLogger(__name__)

CACHE_S = 60
MAX_ITEMS = 3
# 이보다 짧은 급한 오르막·계단은 말하지 않는다 (몇 m짜리 턱까지 주의로 뜨면 정작 중요한 것이 묻힌다)
MIN_NOTABLE_M = 20
STRATEGY_KO = {"shortest": "가까운 경로 (위험 구역을 따지지 않고 계산)", "safest": "안전한 경로",
               "fastest": "안전한 경로", "flat": "안전한 경로 + 오르막을 줄인 길",
               "uphill": "오르막을 줄인 길 (위험 구역을 따지지 않고 계산)"}
# 피한 구역이 없는데 "피해 간다"고 쓰면 틀린 안심이 된다 → 이 말이 있으면 LLM 문장을 버린다
AVOID_WORDS = ("피해", "피했", "피한", "우회")
# 길에 영향이 있을 때만 근거에 넣는다 — 비 0mm·약한 바람까지 넣으면 "걱정 없다"는 말을 지어낸다
NOTABLE = {"rain_1h": 1.0, "wind_speed": 9.0, "wind_gust": 14.0}
MIN_ASCEND_M = 15
LEVEL_KO = {"watch": "예비특보", "advisory": "주의보", "warning": "경보", "critical": "경보"}
NOTE = "경사·계단 길이는 경로 서버의 고도 자료(90m 격자) 기준이라 실제와 다를 수 있습니다."


class Point(BaseModel):
    lat: float
    lon: float
    name: str | None = None


class RouteFacts(BaseModel):
    """경로 서버 /api/route 응답에서 설명에 쓰는 값 (모르는 키는 무시)."""
    distance_m: int
    duration_s: int
    ascend_m: int = 0
    max_uphill_pct: int = 0
    steps_m: int = 0
    steep_up_m: int = 0
    very_steep_up_m: int = 0
    avoided: list[str] = Field(default_factory=list)
    still_inside: list[str] = Field(default_factory=list)
    hazards_ok: bool = True
    mode: Literal["walk", "car"] = "walk"
    strategy: str | None = None
    profile: str = "adult"
    geometry: str = ""


class RouteBriefRequest(BaseModel):
    origin: Point
    destination: Point
    route: RouteFacts
    zone_names: dict[str, str] = Field(default_factory=dict)   # 위험 구역 id → 이름 (앱이 가진 값). 없으면 id 그대로
    demo: bool = False


class RouteBriefResponse(BaseModel):
    summary: str                                   # 이 경로 한 줄
    cautions: list[str] = Field(default_factory=list)   # 주의할 점 (오르막·계단·비·바람)
    hazards: list[str] = Field(default_factory=list)    # 위험한 요소 (지나는 위험 구역·출발/도착 지점 위험·특보)
    note: str = NOTE
    used_template: bool = False                    # True면 LLM 문장 대신 코드가 만든 문장
    timings: dict[str, float] = Field(default_factory=dict)


# (근거 표기, 템플릿 문장) → (summary, cautions, hazards). 실패하면 예외
Writer = Callable[[str, "RouteBriefResponse"], tuple[str, list[str], list[str]]]


def _names(ids: list[str], names: dict[str, str]) -> str:
    """구역 이름 묶음. 이름이 '침수 경보'처럼 종류·단계라 여러 구역이 같은 이름일 수 있다 → "침수 경보 2곳, 산사태 경고"."""
    count: dict[str, int] = {}
    for i in ids:
        n = names.get(i) or i
        count[n] = count.get(n, 0) + 1
    return ", ".join(n if c == 1 else f"{n} {c}곳" for n, c in count.items())


def build_evidence(req: RouteBriefRequest, fetch=None) -> tuple[list[Evidence], list[str]]:
    """근거 목록과 확인하지 못한 항목 이름. tool이 실패하면 그 항목만 빠진다 (답은 계속 나간다)."""
    r, missing = req.route, []
    walk = r.mode == "walk"
    ev = [Evidence(source="request", key="출발지", value=req.origin.name or "현위치"),
          Evidence(source="request", key="도착지", value=req.destination.name or "도착지"),
          Evidence(source="route", key="이동 수단", value="도보" if walk else "자동차"),
          Evidence(source="route", key="경로 거리", value=r.distance_m, unit="m"),
          Evidence(source="route", key="소요 시간", value=math.ceil(r.duration_s / 60), unit="분")]
    if r.strategy in STRATEGY_KO:
        ev.append(Evidence(source="route", key="경로 방식", value=STRATEGY_KO[r.strategy]))
    if walk:
        if r.ascend_m >= MIN_ASCEND_M:
            ev.append(Evidence(source="route", key="오르막 합계", value=r.ascend_m, unit="m"))
        if r.steep_up_m >= MIN_NOTABLE_M:
            ev += [Evidence(source="route", key="급한 오르막 길이 (매우 급한 구간 포함)", value=r.steep_up_m, unit="m"),
                   Evidence(source="route", key="가장 급한 오르막 경사", value=r.max_uphill_pct, unit="%")]
            if r.very_steep_up_m >= MIN_NOTABLE_M:
                ev.append(Evidence(source="route", key="그중 매우 급한 구간(노약자·휠체어 통행 한계 초과) 길이",
                                   value=r.very_steep_up_m, unit="m"))
        if r.steps_m >= MIN_NOTABLE_M:
            ev.append(Evidence(source="route", key="계단 길이", value=r.steps_m, unit="m"))
    inside, avoided = _names(r.still_inside, req.zone_names), _names(r.avoided, req.zone_names)
    if inside:
        ev.append(Evidence(source="route", key=f"다른 길이 없어 지나는 위험 구역 {len(r.still_inside)}곳", value=inside))
    if avoided:
        ev.append(Evidence(source="route", key=f"이 경로가 피한 위험 구역 {len(r.avoided)}곳", value=avoided))
    if not inside and r.hazards_ok and r.strategy not in ("shortest", "uphill"):
        ev.append(Evidence(source="route", key="경로 위 위험 구역", value="없음"))
    if not r.hazards_ok:
        missing.append("위험 구역 정보 (위험 구역을 피하지 않고 계산한 경로)")

    for label, p in (("출발지", req.origin), ("도착지", req.destination)):
        h = tools.hazards_at(p.lat, p.lon, fetch=fetch)
        if not h.get("available"):
            missing.append(f"{label} 위험 여부")
        elif h.get("labels"):
            ev.append(Evidence(source="risk_assessments", key=f"{label} 위험", value=f"지금 위험 영역 안({h['labels']})"))

    w = tools.get_weather_warnings(fetch=fetch)
    if not w.get("available"):
        missing.append("기상특보")
    else:
        active = [i for i in w["items"] if i["status"] == "active"]
        if active:
            ev.append(Evidence(source="weather_warnings", key="발효 중인 특보",
                               value=", ".join(dict.fromkeys(i["headline"] or f"{i['hazard']} {LEVEL_KO.get(i['level'], '')}"
                                                             for i in active))))
    for kind, wanted in (("rain", {"rain_1h": ("1시간 강수량", "mm")}),
                         ("wind", {"wind_speed": ("평균 풍속", "m/s"), "wind_gust": ("순간최대풍속", "m/s")})):
        o = tools.get_observations(kind, req.origin.lat, req.origin.lon, fetch=fetch)
        if not o.get("available"):
            missing.append("비 관측값" if kind == "rain" else "바람 관측값")
            continue
        seen: set[str] = set()
        for i in o["items"]:
            if i["metric"] in wanted and i["metric"] not in seen and not i.get("stale") and i["value"] is not None:
                seen.add(i["metric"])
                if float(i["value"]) < NOTABLE[i["metric"]]:
                    continue
                name, unit = wanted[i["metric"]]
                ev.append(Evidence(source="observations", key=f"{name} (관측소: {i['station']})", value=float(i["value"]), unit=unit))
    return ev, missing


def template_brief(req: RouteBriefRequest, ev: list[Evidence], missing: list[str]) -> RouteBriefResponse:
    """LLM 없이 근거로 만든 문장 (LLM 실패·숫자 검사 실패 때, 그리고 LLM에게 주는 뼈대)."""
    r = req.route
    by = {e.key: e for e in ev}
    dest = req.destination.name or "도착지"
    summary = f"{dest}까지 {r.distance_m}m, {'걸어서' if r.mode == 'walk' else '차로'} 약 {math.ceil(r.duration_s / 60)}분입니다."
    avoided = next((e for e in ev if e.key.startswith("이 경로가 피한 위험 구역")), None)
    if avoided is not None:
        summary += f" 위험 구역을 피해 가는 길입니다 ({avoided.value})."
    hazards, cautions = [], []
    inside = next((e for e in ev if e.key.startswith("다른 길이 없어 지나는 위험 구역")), None)
    if inside is not None:
        hazards.append(f"다른 길이 없어 위험 구역을 지납니다: {inside.value}. 그 구간은 특히 조심하세요.")
    for label in ("출발지", "도착지"):
        if f"{label} 위험" in by:
            hazards.append(f"{label}가 {by[f'{label} 위험'].value}입니다.")
    if "발효 중인 특보" in by:
        hazards.append(f"발효 중인 특보: {by['발효 중인 특보'].value}")
    if not r.hazards_ok:
        hazards.append("위험 구역 정보를 확인하지 못해, 위험 구역을 피하지 않고 계산한 경로입니다.")
    if r.mode == "walk":
        if r.steep_up_m >= MIN_NOTABLE_M:
            very = (f" 그중 {r.very_steep_up_m}m는 노약자·휠체어가 다니기 힘든 매우 급한 구간입니다."
                    if r.very_steep_up_m >= MIN_NOTABLE_M else "")
            cautions.append(f"급한 오르막이 {r.steep_up_m}m 있습니다 (가장 급한 곳 {r.max_uphill_pct}%).{very}")
        if r.steps_m >= MIN_NOTABLE_M:
            cautions.append(f"계단이 {r.steps_m}m 있습니다.")
    for e in ev:
        if e.source == "observations" and e.key.startswith("1시간 강수량") and float(e.value) > 0:
            cautions.append(f"지금 비가 옵니다 (1시간 강수량 {_num(e.value)}mm). 길이 미끄럽습니다.")
        if e.source == "observations" and e.key.startswith("순간최대풍속") and float(e.value) >= 14:
            cautions.append(f"바람이 셉니다 (순간최대풍속 {_num(e.value)}m/s). 간판·나뭇가지를 조심하세요.")
    if missing:
        cautions.append("확인하지 못한 정보: " + ", ".join(missing))
    return RouteBriefResponse(summary=summary, cautions=cautions[:MAX_ITEMS + 1], hazards=hazards[:MAX_ITEMS + 1],
                              used_template=True)


def _num(v: Any) -> str:
    return str(int(v)) if isinstance(v, float) and v.is_integer() else str(v)


class RouteBriefService:
    """writer가 없으면 템플릿 문장만 (테스트·OpenAI 키 없는 환경)."""

    def __init__(self, writer: Writer | None = None, fetch=None, now: Callable[[], float] = time.monotonic):
        self.writer, self.fetch, self._now = writer, fetch, now
        self._cache: dict[str, tuple[float, RouteBriefResponse]] = {}
        self._lock = threading.Lock()

    def brief(self, req: RouteBriefRequest) -> RouteBriefResponse:
        key = hashlib.sha256(req.model_dump_json().encode()).hexdigest()
        with self._lock:
            for k, (t, _) in list(self._cache.items()):
                if self._now() - t > CACHE_S:
                    self._cache.pop(k)
            hit = self._cache.get(key)
        if hit is not None:
            return hit[1].model_copy(update={"timings": {"total": 0.0, "cached": 1.0}})

        started = time.perf_counter()
        with demo.active(req.demo), tracing.scope(req.demo):
            ev, missing = build_evidence(req, self.fetch)
            t_ev = time.perf_counter()
            out = template_brief(req, ev, missing)
            if self.writer is not None:
                try:
                    lines = evidence_lines(ev) + ("\n확인할 수 없는 정보: " + ", ".join(missing) if missing else "")
                    summary, cautions, hazards = self.writer(lines, out)
                    text = "\n".join([summary, *cautions, *hazards])
                    check = check_numbers(text, ev)
                    if not summary.strip():
                        raise ValueError("빈 요약")
                    if not req.route.avoided and any(w in text for w in AVOID_WORDS):
                        logger.info("경로 설명: 피한 구역이 없는데 피했다고 씀 → 템플릿")
                    elif check.ok:
                        out = RouteBriefResponse(summary=summary.strip(), cautions=cautions[:MAX_ITEMS],
                                                 hazards=hazards[:MAX_ITEMS], used_template=False)
                    else:
                        logger.info("경로 설명 숫자 검사 실패 → 템플릿 (%s)", check.feedback)
                except Exception as e:  # noqa: BLE001 — 설명 실패로 경로 안내가 끊기면 안 된다
                    logger.warning("경로 설명 작성 실패 → 템플릿 (%s: %s)", type(e).__name__, e)
        done = time.perf_counter()
        out.timings = {"evidence": round(t_ev - started, 2), "write": round(done - t_ev, 2), "total": round(done - started, 2)}
        logger.info("경로 설명 %.1fs%s %s", out.timings["total"], " [시연]" if req.demo else "",
                    "템플릿" if out.used_template else "LLM")
        with self._lock:
            self._cache[key] = (self._now(), out)
        return out
