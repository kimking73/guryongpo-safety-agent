# GraphHopper 경로 엔진. 공식 jar를 Maven Central에서 받아 실행한다 (arm64·amd64 공통).
FROM eclipse-temurin:21-jre

ARG GH_VERSION=11.0
WORKDIR /gh
ADD https://repo1.maven.org/maven2/com/graphhopper/graphhopper-web/${GH_VERSION}/graphhopper-web-${GH_VERSION}.jar gh.jar
COPY config.yml entrypoint.sh ./

# 도로망(guryongpo.osm.pbf), 고도(srtm/, dem-hgt/), 그래프 캐시는 볼륨 /data에 둔다. 캐시가 없으면 시작할 때 만든다 (구룡포 일대 수 초).
EXPOSE 8989
# 고도 데이터 선택(국토지리정보원 DEM / SRTM)과 캐시 관리는 entrypoint.sh
CMD ["./entrypoint.sh"]
