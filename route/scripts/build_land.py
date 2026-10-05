"""구룡포 일대 육지 영역(route/data/land.geojson)을 OSM 해안선으로 만든다 (B11 해상 판정용).

경로 서버는 출발 좌표가 이 다각형 밖이면 해상으로 본다 (guardian_route/sea.py).
OSM 해안선(natural=coastline)은 "진행 방향 왼쪽이 육지" 규칙으로 그려진다. 경로 범위(bbox)를 해안선으로 잘라
조각마다 왼쪽·오른쪽을 따져 육지 조각만 남기고, 닫힌 해안선(섬·바위)은 그대로 육지로 더한다.

실행 (route/ 폴더에서, docker 필요 — osmium을 설치하지 않도록 컨테이너에서 해안선만 뽑는다):
    .venv/bin/python scripts/build_land.py
도로망을 새로 받았을 때(graphhopper/fetch_osm.sh)만 다시 돌리면 된다. 결과 파일은 커밋한다.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from shapely.geometry import LineString, Point, box, mapping, shape
from shapely.ops import linemerge, split, unary_union

ROOT = Path(__file__).resolve().parents[2]
PBF = ROOT / "graphhopper" / "data" / "guryongpo.osm.pbf"
OUT = ROOT / "route" / "data" / "land.geojson"
# graphhopper/fetch_osm.sh 와 같은 범위 (서쪽 경도, 남쪽 위도, 동쪽 경도, 북쪽 위도)
BBOX = (129.48, 35.92, 129.60, 36.04)
# 확인용: 반드시 육지 / 반드시 바다인 점 (lon, lat)
LAND_CHECK = [(129.5450, 35.9870), (129.5500, 35.9700)]   # 구룡포읍 시가지, 구룡포초 부근
SEA_CHECK = [(129.5800, 35.9900), (129.5900, 35.9500)]    # 구룡포항 앞바다


def extract_coastline(pbf: Path) -> dict:
    """컨테이너 osmium으로 natural=coastline 만 GeoJSON으로 뽑는다."""
    with tempfile.TemporaryDirectory() as tmp:
        shutil.copy(pbf, Path(tmp) / "in.osm.pbf")
        cmd = ("apt-get update -qq >/dev/null && apt-get install -y -qq osmium-tool >/dev/null && "
               "osmium tags-filter --overwrite -o /data/coast.osm.pbf /data/in.osm.pbf w/natural=coastline && "
               "osmium export --overwrite -f geojson -o /data/coast.geojson /data/coast.osm.pbf")
        subprocess.run(["docker", "run", "--rm", "-v", f"{tmp}:/data", "debian:bookworm-slim", "sh", "-c", cmd], check=True)
        return json.loads((Path(tmp) / "coast.geojson").read_text(encoding="utf-8"))


def left_of(line: LineString, pt: Point) -> bool:
    """pt가 line 진행 방향의 왼쪽인지 (가장 가까운 선분 기준 외적 부호)."""
    d = line.project(pt)
    coords = list(line.coords)
    acc = 0.0
    for a, b in zip(coords, coords[1:]):
        seg = LineString([a, b]).length
        if acc + seg >= d or (a, b) == (coords[-2], coords[-1]):
            return (b[0] - a[0]) * (pt.y - a[1]) - (b[1] - a[1]) * (pt.x - a[0]) > 0
        acc += seg
    return False


def build_land(coast: dict, bbox=BBOX):
    area = box(*bbox)
    open_lines, closed = [], []
    for f in coast["features"]:
        if (f.get("properties") or {}).get("natural") != "coastline":
            continue
        g = shape(f["geometry"])
        if g.geom_type == "LineString":
            open_lines.append(g)
        else:  # osmium이 닫힌 해안선(섬)을 다각형으로 내보낸다
            closed.append(g)
    merged = linemerge(open_lines) if open_lines else None
    parts = list(getattr(merged, "geoms", [merged])) if merged is not None else []
    rings = [l for l in parts if l.is_ring]
    lines = [l for l in parts if not l.is_ring]
    closed += [shape({"type": "Polygon", "coordinates": [list(r.coords)]}) for r in rings]

    land_parts = []
    if lines:
        cutter = unary_union([l.intersection(area) for l in lines])
        for piece in split(area, cutter).geoms:
            probe = piece.representative_point()
            nearest = min(lines, key=lambda l: l.distance(probe))
            if left_of(nearest, probe):
                land_parts.append(piece)
    land = unary_union(land_parts + [c.intersection(area) for c in closed])
    return land


def main() -> None:
    coast = extract_coastline(PBF)
    land = build_land(coast)
    for lon, lat in LAND_CHECK:
        assert land.contains(Point(lon, lat)), f"육지여야 하는 점이 바다로 나옴: {lat},{lon}"
    for lon, lat in SEA_CHECK:
        assert not land.contains(Point(lon, lat)), f"바다여야 하는 점이 육지로 나옴: {lat},{lon}"
    land = land.simplify(0.00002, preserve_topology=True)  # 약 2m — 파일 크기 줄이기
    OUT.write_text(json.dumps({
        "type": "FeatureCollection",
        "features": [{"type": "Feature", "geometry": mapping(land),
                      "properties": {"name": "구룡포 일대 육지", "bbox": list(BBOX),
                                     "source": "OpenStreetMap natural=coastline (© OpenStreetMap contributors, ODbL)"}}],
    }, ensure_ascii=False), encoding="utf-8")
    print(f"저장: {OUT} ({OUT.stat().st_size // 1024}KB, 조각 {len(getattr(land, 'geoms', [land]))}개)")


if __name__ == "__main__":
    main()
