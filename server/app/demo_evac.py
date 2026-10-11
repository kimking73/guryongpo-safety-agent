"""시연 대피 응답 (2026-10-12) — 시연 모드의 대피 경보 응답을 서버에 저장해 다른 계정의 방재단원 화면과 주고받는다

- 주민(사용자 모드) 계정: start(새 시연 경보) → respond(대피 완료·대피 중·도움 필요). 계정당 한 줄(care.demo_evac) + 이력(demo_evac_log)
- 방재단원 모드 계정: responses() 로 최근 시연 응답을 읽고, '실제 출발'·업무 단계를 dispatch() 로 그 주민 줄에 쓴다
  → 주민 앱은 mine() 으로 출동 기록(도착 예정 시각)을 받는다
- 실제 대피 상황(care.incidents·incident_targets)·FCM·이관과는 분리. 시연 데이터라 역할 없이 로그인만으로 본다 (사용자 결정 2026-10-12).
  공유 항목은 별명·응답·장애 유형뿐 — 집 주소·전화·실제 위치는 받지도 돌려주지도 않는다 (위치는 시연 기본점 둘레의 가상 좌표)
"""
from __future__ import annotations

import json
from typing import Optional

from . import db
from .errors import ApiError
from .mocks import iso

ACTIVE_HOURS = 3                  # 이만큼 바뀐 게 없으면 목록에서 뺀다 (지난 시연이 남지 않게)
TARGET_PREFIX = "demo-user-"
# 시연 주민 표시 위치: 시연 대피 경보 지역 안의 기본점 둘레 (앱 DemoLiveApi 의 예전 '앱 사용자' 위치와 같은 기본점).
# 사람마다 다른 칸 — 지도 표시가 겹치지 않게, 계정 id 로 고르므로 새로 읽어도 자리가 그대로다
BASE = (35.9893, 129.5541)
OFFSETS = [(0, 0), (0.0007, 0.0005), (-0.0006, 0.0008), (0.0004, -0.0009), (-0.0009, -0.0004),
           (0.0011, -0.0002), (-0.0002, 0.0012), (0.0009, 0.0010)]

START_SQL = """
INSERT INTO care.demo_evac (user_id, status, needs) VALUES (%(uid)s, 'no_response', %(needs)s)
ON CONFLICT (user_id) DO UPDATE SET status = 'no_response', needs = EXCLUDED.needs, started_at = now(), responded_at = NULL,
    updated_at = now(), dispatch = NULL, dispatch_by = NULL, dispatch_at = NULL
"""
RESPOND_SQL = """
INSERT INTO care.demo_evac (user_id, status, needs, responded_at) VALUES (%(uid)s, %(status)s, %(needs)s, now())
ON CONFLICT (user_id) DO UPDATE SET status = EXCLUDED.status, needs = EXCLUDED.needs, responded_at = now(), updated_at = now()
"""
DISPATCH_SQL = """
UPDATE care.demo_evac SET dispatch = %(d)s::jsonb, dispatch_by = %(by)s, dispatch_at = now(), updated_at = now()
WHERE user_id = %(tid)s AND updated_at > now() - make_interval(hours => %(h)s)
"""
LOG_SQL = """
INSERT INTO care.demo_evac_log (user_id, kind, status, via, by_user_id, data)
VALUES (%(uid)s, %(kind)s, %(status)s, %(via)s, %(by)s, %(data)s::jsonb)
"""
ROWS_SQL = """
SELECT d.user_id, u.nickname, d.status, d.needs, d.started_at, d.responded_at, d.updated_at, d.dispatch, d.dispatch_by,
       (EXTRACT(EPOCH FROM now() - d.started_at) / 60)::int AS minutes
FROM care.demo_evac d JOIN users u ON u.id = d.user_id
WHERE d.updated_at > now() - make_interval(hours => %(h)s) {where}
ORDER BY d.started_at
"""


