"""시연 시나리오 값(risk/demo.py DEMO_DT) 지킴이 — 시연 장면이 깨지지 않게 (2026-10-07, docs/demo-scenario.md).

DB 없이 값만 본다. 장면별 실제 경로 결과는 docs/demo-scenario.md 의 확인 방법으로 다시 잰다.
"""
from risk import demo


def level(ext: str) -> int:
    return demo.DEMO_DT[ext][2]


def test_one_flood_warning_at_the_harbor():
    """침수 경보(4단계, 300m)는 환승센터 한 곳 — 둘 이상이면 시가지 → 동쪽 대피소 해안 도로가 막혀 5km를 돈다"""
    assert [e for e, (_, _, lv) in demo.DEMO_DT.items() if lv >= 4 and e != "5"] == ["10"]


def test_bridge_and_harbor_corridor_stay_open():
    """구룡포교 하천(1)·수협(11·4)·해경(9)·파출소(8)는 주의(3단계) 미만 — 경로가 피하는 건 주의부터"""
    assert all(level(e) < 3 for e in ("1", "11", "4", "9", "8"))


def test_avoidance_scene_zone_is_advisory():
    """하나과메기 지표면(7) 주의 150m: 읍사무소 서쪽 → 하정축양장 경로가 이 구역을 피해 돌아가는 장면"""
    metric, value, lv = demo.DEMO_DT["7"]
    assert (metric, lv) == ("flood_depth", 3) and value < 150   # 150mm 이상이면 '침수 발생'(규칙 9)도 함께 켜진다


def test_heavy_rain_warning_matches_dashboard():
    """AWS 3시간 강수가 호우경보 기준(90mm) 이상이고, 상황판 특보도 호우경보 — 산사태 경고(위험지도 1·2등급) 유지"""
    assert demo.AWS["rain_3h"] >= 90
    assert any(w["hazard"] == "heavy_rain" and w["level"] == "warning" for w in demo.WARNINGS)
