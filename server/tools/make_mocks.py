"""목업 JSON 생성 — 시나리오: 2026-10-05 14:30 호우경보 발효 중, 구룡포항 일대 침수.
모든 장소·수치는 가상 예시 데이터."""
import json, os

OUT = "../mock"
os.makedirs(OUT, exist_ok=True)
T = "2026-10-05T14:30:00+09:00"
HERE = {"lat": 35.9903, "lng": 129.5558}          # 사용자 현재 위치 (구룡포환승센터 인근)
HOME = {"lat": 35.9862, "lng": 129.5489}

R_RAIN = {"hazard": "heavy_rain", "level": "warning", "level_num": 3, "label": "호우경보",
          "reason": "3시간 누적강수 92.0mm (구룡포 AWS, 14:30 관측)", "location": HERE,
          "area_id": 1021, "rule_id": 2, "observed_at": T}
T14 = "2026-10-05T14:27:00+09:00"                   # 포항 DT 수집 시각 (원천 측정 시각은 제공되지 않음)
R_FLOOD = {"hazard": "flood", "level": "warning", "level_num": 3, "label": "침수 경보",
           "reason": "구룡포환승센터 지표면 수위계 침수심 230mm (기준 150mm) · 포항 DT 4단계(경보)", "location": HERE,
           "area_id": 1022, "rule_id": 23, "observed_at": T14}

# 포항 DT 수위계 (실제 센서 위치·이름, 값은 시나리오 가상값)
SENSORS = [   # (id, 이름, kind, lat, lng, value(mm), 포항 DT level 1~5)  ※ 실제 센서 이름·위치, 값·등급은 가상 시나리오
    (1,  "구룡포교_하천수위계",           "river_level", 35.987244, 129.550467, 1850, 3),
    (2,  "하나과메기_스마트맨홀",          "manhole",     35.985929, 129.549278, None, 1),
    (3,  "로터리종합건재_스마트맨홀",      "manhole",     35.987373, 129.551115, None, 2),
    (4,  "구룡포수협_스마트맨홀",          "manhole",     35.991235, 129.557327, None, 4),
    (5,  "구룡포읍행정복지센터_강우량계",  "rain_gauge",  35.984987, 129.546115, 38.5, 4),
    (7,  "하나과메기_지표면 수위계",       "road_flood",  35.986115, 129.549245, 0,    1),
    (8,  "구룡포파출소_지표면 수위계",     "road_flood",  35.988698, 129.553056, 60,   2),
    (9,  "해양경찰서_지표면 수위계",       "road_flood",  35.98947,  129.554646, 110,  3),
    (10, "구룡포환승센터_지표면 수위계",   "road_flood",  35.99069,  129.556057, 230,  4),
    (11, "구룡포수협_지표면 수위계",       "road_flood",  35.991109, 129.557354, 170,  3),
]
METRIC = {"manhole": "manhole_level", "road_flood": "flood_depth", "river_level": "river_level", "rain_gauge": "rain_1h"}
DT_LEVEL = {1: ("normal", "정상"), 2: ("watch", "보통"), 3: ("advisory", "주의"), 4: ("warning", "경보"), 5: ("critical", "위험")}
R_SLIDE = {"hazard": "landslide", "level": "warning", "level_num": 3, "label": "산사태 경고",
           "reason": "호우경보 중 · 등록 장소 '우리집'이 산사태 위험지역 내부", "location": HOME,
           "area_id": 1023, "rule_id": 11, "observed_at": T}
R_UV = {"hazard": "uv", "level": "watch", "level_num": 1, "label": "자외선 보통",
        "reason": "자외선지수 4 (포항 디지털 트윈, 14:00)", "location": HERE,
        "area_id": None, "rule_id": 17, "observed_at": "2026-10-05T14:00:00+09:00"}

SH1 = {"id": 12, "name": "구룡포읍 대피소 A (예시)", "shelter_types": ["flood", "earthquake"],
       "address": "경북 포항시 남구 구룡포읍 (예시 주소)", "capacity": 300, "is_accessible": True,
       "location": {"lat": 35.9921, "lng": 129.5512}, "distance_m": 540, "in_risk_area": False}
SH2 = {"id": 15, "name": "구룡포읍 대피소 B (예시)", "shelter_types": ["flood"],
       "address": "경북 포항시 남구 구룡포읍 (예시 주소)", "capacity": 150, "is_accessible": False,
       "location": {"lat": 35.9950, "lng": 129.5470}, "distance_m": 1010, "in_risk_area": False}

PLACE_HOME = {"id": "7b1f6a3e-2c4d-4e8f-9a01-3b5c7d9e1f20", "place_type": "home", "label": "우리집",
              "address": None, "location": HOME, "notify": True, "in_hazard_zones": ["landslide"]}
