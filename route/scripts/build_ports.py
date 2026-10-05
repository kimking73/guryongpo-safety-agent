"""구룡포 일대 항·포구 목록(route/data/ports.geojson)과 DB 시드(db/init/10_seed_ports.sql)를 만든다 (B11).

항구 위치 출처 (2026-10-05 확인):
  - 카카오 로컬 장소 검색 — 분류 '항구,포구'·'방파제'로 등록된 곳 (아래 ANCHORS의 좌표)
  - OpenStreetMap — 구룡포항(harbour=yes), 방파제(man_made=breakwater) 위치로 교차 확인
  - 방파제만 있고 이름이 없는 곳은 행정리 이름(카카오 좌표→행정구역)으로 "OO리 포구"라 적는다
어항 종류(국가·지방·정주어항)는 구룡포항(국가어항)만 확인했다. 나머지는 kind='other'.

각 항구에서
  land_point = 장소 좌표를 GraphHopper 도로망에 붙인 점 (육상 경로 출발점, /api/route origin)
  berth      = land_point에서 가장 가까운 바다 쪽 점 (육지 다각형 경계에서 바다로 15m) — 해상 구간 도착점
실행 (route/ 폴더, graphhopper가 localhost:8989에 떠 있어야 함):
    .venv/bin/python scripts/build_ports.py
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import httpx
from shapely.geometry import Point, shape
from shapely.ops import nearest_points

ROOT = Path(__file__).resolve().parents[2]
LAND = ROOT / "route" / "data" / "land.geojson"
OUT = ROOT / "route" / "data" / "ports.geojson"
SEED = ROOT / "db" / "init" / "10_seed_ports.sql"
GH = os.environ.get("GRAPHHOPPER_URL", "http://localhost:8989")
SEAWARD_M = 15.0
M_PER_DEG_LAT = 111_320.0

# (id, 이름, 종류, 위도, 경도, 근거) — 남쪽에서 북쪽, 동해안 다음 영일만 쪽
ANCHORS = [
    ("mopo", "모포항", "other", 35.93296, 129.52599, "카카오 '모포항'(항구,포구)"),
    ("gupyeong", "구평포구", "other", 35.94459, 129.53595, "카카오 '구평포구'(항구,포구)"),
    ("janggil", "장길리 포구", "other", 35.95170, 129.54622, "카카오 '장길방파제'"),
    ("hajeong", "하정1리 포구", "other", 35.96495, 129.54790, "카카오 '하정1리 방파제'"),
    ("byeongpo", "병포리 포구", "other", 35.97993, 129.55432, "카카오 '병포리방파제'"),
    ("guryongpo", "구룡포항", "national_fishing", 35.98931, 129.55575, "카카오 '구룡포항'(항구,포구), OSM harbour, 국가어항"),
    ("samjeong", "삼정항", "other", 36.00397, 129.57434, "카카오 '삼정항'(항구,포구)"),
    ("seokbyeong1", "석병1리 포구", "other", 36.01274, 129.57908, "카카오 '석병1리 방파제'"),
    ("seokbyeong_n", "석병리 북쪽 포구", "other", 36.02570, 129.57820, "OSM 방파제(이름 없음), 행정리 석병리"),
    ("gangsa", "강사리 포구", "other", 36.03994, 129.57900, "카카오 선착장, 행정리 호미곶면 강사리"),
    ("masan", "마산리 포구", "other", 36.01668, 129.48906, "카카오 '마산항방파제', 영일만 쪽"),
    ("heunghwan", "흥환리 포구", "other", 36.02630, 129.50250, "OSM 방파제(이름 없음), 행정리 동해면 흥환리"),
]


def _sql(text: str) -> str:
    """SQL 문자열 안 작은따옴표 이스케이프"""
    return text.replace("'", "''")


def snap_to_road(lat: float, lon: float) -> tuple[float, float, float]:
    r = httpx.get(f"{GH}/nearest", params={"point": f"{lat},{lon}"}, timeout=10).json()
    lon2, lat2 = r["coordinates"]
    return lat2, lon2, r["distance"]


def seaward(land, lat: float, lon: float) -> tuple[float, float]:
    """육지 경계에서 가장 가까운 점을 찾아 바다 쪽으로 SEAWARD_M 더 나간 점."""
    p = Point(lon, lat)
    edge = nearest_points(land.boundary, p)[0]
    dx, dy = edge.x - p.x, edge.y - p.y
    norm = (dx * dx + dy * dy) ** 0.5 or 1e-9
    step = SEAWARD_M / M_PER_DEG_LAT
    q = Point(edge.x + dx / norm * step, edge.y + dy / norm * step)
    if land.contains(q):  # 경계가 꺾인 곳이면 조금씩 더 나간다
        for k in range(2, 10):
            q = Point(edge.x + dx / norm * step * k, edge.y + dy / norm * step * k)
            if not land.contains(q):
                break
    return q.y, q.x


def main() -> None:
    land = shape(json.loads(LAND.read_text(encoding="utf-8"))["features"][0]["geometry"])
    feats, rows = [], []
    for pid, name, kind, lat, lon, src in ANCHORS:
        llat, llon, snap_m = snap_to_road(lat, lon)
        blat, blon = seaward(land, llat, llon)
        gap = Point(llon, llat).distance(Point(blon, blat)) * M_PER_DEG_LAT
        print(f"{name}: 도로 붙임 {snap_m:.0f}m, 접안점까지 {gap:.0f}m")
        props = {"id": pid, "name": name, "kind": kind, "berth": [round(blon, 6), round(blat, 6)],
                 "land_point": [round(llon, 6), round(llat, 6)], "source": src}
        feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": props["berth"]}, "properties": props})
        rows.append(f"  ('{pid}', '{name}', '{kind}', ST_SetSRID(ST_MakePoint({props['berth'][0]}, {props['berth'][1]}), 4326), "
                    f"ST_SetSRID(ST_MakePoint({props['land_point'][0]}, {props['land_point'][1]}), 4326), "
                    f"'{_sql(json.dumps({'source': src}, ensure_ascii=False))}'::jsonb)")
    OUT.write_text(json.dumps({"type": "FeatureCollection", "features": feats}, ensure_ascii=False, indent=1), encoding="utf-8")
    SEED.write_text(
        "-- B11 해상 → 최근접 항: 구룡포 일대 항·포구 (route/scripts/build_ports.py 가 route/data/ports.geojson 과 함께 생성)\n"
        "-- 재적용 안전 (source_code + external_id 로 갱신). 경로 서버는 같은 내용을 ports.geojson 에서 읽는다\n"
        "INSERT INTO data_sources (code, name, provider, note) VALUES\n"
        "  ('ports_b11', '구룡포 항·포구 (B11)', '카카오 로컬 / OpenStreetMap', "
        "'항·포구 위치 — 카카오 장소 분류 항구·포구·방파제, OSM 방파제로 교차 확인 (route/scripts/build_ports.py)')\n"
        "ON CONFLICT (code) DO NOTHING;\n\n"
        "INSERT INTO ports (external_id, name, kind, berth, land_point, meta, source_code)\n"
        "SELECT v.*, 'ports_b11' FROM (VALUES\n" + ",\n".join(rows) + "\n) AS v(external_id, name, kind, berth, land_point, meta)\n"
        "ON CONFLICT (source_code, external_id) DO UPDATE\n"
        "  SET name = EXCLUDED.name, kind = EXCLUDED.kind, berth = EXCLUDED.berth,\n"
        "      land_point = EXCLUDED.land_point, meta = EXCLUDED.meta;\n",
        encoding="utf-8")
    print(f"저장: {OUT}, {SEED} ({len(feats)}곳)")


if __name__ == "__main__":
    main()
