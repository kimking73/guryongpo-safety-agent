"""산사태 취약지역 CSV 2개 → hazard_zones (hazard='landslide') 적재 SQL + 지도용 GeoJSON

입력 (공공데이터포털 파일데이터, CP949, 폴더에 그대로 두면 됨)
  A. 경상북도_산사태취약지역지정현황_*.csv  (data.go.kr/data/15126579)  8,187행 · 포항 488행
     연번, 시군구, 읍면동, 리, 지번('산42임'), 위도/경도 도·분·초, 취약지역유형, 지정면적(㎡), 데이터기준일자  ← 좌표 있음
  B. 경상북도 포항시_산사태 취약지역 현황_*.csv (data.go.kr/data/15123337)  394행
     주소, 취약지역유형, 관리주체, 소유별, 면적(㎡), 거리(미터)=대피소와의 거리, 취약지역지정사유  ← 좌표 없음, 설명 풍부
  A 를 기준으로 (읍면동, 리, 지번 정규화, 유형) 으로 B 를 붙인다. 같은 지번이 여러 개면 면적이 가까운 것.

영역: 원천이 '점 + 면적' 이므로 중심점에서 반경 r = max(√(면적/π), 50m) 원을 영역으로 저장
  (토석류는 계곡을 따라 긴 형태라 원은 근사 — 판단 규칙 10번은 여기에 100m 버퍼를 더함)
출력
  db/seed_landslide.sql                        hazard_zones INSERT (포항 전체)
  mock/external/landslide_guryongpo.geojson    구룡포읍만, Point + 속성 (C 지도 확인용)
"""
from __future__ import annotations

import csv, json, math, os, re, unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MIN_R = 50.0


def _find(key):
    for f in os.listdir(ROOT / "data"):
        if f.endswith(".csv") and key in unicodedata.normalize("NFC", f):
            return ROOT / "data" / f
    raise FileNotFoundError(key)


def _read(p):
    b = p.read_bytes()
    for enc in ("utf-8-sig", "cp949"):
        try:
            return list(csv.DictReader(b.decode(enc).splitlines()))
        except UnicodeDecodeError:
            pass


def _jibun(s):   # '산42임' → '산42', '1492외 3' → '1492', '산9-3' → '산9-3'
    m = re.match(r"(산?\d+(?:-\d+)?)", s.replace(" ", ""))
    return m.group(1) if m else s


def _dms(d, m, s):
    return float(d) + float(m) / 60 + float(s) / 3600


def load():
    A = [r for r in _read(_find("경상북도_산사태취약지역")) if r["시군구"].startswith("포항")]
    B = _read(_find("포항시_산사태"))
    idx = {}
    for b in B:
        m = re.search(r"(\S+[읍면동])\s+(\S+리)?\s*(산?\d+(?:-\d+)?)", b["주소"])
        if m:
            idx.setdefault((m.group(1), m.group(2) or "", m.group(3), b["취약지역유형"]), []).append(b)
    zones, matched = [], 0
    for a in A:
        area = float(a["지정면적(제곱미터)"] or 0)
        key = (a["읍면동"], a["리"], _jibun(a["지번"]), a["취약지역유형"])
        cand = idx.get(key, [])
        b = min(cand, key=lambda x: abs(float(x["면적(제곱미터)"] or 0) - area)) if cand else None
        if b:
            cand.remove(b); matched += 1
        lat = _dms(a["(위도)도"], a["(위도)분"], a["(위도)초"])
        lng = _dms(a["(경도)도"], a["(경도)분"], a["(경도)초"])
        zones.append({
            "external_id": f'gb_{a["연번"]}', "grade": a["취약지역유형"],
            "name": f'{a["시군구"]} {a["읍면동"]} {a["리"]} {a["지번"]}'.replace("  ", " "),
            "lat": round(lat, 6), "lng": round(lng, 6), "area_m2": area,
            "radius_m": round(max(math.sqrt(area / math.pi), MIN_R), 1),
            "emd": a["읍면동"], "designated_date": a["데이터기준일자"],
            "reason": b and b["취약지역지정사유"], "manager": b and b["관리주체"], "ownership": b and b["소유별"],
            "shelter_distance_m": (float(b["거리(미터)"]) if b and b["거리(미터)"] else None),
        })
    return zones, matched, len(B)


def to_sql(zones):
    q = lambda v: "NULL" if v is None else "'" + str(v).replace("'", "''") + "'"
    lines = ["-- 산사태 취약지역 (포항시) — tools/landslide_zones.py 로 생성. 재실행 시 덮어씀",
             "INSERT INTO hazard_zones (source_code, external_id, hazard, name, grade, geom, meta) VALUES"]
    vals = []
    for z in zones:
        meta = {k: z[k] for k in ("lat", "lng", "area_m2", "radius_m", "emd", "designated_date", "reason",
                                  "manager", "ownership", "shelter_distance_m")}
        vals.append(f"  ('datagokr', {q(z['external_id'])}, 'landslide', {q(z['name'])}, {q(z['grade'])}, "
                    f"ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint({z['lng']}, {z['lat']}), 4326)::geography, {z['radius_m']})::geometry), "
                    f"{q(json.dumps(meta, ensure_ascii=False))}::jsonb)")
    return "\n".join(lines) + "\n" + ",\n".join(vals) + (
        "\nON CONFLICT (source_code, external_id) DO UPDATE SET name = EXCLUDED.name, grade = EXCLUDED.grade,"
        " geom = EXCLUDED.geom, meta = EXCLUDED.meta;\n")


if __name__ == "__main__":
    zones, matched, nb = load()
    (ROOT.parent / "db/init/03_seed_landslide.sql").write_text(to_sql(zones), encoding="utf-8")
    g = [z for z in zones if z["emd"] == "구룡포읍"]
    fc = {"type": "FeatureCollection", "features": [
        {"type": "Feature", "geometry": {"type": "Point", "coordinates": [z["lng"], z["lat"]]},
         "properties": {k: v for k, v in z.items() if k not in ("lat", "lng")}} for z in g]}
    (ROOT / "mock/external/landslide_guryongpo.geojson").write_text(json.dumps(fc, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"포항 {len(zones)}곳 (설명 매칭 {matched}/{nb}) · 구룡포읍 {len(g)}곳 · 설명 있음 {sum(1 for z in g if z['reason'])}")
    print("유형:", {t: sum(1 for z in g if z["grade"] == t) for t in {z["grade"] for z in g}})
    print("반경 m:", sorted(z["radius_m"] for z in g))
