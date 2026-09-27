"""구룡포 대피소 주소 → 위도·경도 (카카오 로컬 API) → shelters 적재 SQL + GeoJSON  [A7 정적 데이터]

입력  mock/external/safemap_tsunami_shelter.txt, safemap_civil_shelter_p*.txt (fetch_dt.py safemap / civil_shelter)
키    dt_config.txt 의 KAKAO_REST_KEY (카카오 developers REST API 키, 카카오맵 사용 설정 ON)
출력  db/seed_shelters.sql, mock/external/shelters_guryongpo.geojson, mock/external/geocode_log.json
실행  cd tools && python3 geocode_shelters.py
- 주소 검색(/v2/local/search/address.json) 실패 시 시설명 키워드 검색(/v2/local/search/keyword.json, 구룡포읍 한정)
- 결과는 geocode_log.json 에 캐시 → 재실행 시 이미 찾은 주소는 다시 호출하지 않음
"""
from __future__ import annotations

import glob, json, re, subprocess, urllib.parse, xml.etree.ElementTree as ET
from pathlib import Path

from fetch_dt import load_env, decode

ROOT = Path(__file__).resolve().parent.parent
EXT = ROOT / "mock/external"
EMD = "구룡포읍"


def shelters():
    out = {}
    for i in ET.parse(EXT / "safemap_tsunami_shelter.txt").getroot().find("body/items").findall("item"):
        d = {c.tag: (c.text or "") for c in i}
        if d["emd_kor_nm"] != EMD:
            continue
        no = d["adres_mnnm"] + (f"-{d['adres_slno']}" if d["adres_slno"] not in ("", "0") else "")
        out[d["obj_mng_no"]] = {"external_id": d["obj_mng_no"], "types": ["tsunami"], "name": d["obj_nm"],
                                "address": f"경북 포항시 남구 {EMD} {d['rn']} {no}", "is_indoor": d["und_yn"] == "1"}
    for f in sorted(glob.glob(str(EXT / "safemap_civil_shelter_p*.txt"))):
        for i in ET.parse(f).getroot().find("body/items").findall("item"):
            d = {c.tag: (c.text or "") for c in i}
            if EMD in d["locplc_rdnmadr"]:
                out[d["shunt_fclty_sn"]] = {"external_id": d["shunt_fclty_sn"], "types": ["civil_defense"], "name": d["mgc_nm"],
                                            "address": d["locplc_rdnmadr"].split(" (")[0].replace("경상북도", "경북"),
                                            "is_indoor": True, "area_m2": d["fclty_ar"], "is_open": d["opn_at"] == "1"}
    return list(out.values())


def kakao(path, params, key):
    url = f"https://dapi.kakao.com{path}?" + urllib.parse.urlencode(params)
    r = subprocess.run(["curl", "-sS", "--max-time", "15", "-H", f"Authorization: KakaoAK {key}", url], capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.decode(errors="replace"))
    j = json.loads(decode(r.stdout))
    if "documents" not in j:
        raise RuntimeError(f"카카오 오류: {j}")
    return j["documents"]


# 카카오맵 등록 '지진해일대피장소' (map.kakao.com 장소, 2026-09-27 확인) — 생활안전지도 주소가 틀리거나 도로 위치만 있는 경우 보정
#   external_id: (lat, lng, 카카오 장소명, confirmid)
KAKAO_PLACES = {
    "OBJ064711100000049": (35.96544619, 129.54677917, "하정리 269번지 (하정", "1680753240"),
    "OBJ064711100000050": (35.97113375, 129.55242499, "하정축양장 앞 공터", "1643514160"),
    "OBJ064711100000018": (36.03130789, 129.57917535, "대성수산 입구 앞 공터", "1795573326"),   # 주소검색 결과(내륙 3km)가 틀렸음
    "OBJ064711100000003": (35.97561168, 129.55080799, "경북대수련원 앞 공", "1763140494"),
    "OBJ064711100000010": (35.94409061, 129.53355107, "구평리 117-2번지 앞 주변도로", "1660470024"),
    "OBJ064711100000044": (35.95481932, 129.54542274, "장길리교회 앞", "1730479766"),
    "OBJ064711100000048": (36.00939523, 129.57652815, "포스코수련원 앞", "1676775365"),
    "OBJ064711100000008": (36.02921467, 129.57382639, "구룡포청소년회관 앞", "1789247046"),
    "OBJ064711100000011": (36.01431585, 129.57650319, "우리수산 앞 사거리 공터 (석병리 901-3)", "1675473784"),
    "OBJ064711100000001": (36.00002962, 129.56847866, "MGM그랜드모텔 앞", "1682424847"),
    "OBJ064711100000054": (35.99693964, 129.56509886, "해은사 앞", "1683920511"),        # 원천 주소 '호미로 417' 은 검색 안 됨
    "OBJ064711100000031": (36.021184, 129.57779159, "석병장로교회 옆", "1687792263"),
    "OBJ064711100000047": (35.99144081, 129.56073009, "충혼탑 앞", "1644069620"),
}


