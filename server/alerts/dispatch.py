"""선제 경고 생성 — 판정 결과(risk_assessments)·재난문자 → 대상 사용자 → user_alerts (+ care.incidents) → FCM

수집기 job risk.alerts (10분마다, 판정 직후) 와 GET /alerts (위치를 보낸 사용자 1명만 즉시) 가 같은 run() 을 쓴다.
같은 경고는 다시 만들지 않는다: user_alerts UNIQUE(user_id, dedupe_key), care.incidents 판정당 1개 (uq_incidents_assessment).

  1. 닫힌 판정의 대피 상황: 같은 재난·겹치는 영역의 새 경보 판정이 있으면 이어 붙이고(단계 변경), 없으면 종료 → FCM incident_closed
  2. 재난문자 대피 지시(+구룡포) → 구룡포읍 영역 대피 상황 (6시간 뒤 자동 종료)
  3. 주의 이상 판정 → policy.classify → 대피 확인이면 대피 상황 + 영역 안 등록 가구를 대상에 추가
  4. 대상 사용자 = 영역 안 현재 위치(60분 이내) 또는 알림 켠 등록 장소. 한 사용자에게 재난별로 가장 높은 단계 1건.
     침수·호우는 대피 확인이 하나라도 있으면 1건으로 묶음 (policy.EVAC_GROUPS, 2026-10-03 결정)
  5. 새 경고 → FCM (kind alert | evacuation)
"""
from __future__ import annotations

import json
import logging
import math
from typing import Optional

from app import db
from risk.levels import GURYONGPO_CENTER, GURYONGPO_RADIUS_M, HAZARD_KO, LEVEL_NUM
from . import fcm, messages, policy

log = logging.getLogger("alerts")

LOCATION_MAX_AGE_MIN = 60          # 기기 위치가 이보다 오래되면 '현재 위치' 로 보지 않음
MESSAGE_LOOKBACK_MIN = 30          # 재난문자는 최근 30분 것만 새 대피 상황으로
MESSAGE_INCIDENT_HOURS = 6         # 재난문자 대피 상황은 6시간 뒤 자동 종료 (판정과 달리 '해제' 신호가 없음)
MSG_NOTE = "disaster_message:"

ACTIVE_SQL = """
SELECT id, hazard::text AS hazard, level::text AS level, label, basis
FROM risk_assessments WHERE valid_to IS NULL AND level >= 'advisory' ORDER BY id
"""

# 영역({area} = area 1개를 돌려주는 SELECT) 안 대상 사용자. 사용자당 1행 — 현재 위치 우선
TARGETS_SQL = """
WITH a AS ({area}),
t AS (
  SELECT d.user_id, 0 AS prio, 'current_location' AS trigger, NULL::uuid AS place_id, NULL::text AS place_label,
         d.last_location AS geom, d.last_location_at AS at
  FROM user_devices d, a
  WHERE d.last_location_at > now() - make_interval(mins => %(loc_min)s) AND ST_Intersects(a.area, d.last_location)
  UNION ALL
  SELECT p.user_id, 1, 'place', p.id, p.label, p.geom, p.created_at
  FROM user_places p, a WHERE p.notify AND ST_Intersects(a.area, p.geom)
)
SELECT DISTINCT ON (t.user_id) t.user_id, t.trigger, t.place_id, t.place_label, ST_Y(t.geom) AS lat, ST_X(t.geom) AS lng,
       pr.birth_year, pr.walking_ability::text AS walking_ability, pr.mobility::text AS mobility, pr.occupation,
       pr.owns_vessel, pr.vision_impaired, pr.hearing_impaired, pr.user_type::text AS user_type,
       (SELECT jsonb_build_object('name', c.name, 'relation', c.relation, 'phone', c.phone) FROM emergency_contacts c
        WHERE c.user_id = t.user_id ORDER BY c.priority, c.name LIMIT 1) AS contact
FROM t LEFT JOIN user_profiles pr ON pr.user_id = t.user_id
WHERE %(uid)s::uuid IS NULL OR t.user_id = %(uid)s::uuid
ORDER BY t.user_id, t.prio, t.at DESC
"""
AREA_OF_ASSESSMENT = "SELECT area FROM risk_assessments WHERE id = %(aid)s"
AREA_OF_INCIDENT = "SELECT area FROM care.incidents WHERE id = %(iid)s"

