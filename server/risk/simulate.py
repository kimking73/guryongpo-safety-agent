"""시연용 재난 시나리오 — 모의 관측값(quality='simulated')을 넣고 바로 판정

모의값은 판정·지도에서 6시간 동안 실측보다 우선한다 (engine.SIM_MAX_AGE_MIN).
'clear' 로 모의값을 지우면 다음 판정부터 실측으로 돌아간다.
A3 에서는 침수 시나리오만. 태풍(힌남노)·산사태·미세먼지는 A4 에서 추가.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app import db
from . import engine

KST = timezone(timedelta(hours=9))

# 포항 DT external_id → (metric, value, 포항 DT 등급)   mock/layer.stations.geojson 과 같은 이야기 (호우경보 중 구룡포항 침수)
HEAVY_RAIN_FLOOD = {
    "10": ("flood_depth", 230, 4),     # 구룡포환승센터 지표면 — 23cm, 경보
    "11": ("flood_depth", 170, 3),     # 구룡포수협 지표면 — 17cm, 주의
    "9":  ("flood_depth", 110, 3),     # 해양경찰서 지표면
    "8":  ("flood_depth", 60, 2),      # 구룡포파출소 지표면
    "7":  ("flood_depth", 0, 1),       # 하나과메기 지표면 — 정상
    "4":  ("manhole_level", 0, 4),     # 구룡포수협 스마트맨홀 — 경보 (value 는 판단 미사용)
    "3":  ("manhole_level", 0, 2),
    "2":  ("manhole_level", 0, 1),
    "1":  ("river_level", 1850, 3),    # 구룡포교 하천 — 주의
    "5":  ("rain_1h", 38.5, 4),        # 행정복지센터 강우량계 — 경보
}
SCENARIOS = {"heavy_rain_flood": HEAVY_RAIN_FLOOD}
UNITS = {"flood_depth": "mm", "manhole_level": "mm", "river_level": "mm", "rain_1h": "mm"}

INSERT_SQL = """
INSERT INTO observations (station_id, metric, observed_at, value, unit, source_level, quality)
SELECT s.id, %(metric)s, %(observed_at)s, %(value)s, %(unit)s, %(source_level)s, 'simulated'
FROM stations s WHERE s.source_code = 'pohang_dt' AND s.external_id = %(external_id)s
ON CONFLICT (station_id, metric, observed_at) DO UPDATE
SET value = EXCLUDED.value, source_level = EXCLUDED.source_level, quality = 'simulated'
"""


def apply(scenario: str) -> dict:
    if scenario == "clear":
        n = db.execute("DELETE FROM observations WHERE quality = 'simulated'")
        return {"scenario": scenario, "removed_observations": n, **_rerun()}
    data = SCENARIOS.get(scenario)
    if data is None:
        return {"scenario": scenario, "accepted": False, "note": "A4 에서 구현 예정 (현재: heavy_rain_flood, clear)"}
    # 실측(수집 시각을 분 단위로 내림)과 같은 시각이 되지 않게 초를 남김 → PK 충돌로 실측이 '모의'로 덮이는 일 방지
    now = datetime.now(KST).replace(microsecond=0)
    t = (now if now.second else now + timedelta(seconds=1)).isoformat()
    rows = [{"external_id": ext, "metric": m, "value": v, "unit": UNITS[m], "source_level": lv, "observed_at": t}
            for ext, (m, v, lv) in data.items()]
    n = db.execute_many(INSERT_SQL, rows)
    return {"scenario": scenario, "accepted": True, "observations": n, **_rerun()}


def _rerun() -> dict:
    """모의값 반영 즉시 판정 (다음 10분 주기를 기다리지 않음) — ingest_runs 에도 기록"""
    from collector import jobs

    res = jobs.execute(jobs.BY_KEY["risk.flood"])
    return {"assessments": res.get("rows"), "risk_run": res.get("status")}
