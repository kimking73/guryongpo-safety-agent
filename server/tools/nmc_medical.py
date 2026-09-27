"""국립중앙의료원 전국 응급의료기관 정보 조회 서비스 → medical_facilities (1회) + er_availability (실시간) [A7 · A2]

API  https://apis.data.go.kr/B552657/ErmctInfoInqireService/<오퍼레이션>?serviceKey=DATA_GO_KR_KEY (XML)
  getEgytListInfoInqire  Q0=경상북도&Q1=포항시   응급의료기관 목록 (좌표 wgs84Lat/Lon, 대표전화 dutyTel1, 응급실 dutyTel3, 등급 dutyEmclsName)
  getEgytLcinfoInqire    WGS84_LON/LAT            기준점에서 가까운 기관 + 거리(km)
  getEmrrmRltmUsefulSckbdInfoInqire STAGE1=경상북도&STAGE2=포항시   응급실 실시간 가용병상 (※ 'Rltm' 철자 주의)
    hvec 응급실 가용병상(음수 = 과밀) · hvoc 수술실 · hvgc 입원실 · hvamyn 구급차 가용(Y/N) · hvidate 입력시각(YYYYMMDDHHMMSS)
구룡포에는 응급의료기관 없음 — 가장 가까운 곳 포항세명기독병원 17.2km (getEgytLcinfoInqire, 2026-09-27)
"""
from __future__ import annotations

import json, xml.etree.ElementTree as ET
from datetime import datetime, timezone, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KST = timezone(timedelta(hours=9))


def _items(text):
    r = ET.fromstring(text.encode("utf-8") if isinstance(text, str) else text)
    code = r.findtext("header/resultCode") or r.findtext("cmmMsgHeader/returnReasonCode")
    if code != "00":
        raise RuntimeError(f"NMC {code} {r.findtext('header/resultMsg') or r.findtext('cmmMsgHeader/returnAuthMsg')}")
    return [{c.tag: (c.text or "").strip() for c in i} for i in r.findall("body/items/item")]


def facilities(text):
    return [{"external_id": d["hpid"], "name": d["dutyName"], "address": d["dutyAddr"], "phone": d.get("dutyTel1"),
             "lat": float(d["wgs84Lat"]), "lng": float(d["wgs84Lon"]),
             "meta": {"er_phone": d.get("dutyTel3"), "emergency_class": d.get("dutyEmclsName")}} for d in _items(text)]


def availability(text):
    out = []
    for d in _items(text):
        n = lambda k: int(d[k]) if d.get(k, "").lstrip("-").isdigit() else None
        out.append({"external_id": d["hpid"],
                    "observed_at": datetime.strptime(d["hvidate"], "%Y%m%d%H%M%S").replace(tzinfo=KST).isoformat(),
                    "er_beds": n("hvec"), "surgery_rooms": n("hvoc"), "inpatient_beds": n("hvgc"),
                    "ambulance": d.get("hvamyn") == "Y", "raw": d})
    return out


UPSERT_AVAILABILITY_SQL = """
INSERT INTO er_availability (facility_id, observed_at, er_beds, surgery_rooms, inpatient_beds, ambulance, raw)
SELECT f.id, %(observed_at)s, %(er_beds)s, %(surgery_rooms)s, %(inpatient_beds)s, %(ambulance)s, %(raw)s::jsonb
FROM medical_facilities f WHERE f.source_code = 'nmc' AND f.external_id = %(external_id)s
ON CONFLICT (facility_id, observed_at) DO NOTHING
"""


if __name__ == "__main__":
    ext = ROOT / "mock/external"
    fs = facilities((ext / "nmc_er_list_pohang.txt").read_text(encoding="utf-8"))
    q = lambda v: "NULL" if v is None else "'" + str(v).replace("'", "''") + "'"
    sql = ["-- 포항 응급의료기관 (국립중앙의료원) — tools/nmc_medical.py 생성. 구룡포 내 응급의료기관 없음",
           "INSERT INTO medical_facilities (source_code, external_id, name, kind, address, phone, geom, meta) VALUES",
           ",\n".join(f"  ('nmc', {q(f['external_id'])}, {q(f['name'])}, 'emergency_room', {q(f['address'])}, {q(f['phone'])}, "
                      f"ST_SetSRID(ST_MakePoint({f['lng']}, {f['lat']}), 4326), {q(json.dumps(f['meta'], ensure_ascii=False))}::jsonb)" for f in fs),
           "ON CONFLICT (source_code, external_id) DO UPDATE SET name = EXCLUDED.name, address = EXCLUDED.address,"
           " phone = EXCLUDED.phone, geom = EXCLUDED.geom, meta = EXCLUDED.meta;"]
    (ROOT.parent / "db/init/06_seed_medical.sql").write_text("\n".join(sql) + "\n", encoding="utf-8")
    fc = {"type": "FeatureCollection", "features": [{"type": "Feature", "geometry": {"type": "Point", "coordinates": [f["lng"], f["lat"]]},
          "properties": {k: f[k] for k in ("external_id", "name", "address", "phone")} | f["meta"]} for f in fs]}
    (ext / "medical_pohang.geojson").write_text(json.dumps(fc, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"응급의료기관 {len(fs)}곳 → db/init/06_seed_medical.sql")
    for a in availability((ext / "nmc_er_beds_pohang.txt").read_text(encoding="utf-8")):
        print(" ", a["external_id"], a["observed_at"], "응급실", a["er_beds"], "수술실", a["surgery_rooms"], "구급차", a["ambulance"])
