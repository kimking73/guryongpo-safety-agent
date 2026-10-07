"""시연 모드 (2026-10-07): 앱이 시연 모드면 AI도 같은 시연 데이터로 답한다.

서버 시연 데이터(api `/api/v1/demo/*`, server/risk/demo.py)는 실제 센서 위치에 시연 측정값을 넣어 실측과 같은 규칙으로
판정한 것이고 DB에 저장하지 않는다. 그래서 AI는 실시간 표를 같은 이름의 CTE(WITH 절)로 덮어 쓴 SQL을 DB에 보낸다 —
PostgreSQL에서 WITH 이름은 같은 이름의 테이블을 가린다. tools.py의 SQL·판단 규칙은 실측과 그대로이고,
대피소·산사태 취약지역·행동요령 같은 고정 자료는 실제 DB 표를 읽는다.

  risk_assessments    ← /demo/risk/areas (시연 위험 영역, 앱 지도·경로 서버 demo=true가 쓰는 것과 같다)
  observations        ← /demo/layers/stations (시나리오 값이 들어간 관측소 + 실측 자외선·대기)
  weather_warnings    ← /demo/dashboard warnings
  disaster_messages   ← /demo/dashboard disaster_messages
  v_latest_forecasts  ← /demo/dashboard forecast·wave
  ingest_runs         ← 판정이 방금 돈 것으로 (시연 데이터는 늘 최신)

켜는 법: ChatRequest.demo=True → service.py가 요청 동안 `active(True)`. tools._query와 request_route가 이 값을 본다.
LangGraph는 병렬 노드를 돌릴 때 contextvars를 복사하므로 요청 안의 모든 노드에 전해진다.
"""

from __future__ import annotations

import contextlib
import json
import logging
import os
import threading
import time
from contextvars import ContextVar
from typing import Any, Iterator

import httpx

from .db import Fetch

logger = logging.getLogger(__name__)

DEFAULT_API_URL = "http://localhost:8000"   # 컨테이너 안에서는 compose가 API_URL=http://api:8000
API_TIMEOUT_S = 5.0
# 서버 시연 데이터도 60초 캐시라 같은 간격으로 다시 받는다
CACHE_S = 60.0
# /demo/dashboard 기준점 (특보·재난문자·예보는 위치와 상관없다) = 구룡포읍 중심
CENTER = (35.9858, 129.5481)
# 예보 격자 (tools.FORECAST_GRIDS와 같은 두 곳)
GRIDS = ((105, 94), (106, 94))
# 시나리오와 겹치는 실측 관측소(기상청 초단기실황 등)는 빼고, 시나리오가 없는 자외선·대기는 실측 그대로 둔다
REAL_KINDS = ("uv", "air")
METRIC_UNITS = {"rain_15m": "mm", "rain_1h": "mm", "rain_12h": "mm", "rain_day": "mm", "flood_depth": "mm",
                "river_level": "mm", "manhole_level": "mm", "wind_speed": "m/s", "wind_gust": "m/s", "wind_dir": "deg",
                "uv_index": "index", "pm10": "㎍/㎥", "pm25": "㎍/㎥"}

_active: ContextVar[bool] = ContextVar("guardian_demo", default=False)


def is_active() -> bool:
    return _active.get()


@contextlib.contextmanager
def active(on: bool) -> Iterator[None]:
    token = _active.set(on)
    try:
        yield
    finally:
        _active.reset(token)


# --- 시연 데이터 받기 ---------------------------------------------------------

class DemoUnavailable(Exception):
    """api 시연 데이터를 못 받음 → 조회한 tool이 available=False로 답한다 (실측으로 몰래 바꾸지 않는다)."""