def geocode(s, key):
    """주소 → (읍 뺀 주소) → 이름 속 지번 → 시설명 키워드 순서로 시도. 구룡포읍 안의 결과만 채택"""
    if "tsunami" in s["types"]:
        # 카카오맵에 '지진해일대피장소 <이름>' 으로 대피장소가 직접 등록돼 있음 → 가장 정확 (주소 데이터 오류 우회)
        base = re.sub(r"\s*(앞|옆)(\s*공터)?$", "", s["name"]).replace("MGM", "엠지엠").replace("구, ", "")
        for q in (f"지진해일대피장소 {s['name']}", f"지진해일대피장소 {base}"):
            docs = [d for d in kakao("/v2/local/search/keyword.json", {"query": q, "size": 15}, key)
                    if "지진해일대피장소" in d.get("place_name", "") and EMD in d.get("address_name", "")]
            if docs:
                return float(docs[0]["y"]), float(docs[0]["x"]), "kakao_place:" + docs[0]["place_name"]
    tries = [("address", s["address"]), ("address", s["address"].replace(f" {EMD}", ""))]
    m = re.search(r"([가-힣]+리)\s*(\d+(?:-\d+)?)", s["name"])          # '석병리 904-2', '하정리 269번지'
    if m:
        tries.append(("address", f"경북 포항시 남구 {EMD} {m.group(1)} {m.group(2)}"))
    for how, q in tries:
        docs = kakao("/v2/local/search/address.json", {"query": q}, key)
        if docs:
            return float(docs[0]["y"]), float(docs[0]["x"]), f"{how}:{q.split('남구 ')[-1]}"
    name = re.sub(r"\s*(앞|옆|입구 앞|앞 공터|도로 옆 공터)$", "", s["name"]).replace("MGM", "엠지엠")
    for q in (f"구룡포 {name}", name, s["name"]):
        docs = [d for d in kakao("/v2/local/search/keyword.json", {"query": q, "size": 15}, key)
                if EMD in d.get("address_name", "") or EMD in d.get("road_address_name", "")]
        if docs:
            return float(docs[0]["y"]), float(docs[0]["x"]), "keyword:" + docs[0]["place_name"]
    return None


def main():
    key = load_env().get("KAKAO_REST_KEY")
    if not key:
        raise SystemExit("dt_config.txt 에 KAKAO_REST_KEY 가 없음")
    logf = EXT / "geocode_log.json"
    cache = json.loads(logf.read_text(encoding="utf-8")) if logf.exists() else {}
    rows, miss = [], []
    for s in shelters():
        if s["external_id"] in KAKAO_PLACES:
            la, lo, nm, cid = KAKAO_PLACES[s["external_id"]]
            rows.append({**s, "lat": la, "lng": lo, "by": f"kakao_place:{cid} {nm}"}); continue
        if not cache.get(s["address"]):          # 실패(None)는 다시 시도
            g = geocode(s, key)
            cache[s["address"]] = g and {"lat": g[0], "lng": g[1], "by": g[2]}
        g = cache[s["address"]]
        (rows if g else miss).append({**s, **(g or {})})
    logf.write_text(json.dumps(cache, ensure_ascii=False, indent=1), encoding="utf-8")

    q = lambda v: "NULL" if v is None else "'" + str(v).replace("'", "''") + "'"
    sql = ["-- 구룡포 대피소 (생활안전지도 IF_0126 지진해일 긴급대피장소 · IF_0122 민방위대피시설) — tools/geocode_shelters.py 생성",
           "-- 좌표: 카카오 로컬 API 주소 검색 (WGS84). 재실행 시 덮어씀",
           "INSERT INTO shelters (source_code, external_id, name, shelter_types, address, is_indoor, is_open, geom) VALUES"]
    sql.append(",\n".join(
        f"  ('safemap', {q(r['external_id'])}, {q(r['name'])}, '{{{','.join(r['types'])}}}', {q(r['address'])}, "
        f"{'true' if r['is_indoor'] else 'false'}, {'false' if r.get('is_open') is False else 'true'}, "
        f"ST_SetSRID(ST_MakePoint({r['lng']}, {r['lat']}), 4326))" for r in rows))
    sql.append("ON CONFLICT (source_code, external_id) DO UPDATE SET name = EXCLUDED.name, shelter_types = EXCLUDED.shelter_types,"
               " address = EXCLUDED.address, is_indoor = EXCLUDED.is_indoor, is_open = EXCLUDED.is_open, geom = EXCLUDED.geom, updated_at = now();")
    (ROOT.parent / "db/init/05_seed_shelters.sql").write_text("\n".join(sql) + "\n", encoding="utf-8")
    fc = {"type": "FeatureCollection", "features": [
        {"type": "Feature", "geometry": {"type": "Point", "coordinates": [r["lng"], r["lat"]]},
         "properties": {k: r[k] for k in ("external_id", "name", "types", "address", "is_indoor", "by")}} for r in rows]}
    (EXT / "shelters_guryongpo.geojson").write_text(json.dumps(fc, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"대피소 {len(rows)}곳 좌표 확보 / 실패 {len(miss)}곳")
    for r in rows:
        print(f"  {r['lat']:.6f}, {r['lng']:.6f}  {r['name']}  ({r['by']})")
    for r in miss:
        print(f"  [실패] {r['name']} — {r['address']}")


if __name__ == "__main__":
    main()