INSERT_ALERT_SQL = """
INSERT INTO user_alerts (user_id, hazard, level, title, body, reason, actions, assessment_id, place_id, location,
                         dedupe_key, response_required, incident_id, tts_text)
VALUES (%(uid)s, %(hazard)s::hazard_type, %(level)s::risk_level, %(title)s, %(body)s, %(reason)s::jsonb, %(actions)s::jsonb,
        %(aid)s, %(pid)s, ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326), %(key)s, %(rr)s, %(iid)s, %(tts)s)
ON CONFLICT (user_id, dedupe_key) DO NOTHING
RETURNING id
"""
# 같은 대피 상황에서 단계가 바뀌어 새 경고가 가면 대상 행은 유지하고 최신 경고만 가리킴 (응답 상태 보존)
INSERT_TARGET_SQL = """
INSERT INTO care.incident_targets (incident_id, user_id, alert_id, last_location)
VALUES (%(iid)s, %(uid)s, %(alert_id)s, ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326))
ON CONFLICT (incident_id, user_id) WHERE household_id IS NULL
DO UPDATE SET alert_id = EXCLUDED.alert_id, updated_at = now()
"""
HOUSEHOLD_TARGETS_SQL = """
INSERT INTO care.incident_targets (incident_id, household_id)
SELECT i.id, h.id FROM care.incidents i JOIN care.households h ON h.active AND ST_Intersects(i.area, h.geom)
WHERE i.id = %(iid)s
ON CONFLICT (incident_id, household_id) WHERE household_id IS NOT NULL DO NOTHING
"""

ENSURE_INCIDENT_SQL = """
INSERT INTO care.incidents (hazard, level, title, area, assessment_id, source)
SELECT ra.hazard, ra.level, %(title)s, ra.area, ra.id, %(source)s FROM risk_assessments ra WHERE ra.id = %(aid)s
ON CONFLICT (assessment_id) WHERE closed_at IS NULL AND assessment_id IS NOT NULL DO NOTHING
RETURNING id
"""
OPEN_INCIDENT_SQL = "SELECT id FROM care.incidents WHERE assessment_id = %(aid)s AND closed_at IS NULL"
# 방재단이 종료한 상황 — 같은 판정이 계속돼도 다시 열지 않고 일반 경고로만 (A12)
CLOSED_BY_STAFF_SQL = "SELECT 1 AS x FROM care.incidents WHERE assessment_id = %(aid)s AND closed_at IS NOT NULL LIMIT 1"

STALE_INCIDENTS_SQL = """
SELECT i.id, i.title, i.assessment_id FROM care.incidents i JOIN risk_assessments o ON o.id = i.assessment_id
WHERE i.closed_at IS NULL AND o.valid_to IS NOT NULL
"""
SUCCESSOR_SQL = """
SELECT n.id, n.level::text AS level FROM risk_assessments n, risk_assessments o
WHERE o.id = %(old)s AND n.valid_to IS NULL AND n.hazard = o.hazard AND n.level >= %(min_level)s::risk_level
  AND ST_Intersects(n.area, o.area)
  AND NOT EXISTS (SELECT 1 FROM care.incidents x WHERE x.assessment_id = n.id AND x.closed_at IS NULL)
ORDER BY n.level DESC, n.id LIMIT 1
"""
CARRY_SQL = """
UPDATE care.incidents i SET assessment_id = n.id, level = n.level, area = n.area
FROM risk_assessments n WHERE i.id = %(iid)s AND n.id = %(new)s
"""
CLOSE_SQL = "UPDATE care.incidents SET closed_at = now() WHERE id = %(iid)s AND closed_at IS NULL"
CLOSE_OLD_MSG_SQL = """
UPDATE care.incidents SET closed_at = now()
WHERE closed_at IS NULL AND note LIKE 'disaster_message:%%' AND started_at < now() - make_interval(hours => %(h)s)
RETURNING id, title
"""

