"""Google 인코딩 polyline (정밀도 1e5) ↔ [(lat, lon)]. GraphHopper가 points_encoded=true일 때 쓰는 형식."""

from __future__ import annotations


def decode(s: str) -> list[tuple[float, float]]:
    coords: list[tuple[float, float]] = []
    idx = lat = lon = 0
    while idx < len(s):
        for which in range(2):
            shift = result = 0
            while True:
                b = ord(s[idx]) - 63
                idx += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            delta = ~(result >> 1) if result & 1 else result >> 1
            if which == 0:
                lat += delta
            else:
                lon += delta
        coords.append((lat / 1e5, lon / 1e5))
    return coords


def encode(coords: list[tuple[float, float]]) -> str:
    out: list[str] = []
    prev_lat = prev_lon = 0
    for lat, lon in coords:
        ilat, ilon = round(lat * 1e5), round(lon * 1e5)
        for delta in (ilat - prev_lat, ilon - prev_lon):
            v = ~(delta << 1) if delta < 0 else delta << 1
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1F)) + 63))
                v >>= 5
            out.append(chr(v + 63))
        prev_lat, prev_lon = ilat, ilon
    return "".join(out)
