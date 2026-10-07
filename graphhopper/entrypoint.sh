#!/bin/sh
# GraphHopper 시작. 고도 데이터를 고르고, 고도 데이터가 바뀌었으면 그래프 캐시를 지우고 다시 만든다 (B7).
#   /data/dem-hgt/N35E129.hgt.zip 있음 → 국토지리정보원 DEM (build_dem.sh로 만든 것)
#   없음                              → SRTM 90m (config.yml 기본값, 자동 다운로드)
set -e

if [ -f /data/dem-hgt/N35E129.hgt.zip ]; then
  ELE="hgt:$(cksum /data/dem-hgt/*.hgt.zip | cksum | cut -d' ' -f1)"
  OPTS="-Ddw.graphhopper.graph.elevation.provider=hgt -Ddw.graphhopper.graph.elevation.cache_dir=/data/dem-hgt"
  echo "고도 데이터: 국토지리정보원 DEM (/data/dem-hgt)"
else
  ELE="srtm"
  OPTS=""
  echo "고도 데이터: SRTM 90m (/data/srtm)"
fi

# 그래프 캐시는 만들 때의 고도 데이터·설정(프로필·도로 정보)으로 굳는다. 표시가 다르면 지우고 새로 만든다.
# 설정 해시를 함께 넣은 것은 2026-10-07 자동차 프로필 추가 때 — 예전엔 config.yml을 바꿔도 옛 그래프로 떠서 car 프로필이 없었다.
ELE="$ELE cfg:$(cksum config.yml | cut -d' ' -f1)"
MARK=/data/graph-cache/elevation.txt
if [ -d /data/graph-cache ] && [ "$(cat "$MARK" 2>/dev/null)" != "$ELE" ]; then
  echo "고도 데이터 또는 설정이 바뀌어 그래프를 다시 만든다"
  rm -rf /data/graph-cache
fi

java -Xmx1g $OPTS -jar gh.jar server config.yml &
PID=$!
# 그래프가 만들어진 뒤 표시를 남긴다 (health가 OK면 import 완료)
( for i in $(seq 1 120); do
    if curl -fs http://localhost:8989/health >/dev/null 2>&1; then echo "$ELE" > "$MARK"; break; fi
    sleep 2
  done ) &
trap 'kill -TERM $PID' TERM INT
wait $PID