RECENT_MSG_SQL = """
SELECT external_id, category, hazard::text AS hazard, message FROM disaster_messages
WHERE sent_at > now() - make_interval(mins => %(min)s) ORDER BY sent_at
"""
MSG_INCIDENT_SQL = """
INSERT INTO care.incidents (hazard, level, title, area, source, note)
SELECT %(hazard)s::hazard_type, 'warning', %(title)s,
       ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326)::geography, %(r)s)::geometry), 'auto', %(note)s
WHERE NOT EXISTS (SELECT 1 FROM care.incidents WHERE note = %(note)s)
RETURNING id
"""
OPEN_MSG_INCIDENTS_SQL = """
SELECT i.id, i.hazard::text AS hazard, i.level::text AS level, m.external_id, m.message
FROM care.incidents i JOIN disaster_messages m ON i.note = 'disaster_message:' || m.external_id
WHERE i.closed_at IS NULL
"""

PUSH_SQL = """
SELECT a.id, a.title, a.body, a.hazard::text AS hazard, a.level::text AS level, a.incident_id, a.response_required,
       a.tts_text, d.fcm_token
FROM user_alerts a JOIN user_devices d ON d.user_id = a.user_id AND d.fcm_token IS NOT NULL
WHERE a.id = ANY(%(ids)s::uuid[])
"""
CLOSED_PUSH_SQL = """
SELECT DISTINCT t.incident_id, d.fcm_token FROM care.incident_targets t
JOIN user_devices d ON d.user_id = t.user_id AND d.fcm_token IS NOT NULL
WHERE t.incident_id = ANY(%(ids)s::uuid[])
"""


def _basis(v) -> dict:
    return v if isinstance(v, dict) else json.loads(v or "{}")


def _rank(a: dict, u: dict) -> tuple:
    b = _basis(a.get("basis"))
    d = float("inf")
    if b.get("station_lat") is not None and u.get("lat") is not None:
        dy = (float(b["station_lat"]) - u["lat"]) * 111_000
        dx = (float(b["station_lng"]) - u["lng"]) * 111_000 * math.cos(math.radians(u["lat"]))
        d = math.hypot(dx, dy)
    return (-LEVEL_NUM[a["level"]], d, a["id"])


def merge_groups(picked: dict) -> dict:
    """같은 묶음(침수·호우)에 대피 확인이 있으면 사용자에게 1건만 — 높은 단계, 같으면 침수(위치가 구체적) 우선.
    picked 를 그 자리에서 줄이고, 남긴 경고에 함께 발효 중인 재난 [{hazard, level}] 을 돌려준다 (문구에 한 줄 추가)"""
    also: dict[tuple, list] = {}
    users = {k[0] for k in picked}
    for uid in users:
        for group in policy.EVAC_GROUPS:
            ks = [(uid, h) for h in group if (uid, h) in picked]
            if len(ks) < 2 or not any(policy.classify(picked[k][0]["hazard"], picked[k][0]["level"]) == "evacuation"
                                      for k in ks):
                continue
            ks.sort(key=lambda k: (-LEVEL_NUM[picked[k][0]["level"]], group.index(k[1]), _rank(*picked[k])))
            keep, drop = ks[0], ks[1:]
            also[keep] = [{"hazard": picked[k][0]["hazard"], "level": picked[k][0]["level"]} for k in drop]
            for k in drop:
                del picked[k]
    return also


# ------------------------------------------------------------------ 대피 상황 (care.incidents)
def ensure_incident(a: dict) -> Optional[str]:
    """판정의 진행 중 대피 상황 id. 방재단이 이미 종료한 판정이면 None (다시 만들지 않음)"""
    if db.fetch_one(CLOSED_BY_STAFF_SQL, {"aid": a["id"]}):
        return None
    simulated = bool(_basis(a.get("basis")).get("simulated"))
    row = db.fetch_one(ENSURE_INCIDENT_SQL, {"aid": a["id"], "title": a.get("label") or _title(a),
                                             "source": "simulated" if simulated else "auto"})
    if row is None:
        row = db.fetch_one(OPEN_INCIDENT_SQL, {"aid": a["id"]})
    return str(row["id"])


def _title(a: dict) -> str:
    return f"{HAZARD_KO.get(a['hazard'], a['hazard'])} {messages.LEVEL_KO.get(a['level'], a['level'])}"


