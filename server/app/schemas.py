"""요청 본문 모델 (server/spec/openapi.yaml 의 components.schemas 와 같은 이름·제약)

응답은 아직 목업이라 모델을 두지 않는다. 실구현 단계에서 응답 모델을 추가한다.
"""
from __future__ import annotations

from typing import Literal, Optional, Union
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator


class _In(BaseModel):
    model_config = ConfigDict(extra="ignore")


class LatLng(_In):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


class ProfileInput(_In):
    nickname: Optional[str] = None
    birth_year: Optional[int] = Field(default=None, ge=1900, le=2100)
    mobility: Optional[Literal["walk", "car", "bicycle", "public_transit", "wheelchair"]] = None
    occupation: Optional[str] = None
    owns_vessel: Optional[bool] = None
    walking_ability: Optional[Literal["normal", "limited", "unable"]] = None
    vision_impaired: Optional[bool] = None
    hearing_impaired: Optional[bool] = None
    blood_type: Optional[Literal["A+", "A-", "B+", "B-", "O+", "O-", "AB+", "AB-"]] = None
    has_dependents: Optional[bool] = None
    dependents_note: Optional[str] = None
    medical_note: Optional[str] = None
    prefers_voice: Optional[bool] = None
    language: Optional[str] = None
    alert_prefs: Optional["AlertPrefs"] = None


class AlertPrefs(_In):
    tts: Optional[bool] = None
    strong_vibration: Optional[bool] = None
    screen_flash: Optional[bool] = None
    large_text: Optional[bool] = None


class PlaceInput(_In):
    """도로명 주소·좌표 중 하나 이상 (2026-10-04). 좌표가 있으면 그대로 쓰고, 주소만 오면 서버가 카카오로 좌표 변환
    — 지번만 있는 집·항구, 지도에서 찍기·GPS 로 집 등록, 카카오 장애에도 등록 가능"""
    place_type: Literal["home", "work", "frequent", "lodging"]
    label: str = Field(min_length=1)
    address: Optional[str] = Field(default=None, min_length=1, max_length=300)
    location: Optional[LatLng] = None
    notify: bool = True

    @model_validator(mode="after")
    def _address_or_location(self):
        if not self.address and self.location is None:
            raise ValueError("address 또는 location 중 하나는 있어야 합니다")
        return self


class PlacePatch(_In):
    place_type: Optional[Literal["home", "work", "frequent", "lodging"]] = None
    label: Optional[str] = None
    address: Optional[str] = Field(default=None, max_length=300)
    location: Optional[LatLng] = None
    notify: Optional[bool] = None


class AddressGeocodeInput(_In):
    address: str = Field(min_length=1, max_length=300)


class EmergencyContactInput(_In):
    name: str = Field(min_length=1)
    relation: Optional[str] = None
    phone: str = Field(min_length=3)
    priority: int = 1


class DeviceTokenInput(_In):
    token: str = Field(min_length=1)
    platform: Literal["ios", "android", "web"]


class SimulateRequest(_In):
    # 구현된 시나리오만 (새로 만들면 명세와 함께 추가)
    scenario: Literal["heavy_rain_flood", "clear", "demo_households", "demo_households_clear"]


# ------------------------------------------------------------------ v0.3 역할 · 가구 · 대피 확인 (A5·A12~A14)
HouseholdNeed = Literal["elderly", "living_alone", "mobility_limited", "wheelchair", "bedridden", "hearing", "vision",
                        "cognitive", "medical_device", "infant", "pet"]
ButtonStatus = Literal["evacuated", "evacuating", "need_help"]      # 대피 완료 / 대피 중 / 도움 필요


class RoleClaim(_In):
    invite_code: str = Field(min_length=4, max_length=64)


class SelfHouseholdInput(_In):
    label: Optional[str] = None
    address: Optional[str] = None
    location: LatLng
    phone: Optional[str] = None
    members: int = Field(default=1, ge=1)
    needs: list[HouseholdNeed] = Field(default_factory=list)
    note: Optional[str] = Field(default=None, max_length=300)
    consent: Literal[True]                    # 민감정보 수집·방재단 제공 동의 — true 가 아니면 422


class HouseholdInput(_In):
    label: str = Field(min_length=1)
    address: Optional[str] = None
    location: LatLng
    phone: Optional[str] = None
    members: int = Field(default=1, ge=1)
    needs: list[HouseholdNeed] = Field(default_factory=list)
    caregiver_user_id: Optional[UUID] = None
    consent_method: Literal["written", "verbal"]
    consent_by: str = Field(min_length=1)
    note: Optional[str] = Field(default=None, max_length=300)


class HouseholdPatch(_In):
    label: Optional[str] = None
    address: Optional[str] = None
    location: Optional[LatLng] = None
    phone: Optional[str] = None
    members: Optional[int] = Field(default=None, ge=1)
    needs: Optional[list[HouseholdNeed]] = None
    caregiver_user_id: Optional[UUID] = None
    note: Optional[str] = Field(default=None, max_length=300)
    active: Optional[bool] = None


class EvacuationResponseInput(_In):
    status: ButtonStatus
    via: Literal["button", "voice", "dashboard"]
    location: Optional[LatLng] = None
    note: Optional[str] = Field(default=None, max_length=200)
    transcript: Optional[str] = Field(default=None, max_length=500)


class IncidentCircle(_In):
    center: LatLng
    radius_m: float = Field(ge=50, le=5000)


class IncidentPolygon(_In):
    type: Literal["Polygon", "MultiPolygon"]
    coordinates: list


class IncidentInput(_In):
    hazard: Literal["landslide", "heavy_rain", "flood", "strong_wind", "typhoon", "high_seas", "fine_dust", "ultrafine_dust", "uv"]
    level: Literal["advisory", "warning", "critical"]
    title: str = Field(min_length=1)
    area: Union[IncidentCircle, IncidentPolygon]
    message: Optional[str] = None


class TargetPatch(_In):
    status: Optional[ButtonStatus] = None
    assigned_to: Optional[str] = None         # "me" = 나에게 지정, null = 해제
    note: Optional[str] = Field(default=None, max_length=300)


class VisitInput(_In):
    result: Literal["evacuated_with_help", "already_evacuated", "refused", "not_home", "transported", "other"]
    status_after: Optional[ButtonStatus] = None
    location: Optional[LatLng] = None
    note: Optional[str] = Field(default=None, max_length=300)


class InviteInput(_In):
    role: Literal["responder", "caregiver", "admin"]
    label: Optional[str] = None
    max_uses: Optional[int] = Field(default=None, ge=1)
    expires_in_days: int = Field(default=60, ge=1, le=365)


ProfileInput.model_rebuild()
