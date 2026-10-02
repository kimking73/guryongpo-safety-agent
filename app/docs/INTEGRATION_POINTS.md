# Production integration points

The prototype keeps data access at `SafetyRepository` so presentation code does not depend on a public-data provider.

| Capability | Prototype source | Production replacement |
|---|---|---|
| Risk status and layers | `MockSafetyRepository.risk` | Server risk endpoint combining Pohang Digital Twin and KMA data |
| Facilities | `MockSafetyRepository.facilities` | Safety Map provider / municipal facility feed |
| Alerts | `MockSafetyRepository.alerts` | Disaster Safety 24 feed and push/browser notification adapter |
| Safe route | `MockSafetyRepository.route` | Server-side GraphHopper plus flood, landslide, manhole, road closure and DEM weighting |
| AI response | `MockSafetyRepository.ask` | Backend AI endpoint constrained to verified risk and guidance data |

The Dio client inserts the Firebase ID token. Do not call upstream public APIs directly from the app when keys, traffic management, or verified risk calculation are required. Persisting the last verified dashboard, facility list, guidance and local map package belongs behind a future cache repository; the current offline switch is intentionally a visual prototype.

## Authentication boundary

Anonymous Firebase authentication is the default. Google and email credentials should be linked to the existing anonymous Firebase user, preserving the user-profile record. Naver OAuth must complete on a trusted backend or Cloud Function; that service validates the Naver result and issues a Firebase Custom Token. Neither a Naver Client Secret nor Firebase service-account key belongs in this Flutter project.

## Dashboard data mapping

| Dashboard element | Mock source | Future data owner |
|---|---|---|
| Flood, wind and living-safety cards | `MockSafetyRepository.risk` and `ask` | Pohang Digital Twin and KMA data pipeline |
| Rain, flood and wind alerts | `MockSafetyRepository.alerts` | Disaster Safety 24 plus push/browser adapter |
| Shelters and medical markers | `MockSafetyRepository.facilities` | Safety Map or municipality facility feed |
| Route polyline and avoidance segment | `RouteMap` mock coordinates | GraphHopper plus verified hazard, closure, manhole and DEM layers |