def settle_incidents() -> list[dict]:
    """판정이 닫힌 대피 상황 정리. 반환: 종료한 상황 [{id, title}]"""
    closed = []
    for i in db.fetch_all(STALE_INCIDENTS_SQL):
        nxt = db.fetch_one(SUCCESSOR_SQL, {"old": i["assessment_id"], "min_level": policy.EVAC_MIN_LEVEL})
        if nxt:
            try:
                db.execute(CARRY_SQL, {"iid": i["id"], "new": nxt["id"]})
                log.info("대피 상황 %s → 판정 %s (%s) 로 이어감", i["id"], nxt["id"], nxt["level"])
                continue
            except Exception as e:  # noqa: BLE001 — 다른 상황이 먼저 같은 판정을 가져감 (uq_incidents_assessment)
                log.info("대피 상황 %s 이어 붙이기 실패 (%s) → 종료", i["id"], type(e).__name__)
        db.execute(CLOSE_SQL, {"iid": i["id"]})
        closed.append({"id": str(i["id"]), "title": i["title"]})
    closed += [{"id": str(r["id"]), "title": r["title"]}
               for r in db.fetch_all(CLOSE_OLD_MSG_SQL, {"h": MESSAGE_INCIDENT_HOURS})]
    return closed


def open_message_incidents() -> int:
    """최근 재난문자 중 구룡포 대피 지시 → 구룡포읍 영역 대피 상황. 반환: 새로 만든 수"""
    n = 0
    for m in db.fetch_all(RECENT_MSG_SQL, {"min": MESSAGE_LOOKBACK_MIN}):
        if not policy.is_evac_message(m["message"]):
            continue
        hz = policy.message_hazard(m.get("hazard"), m.get("category"), m["message"])
        row = db.fetch_one(MSG_INCIDENT_SQL, {
            "hazard": hz, "title": f"재난문자 대피 안내 · {HAZARD_KO.get(hz, hz)}", "note": MSG_NOTE + m["external_id"],
            "lng": GURYONGPO_CENTER[0], "lat": GURYONGPO_CENTER[1], "r": GURYONGPO_RADIUS_M})
        if row:
            n += 1
            db.execute(HOUSEHOLD_TARGETS_SQL, {"iid": row["id"]})
            log.info("재난문자 %s → 대피 상황 %s", m["external_id"], row["id"])
    return n


# ------------------------------------------------------------------ 경고
def targets(area_sql: str, params: dict, user_id: Optional[str]) -> list[dict]:
    return db.fetch_all(TARGETS_SQL.format(area=area_sql),
                        {**params, "uid": user_id, "loc_min": LOCATION_MAX_AGE_MIN})


def insert_alert(u: dict, event: dict, key: str, assessment_id, incident_id: Optional[str]) -> Optional[str]:
    m = messages.compose(event, u)
    evac = event["kind"] == "evacuation"
    row = db.fetch_one(INSERT_ALERT_SQL, {
        "uid": u["user_id"], "hazard": event["hazard"], "level": event["level"], "title": m["title"], "body": m["body"],
        "reason": json.dumps(m["reason"], ensure_ascii=False), "actions": json.dumps(m["actions"], ensure_ascii=False),
        "aid": assessment_id, "pid": u.get("place_id"), "lat": u["lat"], "lng": u["lng"], "key": key,
        "rr": evac, "iid": incident_id if evac else None, "tts": m["tts_text"]})
    if row is None:
        return None                                   # 이미 보낸 경고
    alert_id = str(row["id"])
    if evac and incident_id:
        db.execute(INSERT_TARGET_SQL, {"iid": incident_id, "uid": u["user_id"], "alert_id": alert_id,
                                       "lat": u["lat"], "lng": u["lng"]})
    return alert_id


def start_manual(incident_id: str, hazard: str, level: str, title: str, message: Optional[str]) -> int:
    """방재단 수동 시작 (POST /admin/incidents) — 영역 안 등록 가구를 대상에 넣고, 영역 안 사용자에게 대피 확인 경고. 반환: 새 경고 수"""
    db.execute(HOUSEHOLD_TARGETS_SQL, {"iid": incident_id})
    event = {"kind": "evacuation", "hazard": hazard, "level": level, "reason": title, "notice": message}
    new_ids = [aid for u in targets(AREA_OF_INCIDENT, {"iid": incident_id}, None)
               if (aid := insert_alert(u, event, f"inc:{incident_id}", None, incident_id))]
    push_alerts(new_ids)
    log.info("수동 대피 상황 %s: 경고 %d건", incident_id, len(new_ids))
    return len(new_ids)