class DemoSource:
    """api /api/v1/demo/* → CTE에 넣을 행 목록. CACHE_S 동안 재사용한다."""

    def __init__(self, base_url: str | None = None, client: httpx.Client | None = None, cache_s: float = CACHE_S):
        self.http = client or httpx.Client(base_url=base_url or os.environ.get("API_URL") or DEFAULT_API_URL,
                                           timeout=API_TIMEOUT_S)
        self.cache_s = cache_s
        self._rows: dict[str, Any] | None = None
        self._at = 0.0
        self._lock = threading.Lock()

    def rows(self) -> dict[str, Any]:
        with self._lock:
            if self._rows is None or time.monotonic() - self._at >= self.cache_s:
                self._rows, self._at = self._load(), time.monotonic()
            return self._rows

    def _get(self, path: str, **params: Any) -> dict[str, Any]:
        try:
            res = self.http.get(path, params=params)
            res.raise_for_status()
            return res.json()
        except (httpx.HTTPError, ValueError) as e:
            raise DemoUnavailable(f"시연 데이터를 받지 못했습니다 ({path}: {type(e).__name__})") from e

    def _load(self) -> dict[str, Any]:
        areas = self._get("/api/v1/demo/risk/areas")["features"]
        stations = self._get("/api/v1/demo/layers/stations")["features"]
        dash = self._get("/api/v1/demo/dashboard", lat=CENTER[0], lng=CENTER[1])
        widgets = {w["type"]: w.get("data") or {} for w in dash.get("widgets", [])}
        return {"areas": area_rows(areas), "observations": observation_rows(stations),
                "warnings": warning_rows(widgets.get("warnings", {})),
                "messages": message_rows(widgets.get("disaster_messages", {})),
                "forecasts": forecast_rows(widgets.get("forecast", {}), widgets.get("wave", {}))}


