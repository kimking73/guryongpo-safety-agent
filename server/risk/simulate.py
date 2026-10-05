"""시연용 재난 시나리오 — 모의 관측값(quality='simulated')을 넣고 바로 판정

모의값은 판정·지도에서 6시간 동안 실측보다 우선한다 (engine.SIM_MAX_AGE_MIN).
'clear' 로 모의값을 지우면 다음 판정부터 실측으로 돌아간다.
A3 에서는 침수 시나리오만. 태풍(힌남노)·산사태·미세먼지는 A4 에서 추가.
demo_households (A13): 시연용 가상 취약 가구 5곳 등록 (다시 실행하면 교체), demo_households_clear 로 삭제.
  가구는 관측값이 아니라서 clear 로는 지우지 않는다 — 판정 해제와 가구 삭제를 따로 할 수 있게
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app import db
from . import engine
from .levels import GURYONGPO_CENTER

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


# 시연용 가상 취약 가구 (A13) — 실제 개인정보 아님. 표시명은 households.DEMO_PREFIX 로 시작
# (표시명, 위도, 경도, 사정, 가구원 수, 방문 참고) — 앞 둘은 heavy_rain_flood 침수 경보 영역(환승센터·수협) 안
DEMO_HOUSEHOLDS = [
    ("환승센터 옆 휠체어 어르신 댁", 35.99055, 129.55590, ["elderly", "wheelchair"], 1, "1층, 현관 경사로 있음"),
    # 2026-10-05: 수협 뒤·시각장애 가구 좌표가 바다 위였음 → 가장 가까운 도로 위 육지로 옮김 (시각장애 가구는 위치가 병포리라 이름도 맞춤)
    ("수협 뒤 독거 어르신 댁", 35.98912, 129.55597, ["elderly", "living_alone", "hearing"], 1, "보청기 사용 — 문 두드리고 기다리기"),
    ("행정복지센터 앞 와상 환자 댁", 35.98600, 129.54830, ["bedridden", "medical_device"], 2, "산소발생기 사용, 보호자 동거"),
    ("병포리 시각장애 주민 댁", 35.97978, 129.55550, ["vision", "living_alone"], 1, None),
    # 방재단 대시보드 시연용 추가 (2026-10-05) — 장애인·독거노인 가구를 읍 전체에 흩어 둠. 좌표는 도로망 위 육지(경로 서버로 확인)
    # 앞 둘은 침수 경보 영역 안(환승센터에서 약 210·245m) → 대피 상황 대상, 나머지는 평시 지도에만
    ("호미로 독거 어르신 댁", 35.98962, 129.55413, ["elderly", "living_alone"], 1, "낮에는 경로당에 계심"),
    ("구룡포리 청각장애 독거 어르신 댁", 35.99250, 129.55450, ["elderly", "living_alone", "hearing"], 1, "초인종 대신 창문 두드리기"),
    ("시장 옆 청각장애 주민 댁", 35.98817, 129.55254, ["hearing"], 2, "문자로 연락"),
    ("충혼탑 아래 시각장애 어르신 댁", 35.98259, 129.54956, ["elderly", "vision"], 2, "안내견 있음"),
    ("병포리 지적장애 청년 가구", 35.98091, 129.55239, ["cognitive"], 3, "부모와 동거, 낯선 사람 경계 — 보호자 먼저"),
    ("삼정리 독거 어르신 댁", 36.00190, 129.57005, ["elderly", "living_alone", "mobility_limited"], 1, None),
    ("석병리 휠체어 이용 주민 댁", 36.01200, 129.57600, ["wheelchair"], 2, "전동휠체어, 충전 확인"),
    ("하정리 독거 어르신 댁", 35.96520, 129.54600, ["elderly", "living_alone"], 1, None),
    ("구평리 독거 어르신 댁", 35.94400, 129.53400, ["elderly", "living_alone", "medical_device"], 1, "투석 — 화·목·토 병원"),
]
DEMO_SQL = """
INSERT INTO care.households (label, address, geom, phone, members, needs, note, source,
                             consent_at, consent_method, consent_by, consent_version)
VALUES (%(label)s, '경북 포항시 남구 구룡포읍 (시연용 가상 주소)', ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326),
        NULL, %(members)s, %(needs)s::text[], %(note)s, 'responder', now(), 'written', '시연용 가상 데이터', %(ver)s)
"""
# 산사태 시연용: 구룡포 중심에서 가장 가까운 산사태위험지도 1등급 비탈 위 지점
DEMO_LANDSLIDE_SQL = """
INSERT INTO care.households (label, address, geom, members, needs, note, source, consent_at, consent_method, consent_by, consent_version)
SELECT %(label)s, '경북 포항시 남구 구룡포읍 (시연용 가상 주소)',
       ST_ClosestPoint(g.geom, ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326)), 2, ARRAY['elderly','mobility_limited'],
       '뒷산 비탈 바로 아래', 'responder', now(), 'written', '시연용 가상 데이터', %(ver)s
FROM hazard_zones g WHERE g.hazard = 'landslide' AND g.external_id = 'riskmap_g1'
"""


def demo_households(remove: bool = False) -> dict:
    from app.households import CONSENT_VERSION, DEMO_PREFIX
    removed = db.execute("DELETE FROM care.households WHERE label LIKE %(p)s", {"p": DEMO_PREFIX + "%"})
    if remove:
        return {"scenario": "demo_households_clear", "accepted": True, "removed_households": removed}
    n = db.execute_many(DEMO_SQL, [{"label": DEMO_PREFIX + label, "lat": lat, "lng": lng, "needs": needs, "members": m,
                                    "note": note, "ver": CONSENT_VERSION}
                                   for label, lat, lng, needs, m, note in DEMO_HOUSEHOLDS])
    n += db.execute(DEMO_LANDSLIDE_SQL, {"label": DEMO_PREFIX + "산사태 비탈 아래 노부부 댁", "lng": GURYONGPO_CENTER[0],
                                         "lat": GURYONGPO_CENTER[1], "ver": CONSENT_VERSION})
    return {"scenario": "demo_households", "accepted": True, "households": n, "replaced": removed}


def apply(scenario: str) -> dict:
    if scenario in ("demo_households", "demo_households_clear"):
        return demo_households(remove=scenario == "demo_households_clear")
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
    """모의값 반영 즉시 판정 + 선제 경고 (다음 10분 주기를 기다리지 않음) — ingest_runs 에도 기록"""
    from collector import jobs

    res = jobs.execute(jobs.BY_KEY["risk.flood"])
    alerts = jobs.execute(jobs.BY_KEY["risk.alerts"])
    return {"assessments": res.get("rows"), "risk_run": res.get("status"),
            "new_alerts": alerts.get("rows"), "alerts_run": alerts.get("status")}
