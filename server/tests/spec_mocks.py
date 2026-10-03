"""목업 JSON ↔ server/spec/openapi.yaml 응답 스키마 대응표 (test_spec.py 가 검사)"""
MOCK_SCHEMAS = {
    # 파일: (경로, 메서드, 상태, content-type)
    "health.json": ("/health", "get", "200", "application/json"),
    "user.json": ("/user", "get", "200", "application/json"),
    "role.json": ("/user/role", "post", "200", "application/json"),
    "household.json": ("/user/household", "get", "200", "application/json"),
    "device-token.json": ("/device-token", "post", "200", "application/json"),
    "dashboard.normal.json": ("/dashboard", "get", "200", "application/json"),
    "dashboard.emergency.json": ("/dashboard", "get", "200", "application/json"),
    "layer.shelters.geojson": ("/dashboard/layers/{layer_id}", "get", "200", "application/geo+json"),
    "layer.stations.geojson": ("/dashboard/layers/{layer_id}", "get", "200", "application/geo+json"),
    "risk.json": ("/risk", "get", "200", "application/json"),
    "risk-areas.geojson": ("/risk/areas", "get", "200", "application/geo+json"),
    "alerts.json": ("/alerts", "get", "200", "application/json"),
    "alert-response.json": ("/alerts/{alert_id}/response", "post", "200", "application/json"),
    "admin.overview.json": ("/admin/overview", "get", "200", "application/json"),
    "admin.incidents.json": ("/admin/incidents", "get", "200", "application/json"),
    "admin.incident.json": ("/admin/incidents/{incident_id}", "get", "200", "application/json"),
    "admin.incident-map.geojson": ("/admin/incidents/{incident_id}/map", "get", "200", "application/geo+json"),
    "admin.households.json": ("/admin/households", "get", "200", "application/json"),
    "admin.visit.json": ("/admin/incidents/{incident_id}/targets/{target_id}/visits", "post", "201", "application/json"),
}