PLACE_PORT = {"id": "8c2e7b4f-3d5e-4f90-8b12-4c6d8e0f2a31", "place_type": "work", "label": "구룡포항 3부두",
              "address": None, "location": {"lat": 35.9893, "lng": 129.5571}, "notify": True,
              "in_hazard_zones": ["flood", "high_seas"]}

mocks = {}

mocks["health.json"] = {"status": "ok", "version": "0.2.0", "components": {
    "db": {"status": "ok", "last_success_at": T},
    "ingest.kma": {"status": "ok", "last_success_at": "2026-10-05T14:25:00+09:00"},
    "ingest.pohang_dt": {"status": "ok", "last_success_at": "2026-10-05T14:27:00+09:00"},
    "ingest.safety24": {"status": "degraded", "last_success_at": "2026-10-05T13:50:00+09:00"},
    "graphhopper": {"status": "ok", "last_success_at": T},
    "gemini": {"status": "ok", "last_success_at": T}}}

mocks["user.json"] = {
    "id": "3f2a1c9e-8b7d-4e6f-a5c4-1d2e3f4a5b6c", "firebase_uid": "Xk2mP9qR4sT7uV1wY3zA5bC8dE0f",
    "is_anonymous": True,
    "profile": {"nickname": "하린", "user_type": "resident", "birth_year": 1958, "mobility": "walk",
                "occupation": "fisher", "owns_vessel": True, "walking_ability": "limited",
                "vision_impaired": False, "hearing_impaired": False, "blood_type": "A+",
                "has_dependents": False, "dependents_note": None, "medical_note": "고혈압 약 복용",
                "prefers_voice": True},
    "places": [PLACE_HOME, PLACE_PORT],
    "contacts": [{"id": "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b", "name": "김OO", "relation": "딸",
                  "phone": "010-0000-0000", "priority": 1}],
    "onboarding": {"completed": True, "missing": []},
    "created_at": "2026-10-01T09:12:00+09:00"}

mocks["device-token.json"] = {"device_id": "9a8b7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d"}

def widgets_normal():
    return [
        {"type": "forecast", "emphasized": False, "data": {"slots": [
            {"t": "2026-10-05T15:00:00+09:00", "pop": 30, "pty": "없음", "pcp_mm": 0, "tmp": 21, "wsd": 3.2},
            {"t": "2026-10-05T18:00:00+09:00", "pop": 60, "pty": "비", "pcp_mm": 2.0, "tmp": 19, "wsd": 4.8}]}},
        {"type": "life_safety", "emphasized": False, "data": {"items": [
            {**R_UV, "value": 4, "unit": "index"},
            {"hazard": "fine_dust", "level": "normal", "level_num": 0, "label": "미세먼지 좋음",
             "value": 28, "unit": "㎍/㎥"}]}},
        {"type": "checklist", "emphasized": False, "data": {"hazard": "typhoon", "items": [
            {"id": 31, "content": "선박 결박 상태와 계류줄 점검", "checked": False, "is_often_missed": True},
            {"id": 32, "content": "비상용 손전등·보조배터리 준비", "checked": True, "is_often_missed": False}]}},
        {"type": "disaster_messages", "emphasized": False, "data": {"items": []}}]

mocks["dashboard.normal.json"] = {
    "mode": "normal", "headline": None,
    "point_risk": {"location": HERE, "max_level": "watch", "max_level_num": 1, "items": [R_UV], "computed_at": T},
    "places": [{"place_id": PLACE_HOME["id"], "label": "우리집", "max_level": "normal", "max_level_num": 0},
               {"place_id": PLACE_PORT["id"], "label": "구룡포항 3부두", "max_level": "normal", "max_level_num": 0}],
    "widgets": widgets_normal(), "highlight_layers": [], "nearest_shelters": [SH1, SH2], "updated_at": T}

