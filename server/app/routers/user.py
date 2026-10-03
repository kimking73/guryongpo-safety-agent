"""사용자 · 장소 · 비상연락처 · 체크리스트 · 기기 토큰 · 역할 · 본인 가구 등록 — 인증 필요

목업: /user·장소·연락처·체크리스트·기기 토큰 (실구현 A5), /user/household (실구현 A13)
실데이터: /user/role (초대 코드 확인 → users.role). dev 모드에서는 DEMO-* 코드도 허용 (DB 없이 화면 개발용)"""
import uuid
from typing import Optional

from fastapi import APIRouter, Depends, Response

from .. import db, mocks
from ..auth import AuthUser, current_user
from ..config import settings
from ..errors import ApiError
from ..schemas import (DeviceTokenInput, EmergencyContactInput, PlaceInput, PlacePatch, ProfileInput, RoleClaim,
                       SelfHouseholdInput)

router = APIRouter(tags=["user"])


def _user(u: AuthUser) -> dict:
    d = mocks.load("user.json")
    d["firebase_uid"] = u.uid            # 호출한 사람의 uid 로 바꿔서 반환 (앱이 uid 일치를 확인할 수 있게)
    return d


@router.post("/user", status_code=201, summary="첫 실행 등록 (uid 기준 멱등)")
def register_user(body: Optional[ProfileInput] = None, u: AuthUser = Depends(current_user)):
    return mocks.respond(_user(u), 201)


@router.get("/user", summary="내 정보")
def get_user(u: AuthUser = Depends(current_user)):
    return mocks.respond(_user(u))


@router.patch("/user", summary="인적사항 부분 수정")
def update_user(body: ProfileInput, u: AuthUser = Depends(current_user)):
    d = _user(u)
    d["profile"].update(body.model_dump(exclude_unset=True))
    return mocks.respond(d)


@router.delete("/user", status_code=204, summary="탈퇴")
def delete_user(u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})


@router.post("/user/places", status_code=201, summary="장소 추가")
def add_place(body: PlaceInput, u: AuthUser = Depends(current_user)):
    return mocks.respond({"id": str(uuid.uuid4()), **body.model_dump(), "in_hazard_zones": []}, 201)


@router.patch("/user/places/{place_id}", summary="장소 수정")
def update_place(place_id: uuid.UUID, body: PlacePatch, u: AuthUser = Depends(current_user)):
    base = next((p for p in _user(u)["places"] if p["id"] == str(place_id)), None)
    if base is None:
        from ..errors import ApiError
        raise ApiError("NOT_FOUND")
    base.update(body.model_dump(exclude_unset=True))
    return mocks.respond(base)


@router.delete("/user/places/{place_id}", status_code=204, summary="장소 삭제")
def delete_place(place_id: uuid.UUID, u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})


@router.post("/user/contacts", status_code=201, summary="비상연락처 추가")
def add_contact(body: EmergencyContactInput, u: AuthUser = Depends(current_user)):
    return mocks.respond({"id": str(uuid.uuid4()), **body.model_dump()}, 201)


@router.delete("/user/contacts/{contact_id}", status_code=204, summary="비상연락처 삭제")
def delete_contact(contact_id: uuid.UUID, u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})


@router.put("/user/checklist/{item_id}", status_code=204, summary="체크리스트 체크")
def check_item(item_id: int, u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})


@router.delete("/user/checklist/{item_id}", status_code=204, summary="체크리스트 해제")
def uncheck_item(item_id: int, u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})


@router.post("/device-token", summary="FCM 토큰 등록 → device_id")
def register_device_token(body: DeviceTokenInput, u: AuthUser = Depends(current_user)):
    # 같은 uid+토큰이면 같은 device_id (앱 재시작 시 폴링 device_id 유지) — 실구현은 user_devices 테이블
    return mocks.respond({"device_id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"{u.uid}|{body.token}"))})


@router.delete("/device-token", status_code=204, summary="FCM 토큰 해제")
def delete_device_token(token: str, u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})


# ------------------------------------------------------------------ 역할 (v0.3, 초대 코드)
DEMO_CODES = {"DEMO-RESPONDER": "responder", "DEMO-CAREGIVER": "caregiver", "DEMO-ADMIN": "admin"}

# 코드 사용 횟수 증가와 역할 부여를 한 문장(한 트랜잭션)으로 — 만료·회수·횟수 초과 코드는 0행
CLAIM_SQL = """
WITH c AS (
  UPDATE care.invite_codes SET used_count = used_count + 1
  WHERE code_hash = %(h)s AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())
    AND (max_uses IS NULL OR used_count < max_uses)
  RETURNING role, label
), u AS (
  INSERT INTO users (firebase_uid, is_anonymous, role, role_granted_at)
  SELECT %(uid)s, %(anon)s, c.role, now() FROM c
  ON CONFLICT (firebase_uid) DO UPDATE SET role = EXCLUDED.role, role_granted_at = EXCLUDED.role_granted_at
  RETURNING role, role_granted_at
)
SELECT u.role::text AS role, c.label, u.role_granted_at AS granted_at FROM u, c
"""


def code_hash(code: str) -> str:
    import hashlib
    return hashlib.sha256(code.strip().upper().encode("utf-8")).hexdigest()


@router.post("/user/role", summary="초대 코드로 역할 받기")
def claim_role(body: RoleClaim, u: AuthUser = Depends(current_user)):
    code = body.invite_code.strip().upper()
    if settings.auth_mode == "dev" and code in DEMO_CODES:
        d = mocks.load("role.json")
        d.update(role=DEMO_CODES[code], granted_at=mocks.now_iso())
        return mocks.respond(d)
    row = db.fetch_one(CLAIM_SQL, {"h": code_hash(code), "uid": u.uid, "anon": u.is_anonymous})
    if not row:
        raise ApiError("INVALID_INVITE")
    return {"role": row["role"], "label": row["label"], "granted_at": mocks.iso(row["granted_at"])}


@router.delete("/user/role", status_code=204, summary="역할 내려놓기")
def drop_role(u: AuthUser = Depends(current_user)):
    db.execute("UPDATE users SET role = 'resident', role_granted_at = NULL WHERE firebase_uid = %(uid)s", {"uid": u.uid})
    return Response(status_code=204)


# ------------------------------------------------------------------ 본인 가구 등록 (목업, 실구현 A13)
@router.get("/user/household", summary="내 취약 가구 정보")
def get_my_household(u: AuthUser = Depends(current_user)):
    return mocks.mock("household.json")


@router.put("/user/household", summary="취약 가구로 본인 등록·수정 (동의 필수)")
def put_my_household(body: SelfHouseholdInput, u: AuthUser = Depends(current_user)):
    d = mocks.load("household.json")
    data = body.model_dump(exclude={"consent"}, exclude_unset=True)
    d.update({k: v for k, v in data.items() if v is not None})
    d["consent"] = {"at": mocks.now_iso(), "method": "app", "by": "본인"}
    d["updated_at"] = mocks.now_iso()
    return mocks.respond(d)


@router.delete("/user/household", status_code=204, summary="동의 철회 — 가구 정보 삭제")
def delete_my_household(u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})