def push_alerts(ids: list[str]) -> dict:
    if not ids:
        return {}
    pushes = []
    for r in db.fetch_all(PUSH_SQL, {"ids": ids}):
        kind = "evacuation" if r["response_required"] else "alert"
        pushes.append(fcm.Push(token=r["fcm_token"], title=r["title"], body=r["body"], ref=str(r["id"]),
                               data=fcm.payload(kind, alert_id=r["id"], incident_id=r["incident_id"], hazard=r["hazard"],
                                                level=r["level"], level_num=LEVEL_NUM[r["level"]],
                                                action="respond" if kind == "evacuation" else "open_alert",
                                                tts_text=r["tts_text"])))
    stats = fcm.send(pushes)
    ok = list(stats.pop("ok_refs", set()))
    if ok:
        db.execute("UPDATE user_alerts SET pushed_at = now() WHERE id = ANY(%(ids)s::uuid[])", {"ids": ok})
    return stats


def push_closed(closed: list[dict]) -> None:
    if not closed:
        return
    titles = {c["id"]: c["title"] for c in closed}
    rows = db.fetch_all(CLOSED_PUSH_SQL, {"ids": list(titles)})
    fcm.send([fcm.Push(token=r["fcm_token"], title="대피 상황 종료",
                       body=f"{titles.get(str(r['incident_id']), '대피 상황')}이(가) 종료되었습니다. 안전을 확인한 뒤 움직이세요.",
                       data=fcm.payload("incident_closed", incident_id=r["incident_id"])) for r in rows])


def run(run_id: Optional[int] = None, user_id: Optional[str] = None) -> int:
    """경고 생성 1회. user_id 를 주면 그 사용자만 (대피 상황 정리·재난문자·가구 대상은 수집기 주기 실행에서만). 반환: 새 경고 수"""
    closed = []
    if user_id is None:
        closed = settle_incidents()
        open_message_incidents()

    # 판정 → 사용자별·재난별 가장 높은 단계 1건 (같은 단계면 원인 관측소가 가장 가까운 것 — 그 위치 사정을 가장 잘 설명)
    active = db.fetch_all(ACTIVE_SQL)
    picked: dict[tuple, tuple[dict, dict]] = {}
    for a in active:
        if policy.classify(a["hazard"], a["level"]) is None:
            continue
        for u in targets(AREA_OF_ASSESSMENT, {"aid": a["id"]}, user_id):
            k = (str(u["user_id"]), a["hazard"])
            if k not in picked or _rank(a, u) < _rank(*picked[k]):
                picked[k] = (a, u)
    also = merge_groups(picked)

    new_ids, incidents = [], {}
    for k, (a, u) in picked.items():
        kind = policy.classify(a["hazard"], a["level"])
        iid = None
        if kind == "evacuation":
            if a["id"] not in incidents:
                incidents[a["id"]] = ensure_incident(a)
            iid = incidents[a["id"]]
            if iid is None:                            # 방재단이 종료한 상황 → 일반 경고로
                kind = "alert"
        event = {"kind": kind, "hazard": a["hazard"], "level": a["level"], "reason": _basis(a.get("basis")).get("reason"),
                 "also": also.get(k, [])}
        aid = insert_alert(u, event, f"ra:{a['id']}", a["id"], iid)
        if aid:
            new_ids.append(aid)
    if user_id is None:
        for a in active:                               # 경보 이상이면 대상 사용자가 없어도 대피 상황·등록 가구는 만든다
            if policy.classify(a["hazard"], a["level"]) == "evacuation":
                iid = incidents.get(a["id"]) or ensure_incident(a)
                if iid:
                    db.execute(HOUSEHOLD_TARGETS_SQL, {"iid": iid})

    # 재난문자 대피 상황 → 구룡포읍 안 사용자 전체
    for i in db.fetch_all(OPEN_MSG_INCIDENTS_SQL):
        event = {"kind": "evacuation", "hazard": i["hazard"], "level": i["level"], "message": i["message"]}
        for u in targets(AREA_OF_INCIDENT, {"iid": i["id"]}, user_id):
            u = {**u, "trigger": "broadcast", "place_id": None, "place_label": None}
            aid = insert_alert(u, event, f"msg:{i['external_id']}", None, str(i["id"]))
            if aid:
                new_ids.append(aid)

    stats = push_alerts(new_ids)
    push_closed(closed)
    if user_id is None or new_ids:
        log.info("alerts: active=%d new=%d closed_incidents=%d push=%s user=%s",
                 len(active), len(new_ids), len(closed), stats, user_id)
    return len(new_ids)