mocks["dashboard.emergency.json"] = {
    "mode": "emergency",
    "headline": {"risk": R_RAIN, "title": "호우경보 · 현재 위치 침수 — 가까운 대피소로 이동하세요", "action": "open_route"},
    "point_risk": {"location": HERE, "max_level": "warning", "max_level_num": 3,
                   "items": [R_RAIN, R_FLOOD, R_UV], "computed_at": T},
    "places": [{"place_id": PLACE_HOME["id"], "label": "우리집", "max_level": "warning", "max_level_num": 3},
               {"place_id": PLACE_PORT["id"], "label": "구룡포항 3부두", "max_level": "advisory", "max_level_num": 2}],
    "widgets": [
        {"type": "warnings", "emphasized": True, "data": {"items": [
            {"label": "호우경보", "region_name": "포항시", "issued_at": "2026-10-05T13:00:00+09:00"}]}},
        {"type": "water_level", "emphasized": True, "data": {"observed_at": T14, "stations": [
            {"station_id": sid, "station_name": nm, "kind": kd, "metric": METRIC[kd], "value": v, "unit": "mm",
             "source_level": lv, "source_level_label": DT_LEVEL[lv][1], "level": DT_LEVEL[lv][0],
             "location": {"lat": la, "lng": ln}} for sid, nm, kd, la, ln, v, lv in SENSORS if kd != "rain_gauge"],
            "series": {"station_id": 10, "metric": "flood_depth", "points": [
                {"t": "2026-10-05T13:27:00+09:00", "v": 0}, {"t": "2026-10-05T13:57:00+09:00", "v": 90},
                {"t": T14, "v": 230}]}}},
        {"type": "rain", "emphasized": True, "data": {
            "station_name": "구룡포 AWS", "value": 92.0, "unit": "mm/3h", "observed_at": T, "level": "warning",
            "series": [{"t": "2026-10-05T12:30:00+09:00", "v": 18.5},
                       {"t": "2026-10-05T13:30:00+09:00", "v": 51.0}, {"t": T, "v": 92.0}]}},
        {"type": "disaster_messages", "emphasized": True, "data": {"items": [
            {"sent_at": "2026-10-05T13:05:00+09:00", "sender": "포항시",
             "message": "[포항시] 호우경보 발효. 하천변·해안가 저지대 접근 금지, 산사태 위험지역 주민은 대피 바랍니다. (예시)"}]}},
        {"type": "checklist", "emphasized": False, "data": {"hazard": "flood", "items": [
            {"id": 41, "content": "전기 차단기 내리기", "checked": False, "is_often_missed": True},
            {"id": 42, "content": "맨홀·배수구 주변으로 걷지 않기", "checked": False, "is_often_missed": True}]}},
        {"type": "forecast", "emphasized": False, "data": {"slots": [
            {"t": "2026-10-05T15:00:00+09:00", "pop": 90, "pty": "비", "pcp_mm": 30.0, "tmp": 19, "wsd": 9.1}]}}],
    "highlight_layers": ["risk_areas", "shelters", "manholes", "landslide_zones"],
    "nearest_shelters": [SH1, SH2], "updated_at": T}

def feat(i, geom, props):
    return {"type": "Feature", "id": i, "geometry": geom, "properties": props}

mocks["layer.shelters.geojson"] = {"type": "FeatureCollection", "features": [
    feat(s["id"], {"type": "Point", "coordinates": [s["location"]["lng"], s["location"]["lat"]]},
         {k: v for k, v in s.items() if k not in ("location", "distance_m")}) for s in (SH1, SH2)]}

mocks["risk-areas.geojson"] = {"type": "FeatureCollection", "features": [
    feat(1022, {"type": "Polygon", "coordinates": [[[129.5544, 35.9896], [129.5577, 35.9896],
                                                     [129.5577, 35.9920], [129.5544, 35.9920],
                                                     [129.5544, 35.9896]]]}, R_FLOOD),
    feat(1023, {"type": "Polygon", "coordinates": [[[129.5470, 35.9850], [129.5500, 35.9850],
                                                     [129.5500, 35.9875], [129.5470, 35.9875],
                                                     [129.5470, 35.9850]]]}, R_SLIDE)]}

mocks["layer.stations.geojson"] = {"type": "FeatureCollection", "features": [
    feat(sid, {"type": "Point", "coordinates": [ln, la]},
         {"name": nm, "kind": kd, "source": "pohang_dt", "metric": METRIC[kd], "value": v, "unit": "mm",
          "source_level": lv, "source_level_label": DT_LEVEL[lv][1], "level": DT_LEVEL[lv][0], "observed_at": T14})
    for sid, nm, kd, la, ln, v, lv in SENSORS]}

mocks["risk.json"] = {"location": HERE, "max_level": "warning", "max_level_num": 3,
                      "items": [R_RAIN, R_FLOOD, R_UV], "computed_at": T}

mocks["alerts.json"] = {"alerts": [
    {"id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d", "risk": R_SLIDE,
     "title": "[산사태 경고] 우리집 주변 대피 필요",
     "body": "호우경보가 발효 중이고 '우리집'이 산사태 위험지역에 있습니다. 보행이 불편하시면 지금 바로 대피소로 이동하세요.",
     "reason": {"trigger": "place", "place_label": "우리집", "profile_tags": ["elderly", "walking_limited"]},
     "actions": [{"type": "open_route", "label": "대피 경로 보기", "params": {"shelter_id": 12}},
                 {"type": "call", "label": "딸에게 전화", "params": {"phone": "010-0000-0000"}}],
     "created_at": "2026-10-05T14:28:00+09:00", "read_at": None},
    {"id": "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e", "risk": R_FLOOD,
     "title": "[침수 경보] 구룡포환승센터 일대 침수",
     "body": "현재 위치 주변 도로 침수심 23cm, 구룡포수협 맨홀도 경보 단계입니다. 맨홀·배수구를 피해 높은 곳으로 이동하세요. 선박 점검은 물이 빠진 뒤에 하세요.",
     "reason": {"trigger": "current_location", "place_label": None, "profile_tags": ["fisher", "vessel_owner"]},
     "actions": [{"type": "open_route", "label": "안전 경로", "params": {}},
                 {"type": "open_checklist", "label": "침수 체크리스트", "params": {"hazard": "flood"}}],
     "created_at": T, "read_at": None}],
    "mode": "emergency", "server_time": "2026-10-05T14:30:05+09:00", "next_poll_sec": 15}

