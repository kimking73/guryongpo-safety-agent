-- DB 컨테이너를 처음 만들 때(볼륨이 비어 있을 때) 한 번만 실행된다.
-- 이미 만든 볼륨에는 적용되지 않으므로, 바꾼 뒤에는 `docker compose down -v`로 초기화한다.
CREATE EXTENSION IF NOT EXISTS postgis;
