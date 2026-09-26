#!/usr/bin/env bash
# 구룡포 일대 OSM 도로망을 받아 graphhopper/data/guryongpo.osm.pbf로 만든다.
# 처음 한 번, 또는 도로망을 최신으로 바꾸고 싶을 때 실행한다 (코드/ 폴더에서: ./graphhopper/fetch_osm.sh).
# 필요한 것: curl, docker. osmium을 따로 설치하지 않도록 잘라내기는 컨테이너 안에서 한다.
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p data

# 구룡포읍과 주변 (서쪽 경도, 남쪽 위도, 동쪽 경도, 북쪽 위도). 대피 경로가 읍 경계를 조금 넘어도 끊기지 않게 여유를 둔다.
BBOX="129.48,35.92,129.60,36.04"
SRC_URL="https://download.geofabrik.de/asia/south-korea-latest.osm.pbf"

echo "1/3 한국 전체 OSM 다운로드 (약 290MB)"
curl -fL --progress-bar -o data/south-korea-latest.osm.pbf "$SRC_URL"

echo "2/3 구룡포 일대만 잘라내기 (bbox $BBOX)"
docker run --rm -v "$PWD/data:/data" debian:bookworm-slim sh -c \
  "apt-get update -qq >/dev/null && apt-get install -y -qq osmium-tool >/dev/null && \
   osmium extract --overwrite --bbox $BBOX -o /data/guryongpo.osm.pbf /data/south-korea-latest.osm.pbf"

echo "3/3 정리: 전체 파일 삭제, 이전 그래프 캐시 삭제 (graphhopper가 다음 시작 때 새로 만든다)"
rm -f data/south-korea-latest.osm.pbf
rm -rf data/graph-cache

ls -lh data/guryongpo.osm.pbf
echo "완료. 코드/ 폴더에서 docker compose up -d --build"