MSG = {"id": "c3d4e5f6-a7b8-4c9d-8e0f-2a3b4c5d6e7f", "role": "assistant",
       "content": "지금 구룡포에 **호우경보**가 발효 중이고, 계신 곳 주변 도로가 **23cm 잠긴** 상태예요.\n배를 확인하러 부두로 가지 마시고, 먼저 대피소 A로 이동하세요.",
       "blocks": [
           {"type": "action_steps", "title": "지금 할 일", "data": {"steps": [
               {"order": 1, "text": "부두·해안가로 가지 않기 (선박 점검은 경보 해제 후)"},
               {"order": 2, "text": "맨홀·배수구를 피해 대피소 A로 이동"},
               {"order": 3, "text": "딸에게 위치 알리기"}]}},
           {"type": "route_card", "title": "대피 경로",
            "data": {"route_id": "d4e5f6a7-b8c9-4d0e-9f1a-3b4c5d6e7f80", "shelter_name": SH1["name"],
                     "distance_m": 690, "duration_s": 780}},
           {"type": "call_button", "title": "긴급 전화", "data": {"label": "119 연결", "phone": "119"}}],
       "audio_url": None,
       "grounding": [
           {"kind": "warning", "ref_id": "88", "label": "호우경보 (포항시, 13:00 발효)"},
           {"kind": "observation", "ref_id": "10:flood_depth:2026-10-05T14:27", "label": "구룡포환승센터 지표면 수위계 침수심 230mm (14:27 수집)"},
           {"kind": "action_guide", "ref_id": "57", "label": "침수 시 행동요령 — 국민재난안전포털"}],
       "verification": "passed",
       "profile_suggestions": {},
       "created_at": "2026-10-05T14:30:09+09:00"}

mocks["chat.json"] = {"session_id": "e5f6a7b8-c9d0-4e1f-8a2b-4c5d6e7f8091", "message": MSG}

mocks["voice.json"] = {"session_id": "e5f6a7b8-c9d0-4e1f-8a2b-4c5d6e7f8091",
                       "transcript": "배 보러 부두에 가도 되나", "stt_confidence": 0.91,
                       "message": {**MSG, "audio_url": "http://localhost:8000/api/v1/voice/audio/tts_c3d4e5f6.mp3"}}

ROUTE = {"route_id": "d4e5f6a7-b8c9-4d0e-9f1a-3b4c5d6e7f80", "profile": "elderly",
         "destination": {"shelter": SH1, "location": SH1["location"]},
         "distance_m": 690, "duration_s": 780,
         "geometry": {"type": "LineString", "coordinates": [
             [129.5558, 35.9903], [129.5549, 35.9907], [129.5538, 35.9904],
             [129.5524, 35.9913], [129.5512, 35.9921]]},
         "instructions": [
             {"text": "북서쪽으로 120m 이동 (맨홀 구간 우회)", "distance_m": 120, "interval": [0, 1]},
             {"text": "왼쪽 골목으로 250m — 경사가 완만한 길", "distance_m": 250, "interval": [1, 3]},
             {"text": "320m 직진 후 대피소 A 도착", "distance_m": 320, "interval": [3, 4]}],
         "avoided": {"flood_areas": 1, "landslide_zones": 0, "manholes": 4, "steep_segments": 2},
         "remaining_risks": [], "computed_at": T}
mocks["route.json"] = ROUTE

mocks["route-check.json"] = {
    "status": "rerouted", "reason": "경로 앞 200m 구간에 새 침수 감지",
    "new_risks": [{**R_FLOOD, "location": {"lat": 35.9905, "lng": 129.5535}, "area_id": 1030}],
    "route": {**ROUTE, "route_id": "f6a7b8c9-d0e1-4f2a-8b3c-5d6e7f8091a2", "distance_m": 820, "duration_s": 930,
              "computed_at": "2026-10-05T14:33:00+09:00"},
    "remaining_m": 820}

for name, obj in mocks.items():
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
print(len(mocks), "mock files")
