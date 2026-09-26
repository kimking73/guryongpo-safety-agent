# 국토지리정보원 DEM 원본

`ngii/`에 국토정보플랫폼(map.ngii.go.kr)에서 받은 수치표고모델 파일을 넣고 `../build_dem.sh`를 실행한다.
원본은 용량이 커서 커밋하지 않는다 (`.gitignore`). 변환 결과는 `../data/dem-hgt/`.

현재(2026-09-26): 국토지리정보원 **공개DEM 90m** 도엽 35903(`35903.img`, EPSG:5179, 2025). 5m를 구하면 교체한다
(`ai/.claude/docs/timeline.md` 이월 항목).