def _log(uid: str, kind: str, status: Optional[str] = None, via: Optional[str] = None,
         by: Optional[str] = None, data: Optional[dict] = None) -> None:
    db.execute(LOG_SQL, {"uid": uid, "kind": kind, "status": status, "via": via, "by": by or uid,
                         "data": json.dumps(data, ensure_ascii=False) if data is not None else None})


def _slot(uid: str) -> int:
    return int(uid.replace("-", "")[:8], 16) % len(OFFSETS)


def target_out(r: dict, me: Optional[str], slot: Optional[int] = None) -> dict:
    uid = str(r["user_id"])
    k = _slot(uid) if slot is None else slot
    dy, dx = OFFSETS[k % len(OFFSETS)]
    dy, dx = dy * (1 + k // len(OFFSETS)), dx * (1 + k // len(OFFSETS))     # 칸이 모자라면 한 바퀴 더 바깥으로
    d = r.get("dispatch")
    if isinstance(d, str):
        d = json.loads(d)
    return {
        "id": TARGET_PREFIX + uid,
        "label": r.get("nickname") or f"시연 주민 {uid[:4]}",
        "status": r["status"],
        "needs": list(r.get("needs") or []),
        "minutes_since_alert": max(0, int(r.get("minutes") or 0)),
        "started_at": iso(r["started_at"]),
        "responded_at": iso(r.get("responded_at")),
        "updated_at": iso(r["updated_at"]),
        "is_me": uid == me,
        "location": {"lat": round(BASE[0] + dy, 6), "lng": round(BASE[1] + dx, 6)},
        "dispatch": d or None,
        "dispatch_by_me": bool(d) and me is not None and str(r.get("dispatch_by")) == me,   # 내가(이 방재단원이) 보낸 출동인지
    }


def mine(uid: str) -> Optional[dict]:
    r = db.fetch_one(ROWS_SQL.format(where="AND d.user_id = %(uid)s"), {"h": ACTIVE_HOURS, "uid": uid})
    return target_out(r, uid) if r else None


def start(uid: str, needs: list[str]) -> Optional[dict]:
    db.execute(START_SQL, {"uid": uid, "needs": list(needs)})
    _log(uid, "start", "no_response", data={"needs": list(needs)})
    return mine(uid)


def respond(uid: str, status: str, needs: list[str], via: str) -> Optional[dict]:
    db.execute(RESPOND_SQL, {"uid": uid, "status": status, "needs": list(needs)})
    _log(uid, "response", status, via, data={"needs": list(needs)})
    return mine(uid)


def responses(me: Optional[str]) -> list[dict]:
    rows = db.fetch_all(ROWS_SQL.format(where=""), {"h": ACTIVE_HOURS})
    # 자리는 계정마다 정해진 칸, 같은 칸이 이미 쓰였으면 다음 빈 칸 (목록 안에서 겹치지 않게)
    taken: set[int] = set()
    out = []
    for r in rows:
        k = _slot(str(r["user_id"]))
        while k in taken:
            k += 1
        taken.add(k)
        out.append(target_out(r, me, k))
    return out


def resident_id(target_id: str) -> str:
    """'demo-user-<uuid>' 또는 uuid → 주민 계정 id"""
    from uuid import UUID
    raw = target_id[len(TARGET_PREFIX):] if target_id.startswith(TARGET_PREFIX) else target_id
    try:
        return str(UUID(raw))
    except ValueError:
        raise ApiError("NOT_FOUND") from None


def dispatch(target_id: str, data: Optional[dict], by: str) -> None:
    """방재단원 출동 기록 쓰기(data) · 지우기(None). 진행 중인 시연 응답이 없으면 404"""
    tid = resident_id(target_id)
    n = db.execute(DISPATCH_SQL, {"tid": tid, "by": by, "h": ACTIVE_HOURS,
                                  "d": json.dumps(data, ensure_ascii=False) if data is not None else None})
    if not n:
        raise ApiError("NOT_FOUND", "진행 중인 시연 대피 응답이 없습니다.", detail="demo_evac_not_found")
    _log(tid, "dispatch", (data or {}).get("stage"), by=by, data=data)
