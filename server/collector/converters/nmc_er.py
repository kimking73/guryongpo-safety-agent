"""국립중앙의료원 응급실 실시간 가용병상 → er_availability (tools/nmc_medical.py 사본 — 수정은 여기서)

API  https://apis.data.go.kr/B552657/ErmctInfoInqireService/getEmrrmRltmUsefulSckbdInfoInqire
     ?serviceKey=DATA_GO_KR_KEY&STAGE1=경상북도&STAGE2=포항시&pageNo=1&numOfRows=50   (XML, 'Rltm' 철자 주의)
  hvec 응급실 가용병상(음수 = 과밀) · hvoc 수술실 · hvgc 입원실 · hvamyn 구급차 가용(Y/N) · hvidate 입력시각 YYYYMMDDHHMMSS
  hpid = medical_facilities.external_id (db/init/06_seed_medical.sql, source_code='nmc') — 포항 5곳
"""
from __future__ import annotations

import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))


class NmcError(Exception):
    pass


def _items(text: str) -> list[dict]:
    try:
        r = ET.fromstring(text.encode("utf-8") if isinstance(text, str) else text)
    except ET.ParseError as e:
        raise NmcError(f"XML 아님: {str(text)[:80]!r}") from e
    code = r.findtext("header/resultCode") or r.findtext("cmmMsgHeader/returnReasonCode")
    if code != "00":
        raise NmcError(f"NMC {code} {r.findtext('header/resultMsg') or r.findtext('cmmMsgHeader/returnAuthMsg')}")
    return [{c.tag: (c.text or "").strip() for c in i} for i in r.findall("body/items/item")]


def availability(text: str) -> list[dict]:
    out = []
    for d in _items(text):
        n = lambda k: int(d[k]) if d.get(k, "").lstrip("-").isdigit() else None
        if not d.get("hpid") or not d.get("hvidate"):
            continue
        out.append({"external_id": d["hpid"],
                    "observed_at": datetime.strptime(d["hvidate"], "%Y%m%d%H%M%S").replace(tzinfo=KST).isoformat(),
                    "er_beds": n("hvec"), "surgery_rooms": n("hvoc"), "inpatient_beds": n("hvgc"),
                    "ambulance": d.get("hvamyn") == "Y", "raw": d})
    return out


INSERT_AVAILABILITY_SQL = """
INSERT INTO er_availability (facility_id, observed_at, er_beds, surgery_rooms, inpatient_beds, ambulance, raw)
SELECT f.id, %(observed_at)s, %(er_beds)s, %(surgery_rooms)s, %(inpatient_beds)s, %(ambulance)s, %(raw)s::jsonb
FROM medical_facilities f WHERE f.source_code = 'nmc' AND f.external_id = %(external_id)s
ON CONFLICT (facility_id, observed_at) DO NOTHING
"""