def area_rows(features: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out = []
    for f in features:
        p = f["properties"]
        out.append({"id": f.get("id") or p.get("area_id"), "hazard": p["hazard"], "level": p["level"], "label": p.get("label"),
                    "rule_id": p.get("rule_id"), "basis": {**(f.get("basis") or {}), "reason": p.get("reason")},
                    "geometry": f["geometry"]})
    return out


def observation_rows(features: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out = []
    for f in features:
        p = f["properties"]
        simulated = bool(p.get("simulated"))
        if not simulated and p.get("kind") not in REAL_KINDS:
            continue
        for metric, value in (p.get("metrics") or {}).items():
            if value is None or metric not in METRIC_UNITS:
                continue
            primary = metric == p.get("metric")
            out.append({"station_id": f["id"], "metric": metric, "observed_at": p.get("observed_at"), "value": value,
                        "unit": (p.get("unit") if primary else None) or METRIC_UNITS[metric],
                        "source_level": p.get("source_level") if primary else None,
                        "quality": "simulated" if simulated else None})
    return out


def warning_rows(widget: dict[str, Any]) -> list[dict[str, Any]]:
    return [{"hazard": w["hazard"], "level": w["level"], "region_name": w.get("region_name") or "포항시",
             "issued_at": w.get("issued_at"), "effective_at": w.get("issued_at"), "released_at": None,
             "headline": w.get("label")} for w in widget.get("items", [])]


def message_rows(widget: dict[str, Any]) -> list[dict[str, Any]]:
    return [{"sent_at": m["sent_at"], "sender": m.get("sender"), "region_name": "포항시", "category": None, "hazard": None,
             "alert_class": m.get("alert_class"), "message": m["message"]} for m in widget.get("items", [])]


def forecast_rows(forecast: dict[str, Any], wave: dict[str, Any]) -> list[dict[str, Any]]:
    """시연 예보(1시간 간격) → 기상청 예보 표 모양 (POP·PTY·PCP·WSD, 파고 WAV). 두 격자에 같은 값."""
    base: list[tuple[str, str, str, float | None]] = []
    for s in forecast.get("slots", []):
        pcp = s.get("pcp_mm") or 0
        base += [(s["t"], "POP", str(s["pop"]), s["pop"]),
                 (s["t"], "PTY", "1" if s.get("pty") == "비" else "0", 1 if s.get("pty") == "비" else 0),
                 (s["t"], "PCP", f"{pcp}mm" if pcp else "강수없음", pcp),
                 (s["t"], "WSD", str(s["wsd"]), s["wsd"])]
    base += [(w["t"], "WAV", str(w["v"]), w["v"]) for w in wave.get("series", [])]
    return [{"kind": "short", "grid_nx": nx, "grid_ny": ny, "fcst_time": t, "category": c, "value": v, "value_num": n}
            for nx, ny in GRIDS for t, c, v, n in base]


# --- SQL 덮어쓰기 ---------------------------------------------------------------

# 표 이름 → (CTE 본문, 행 키). 본문은 tools.py SQL이 쓰는 열만 만든다
_CTES: dict[str, tuple[str, str]] = {
    "risk_assessments": ("""
  SELECT (r->>'id')::bigint AS id, (r->>'hazard')::hazard_type AS hazard, (r->>'level')::risk_level AS level,
         r->>'label' AS label, ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(r->'geometry'), 4326)) AS area,
         (r->>'rule_id')::int AS rule_id, r->'basis' AS basis, now() AS valid_from, NULL::timestamptz AS valid_to,
         now() AS computed_at
  FROM jsonb_array_elements(%(_demo_areas)s::jsonb) r""", "areas"),
    "observations": ("""
  SELECT * FROM jsonb_to_recordset(%(_demo_observations)s::jsonb)
    AS t(station_id int, metric text, observed_at timestamptz, value float8, unit text, source_level smallint, quality text)""",
                     "observations"),
    "weather_warnings": ("""
  SELECT (r->>'hazard')::hazard_type AS hazard, (r->>'level')::risk_level AS level, r->>'region_name' AS region_name,
         (r->>'issued_at')::timestamptz AS issued_at, (r->>'effective_at')::timestamptz AS effective_at,
         (r->>'released_at')::timestamptz AS released_at, r->>'headline' AS headline
  FROM jsonb_array_elements(%(_demo_warnings)s::jsonb) r""", "warnings"),
    "disaster_messages": ("""
  SELECT (r->>'sent_at')::timestamptz AS sent_at, r->>'sender' AS sender, r->>'region_name' AS region_name,
         r->>'category' AS category, (r->>'hazard')::hazard_type AS hazard, r->>'alert_class' AS alert_class,
         r->>'message' AS message
  FROM jsonb_array_elements(%(_demo_messages)s::jsonb) r""", "messages"),
    "v_latest_forecasts": ("""
  SELECT * FROM jsonb_to_recordset(%(_demo_forecasts)s::jsonb)
    AS t(kind text, grid_nx smallint, grid_ny smallint, fcst_time timestamptz, category text, value text, value_num float8)""",
                           "forecasts"),
    "ingest_runs": ("""
  SELECT 'risk'::text AS source_code, 'demo'::text AS job, now() AS started_at, now() AS finished_at,
         'success'::text AS status""", ""),
}


def rewrite(sql: str, params: dict[str, Any], rows: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    """SQL이 읽는 실시간 표를 같은 이름의 CTE로 가린다. 실시간 표를 안 읽는 SQL은 그대로."""
    used = [name for name in _CTES if name in sql]
    if not used:
        return sql, params
    if sql.lstrip().upper().startswith("WITH"):
        raise ValueError("WITH로 시작하는 SQL은 시연 덮어쓰기를 지원하지 않습니다")
    ctes, extra = [], {}
    for name in used:
        body, key = _CTES[name]
        ctes.append(f"{name} AS ({body}\n)")
        if key:
            extra[f"_demo_{key}"] = json.dumps(rows[key], ensure_ascii=False, default=str)
    return "WITH " + ",\n".join(ctes) + "\n" + sql, {**params, **extra}


_source: DemoSource | None = None


def get_source() -> DemoSource:
    global _source
    if _source is None:
        _source = DemoSource()
    return _source


def demo_fetch(base: Fetch, source: DemoSource | None = None) -> Fetch:
    """base(실제 DB 조회)에 시연 표를 덮어씌운 조회 함수. 시연 데이터를 못 받으면 DemoUnavailable (tool이 '확인 불가'로 답한다)."""
    def fetch(sql: str, params: Any = None) -> list[dict[str, Any]]:
        new_sql, new_params = rewrite(sql, dict(params or {}), (source or get_source()).rows())
        return base(new_sql, new_params)
    return fetch
