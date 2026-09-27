"""요청 본문 모델 (api/openapi.yaml 의 components.schemas 와 같은 이름·제약)

응답은 아직 목업이라 모델을 두지 않는다. 실구현 단계에서 응답 모델을 추가한다.
"""
from __future__ import annotations

from typing import Literal, Optional
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class _In(BaseModel):
    model_config = ConfigDict(extra="ignore")


class LatLng(_In):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


class ProfileInput(_In):
    nickname: Optional[str] = None
    user_type: Optional[Literal["resident", "tourist", "worker"]] = None
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


class PlaceInput(_In):
    place_type: Literal["home", "work", "frequent", "lodging"]
    label: str = Field(min_length=1)
    address: Optional[str] = None
    location: LatLng
    notify: bool = True


class PlacePatch(_In):
    place_type: Optional[Literal["home", "work", "frequent", "lodging"]] = None
    label: Optional[str] = None
    address: Optional[str] = None
    location: Optional[LatLng] = None
    notify: Optional[bool] = None


class EmergencyContactInput(_In):
    name: str = Field(min_length=1)
    relation: Optional[str] = None
    phone: str = Field(min_length=3)
    priority: int = 1


class DeviceTokenInput(_In):
    token: str = Field(min_length=1)
    platform: Literal["ios", "android", "web"]


class ChatRequest(_In):
    session_id: Optional[UUID] = None
    content: str = Field(min_length=1, max_length=2000)
    location: Optional[LatLng] = None
    want_audio: bool = False


class RouteAvoid(_In):
    flood: Optional[bool] = None
    landslide: Optional[bool] = None
    manhole: Optional[bool] = None
    coastal: Optional[bool] = None
    max_slope_pct: Optional[float] = None


class RouteRequest(_In):
    origin: LatLng
    destination: Optional[LatLng] = None
    shelter_id: Optional[int] = None
    profile: Optional[Literal["fastest", "safe", "elderly", "wheelchair", "car"]] = None
    avoid: Optional[RouteAvoid] = None


class RouteCheckRequest(_In):
    route_id: UUID
    location: LatLng


class SimulateRequest(_In):
    scenario: Literal["typhoon_hinnamnor_2022", "heavy_rain_flood", "landslide", "fine_dust", "clear"]
