#!/usr/bin/env bash
# 국토지리정보원 수치표고모델(DEM)을 GraphHopper가 읽는 고도 타일(HGT, 1초 ≈ 30m 간격)로 바꾼다 (B7).
#
# 1. 국토정보플랫폼(map.ngii.go.kr)에서 구룡포 일대 DEM 파일(.img 등)을 받아 graphhopper/dem/ngii/에 넣는다.
# 2. 코드/ 폴더에서 ./graphhopper/build_dem.sh
# 3. docker compose restart graphhopper  (entrypoint.sh가 dem-hgt를 보고 국토지리정보원 DEM으로 그래프를 다시 만든다)
#
# 결과: graphhopper/data/dem-hgt/N35E129.hgt.zip, N36E129.hgt.zip
# DEM이 없는 곳(바다, 받지 않은 도엽)은 SRTM(graphhopper/data/srtm, 90m)으로 채운다. SRTM은 처음 graphhopper를
# 띄울 때 자동으로 받아지므로, 이 스크립트 전에 한 번은 SRTM 설정으로 graphhopper를 띄운 적이 있어야 한다.
# 필요한 것: docker. GDAL은 컨테이너 안에서 실행한다.
set -euo pipefail

cd "$(dirname "$0")"
# 파일 안에 좌표계 정보가 없을 때만 지정한다. 예: SRC_SRS=EPSG:5186 ./graphhopper/build_dem.sh
SRC_SRS="${SRC_SRS:-}"

docker run --rm -i -v "$PWD:/w" -w /w -e SRC_SRS="$SRC_SRS" ghcr.io/osgeo/gdal:ubuntu-small-3.11.4 python3 - <<'PY'
import glob, os, sys, zipfile
import numpy as np
from osgeo import gdal

gdal.UseExceptions()
SRC = sorted(f for ext in ("img", "tif", "tiff", "asc", "IMG", "TIF", "TIFF", "ASC")
             for f in glob.glob(f"dem/ngii/**/*.{ext}", recursive=True))
if not SRC:
    sys.exit("dem/ngii/ 에 DEM 파일(.img, .tif, .asc)이 없습니다. 국토정보플랫폼에서 받아 넣어 주세요.")
print(f"국토지리정보원 DEM 파일 {len(SRC)}개")

src_srs = os.environ.get("SRC_SRS") or None
vrt = gdal.BuildVRT("/tmp/ngii.vrt", SRC, outputSRS=src_srs)
srs = vrt.GetProjection()
if not srs:
    sys.exit("DEM 파일에 좌표계 정보가 없습니다. SRC_SRS=EPSG:5186 처럼 지정해서 다시 실행하세요.")
print("좌표계:", vrt.GetSpatialRef().GetName(), f"/ 격자 {abs(vrt.GetGeoTransform()[1]):.1f}m")
vrt = None

N = 3601                  # HGT 1초 타일: 1도를 3600칸, 양 끝 포함 3601점
H = 0.5 / 3600            # 점이 칸 가운데가 아니라 격자선 위에 오도록 반 칸 넓힌다
os.makedirs("data/dem-hgt", exist_ok=True)
GRAPH_BBOX = (129.48, 35.92, 129.60, 36.04)   # fetch_osm.sh와 같은 범위

for lat, lon in [(35, 129), (36, 129)]:
    name = f"N{lat:02d}E{lon:03d}"
    te = (lon - H, lat - H, lon + 1 + H, lat + 1 + H)
    tif = f"/tmp/{name}.tif"
    # 1) 바탕: SRTM 90m를 30m 격자로 (없으면 0 = 해수면)
    srtm = f"data/srtm/{name}.hgt.zip"
    if os.path.exists(srtm):
        gdal.Warp(tif, f"/vsizip/{srtm}/{name}.hgt", outputBounds=te, width=N, height=N,
                  dstSRS="EPSG:4326", resampleAlg="bilinear", outputType=gdal.GDT_Int16, dstNodata=-32768)
    else:
        print(f"  {name}: SRTM 바탕이 없어 빈 곳은 0m로 둔다")
        ds = gdal.GetDriverByName("GTiff").Create(tif, N, N, 1, gdal.GDT_Int16)
        ds.SetGeoTransform((te[0], 1 / 3600, 0, te[3], 0, -1 / 3600)); ds.SetProjection("EPSG:4326")
        ds.GetRasterBand(1).Fill(0); ds = None
    # 2) 위에 국토지리정보원 DEM을 덮는다. 5m → 30m는 평균으로 줄인다 (값이 있는 곳만 덮어쓴다)
    dst = gdal.Open(tif, gdal.GA_Update)       # 파일 이름을 넘기면 새로 만들어 버리므로 열린 데이터셋에 덮는다
    gdal.Warp(dst, "/tmp/ngii.vrt", resampleAlg="average")
    # 남은 빈 곳(SRTM도 비어 있는 바다 등)은 0m. 빈 값(-32768)이 남으면 경사 계산이 튄다
    band = dst.GetRasterBand(1)
    arr = band.ReadAsArray()
    arr[arr == -32768] = 0
    band.WriteArray(arr)
    dst = None
    # 3) HGT로 저장하고 zip (GraphHopper hgt provider는 N35E129.hgt.zip 안의 첫 파일을 읽는다)
    hgt = f"/tmp/{name}.hgt"
    gdal.Translate(hgt, tif, format="SRTMHGT")
    with zipfile.ZipFile(f"data/dem-hgt/{name}.hgt.zip", "w", zipfile.ZIP_DEFLATED) as z:
        z.write(hgt, f"{name}.hgt")
    print(f"  {name}.hgt.zip 생성")

# 도로망 범위의 육지(SRTM 기준 0m 초과) 중 국토지리정보원 DEM이 덮는 비율. 바다는 DEM에 없어도 되므로 뺀다
def grid(src, alg):
    return gdal.Warp("", src, format="MEM", outputBounds=GRAPH_BBOX, xRes=1 / 3600, yRes=1 / 3600,
                     dstSRS="EPSG:4326", resampleAlg=alg, dstNodata=-32768).ReadAsArray()
ngii = grid("/tmp/ngii.vrt", "average")
srtm = [f"/vsizip/{p}/{os.path.basename(p)[:-4]}" for p in sorted(glob.glob("data/srtm/*.hgt.zip"))]
base = grid(gdal.BuildVRT("/tmp/srtm.vrt", srtm), "bilinear") if srtm else None
land = (base > 0) if base is not None else np.ones_like(ngii, dtype=bool)
pct = 100 * np.count_nonzero((ngii != -32768) & land) / max(np.count_nonzero(land), 1)
print(f"도로망 범위(구룡포 일대) 육지 중 국토지리정보원 DEM이 덮는 비율: {pct:.0f}%")
if pct < 90:
    print("  → 90% 미만입니다. 빈 곳은 SRTM으로 채웠습니다. 구룡포읍 전체 도엽을 받았는지 확인하세요.")
print("완료. 다음: docker compose restart graphhopper (DEM이 바뀐 것을 알아채고 그래프를 다시 만든다)")
PY
