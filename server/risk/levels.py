"""위험 단계·재난 이름 (명세 4장)"""
LEVELS = ["normal", "watch", "advisory", "warning", "critical"]
LEVEL_NUM = {lv: i for i, lv in enumerate(LEVELS)}
HAZARD_KO = {"landslide": "산사태", "heavy_rain": "호우", "flood": "침수", "strong_wind": "강풍", "typhoon": "태풍",
             "high_seas": "풍랑", "fine_dust": "미세먼지", "ultrafine_dust": "초미세먼지", "uv": "자외선"}
DT_LEVEL_KO = {1: "정상", 2: "보통", 3: "주의", 4: "경보", 5: "위험"}
DT_TO_LEVEL = {1: "normal", 2: "watch", 3: "advisory", 4: "warning", 5: "critical"}

# 구룡포읍 전체에 적용하는 값(강우량계 1대, 자외선 전역값)의 영향 범위 — 읍 중심 반경 4km 원으로 근사
GURYONGPO_CENTER = (129.5481, 35.9858)      # (lng, lat)
GURYONGPO_RADIUS_M = 4000
