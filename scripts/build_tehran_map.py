#!/usr/bin/env python3
"""Build a LEGALLY SOURCED, optional Tehran raster MBTiles map from raw OSM data.

Source: Geofabrik Iran OSM PBF (ODbL), never tile.openstreetmap.org.
This is a lightweight map focused on roads, parks, water, buildings and names.
It is not guaranteed to contain every POI or exact address.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from datetime import date
from io import BytesIO
import math
import os
from pathlib import Path
import sqlite3
import urllib.request

import osmium
from PIL import Image, ImageDraw, ImageFont

# City and outskirts; broader than BBBike's 51.27..51.55 central-city extract.
WEST, SOUTH, EAST, NORTH = 50.90, 35.39, 51.85, 36.02
MIN_ZOOM, MAX_ZOOM = 10, 15
SIZE = 256
SOURCE_URLS = (
    "https://download.geofabrik.de/asia/iran-latest.osm.pbf",
    "https://download-ext2.geofabrik.de/asia/iran-latest.osm.pbf",
)
MAJOR = {"motorway", "trunk", "primary", "secondary"}
MEDIUM = {"tertiary", "residential", "unclassified", "living_street"}
SMALL = {"service", "pedestrian", "footway", "path", "steps", "cycleway"}
ROAD_TYPES = MAJOR | MEDIUM | SMALL
PARK_TYPES = {"park", "garden", "forest", "recreation_ground", "nature_reserve"}
WATER_TYPES = {"water", "reservoir", "riverbank"}
PREFILL = (245, 248, 248)
COLORS = {
    "motorway": (245, 177, 92),
    "trunk": (250, 194, 121),
    "primary": (252, 214, 150),
    "secondary": (253, 229, 187),
    "tertiary": (255, 255, 251),
    "residential": (255, 255, 255),
    "unclassified": (253, 253, 253),
    "living_street": (251, 251, 251),
    "service": (241, 241, 241),
    "pedestrian": (245, 243, 234),
    "footway": (228, 229, 225),
    "path": (228, 229, 225),
    "steps": (228, 229, 225),
    "cycleway": (220, 231, 227),
}
FONT = Path("assets/fonts/Vazir-Regular.ttf")


def tile_xy(lon: float, lat: float, zoom: int) -> tuple[float, float]:
    lat = max(min(lat, 85.0), -85.0)
    scale = 2**zoom
    x = (lon + 180.0) / 360.0 * scale
    r = math.radians(lat)
    y = (1.0 - math.asinh(math.tan(r)) / math.pi) / 2.0 * scale
    return x, y


class Extract(osmium.SimpleHandler):
    def __init__(self) -> None:
        super().__init__()
        self.features = []
        self.places = []
        self.road_count = 0

    def way(self, way) -> None:
        t = way.tags
        highway = t.get("highway")
        natural = t.get("natural")
        leisure = t.get("leisure")
        landuse = t.get("landuse")
        waterway = t.get("waterway")
        building = t.get("building")
        if highway not in ROAD_TYPES and not (
            leisure in PARK_TYPES or landuse in PARK_TYPES or
            natural in WATER_TYPES or landuse in WATER_TYPES or
            waterway in {"stream", "river", "canal"} or building
        ):
            return
        pts = []
        for node in way.nodes:
            if node.location.valid():
                lat, lon = node.lat, node.lon
                if (WEST - .04) <= lon <= (EAST + .04) and (
                    SOUTH - .04) <= lat <= (NORTH + .04):
                    pts.append((lon, lat))
                else:
                    # Keep boundary transitions, if road enters city in next node.
                    pts.append((lon, lat))
        if len(pts) < 2:
            return
        bb = (min(p[0] for p in pts), min(p[1] for p in pts),
              max(p[0] for p in pts), max(p[1] for p in pts))
        if bb[2] < WEST or bb[0] > EAST or bb[3] < SOUTH or bb[1] > NORTH:
            return
        if highway in ROAD_TYPES:
            kind, subtype = "road", highway
            self.road_count += 1
        elif natural in WATER_TYPES or landuse in WATER_TYPES:
            kind, subtype = "area", "water"
        elif leisure in PARK_TYPES or landuse in PARK_TYPES:
            kind, subtype = "area", "park"
        elif waterway in {"stream", "river", "canal"}:
            kind, subtype = "waterway", waterway
        else:
            kind, subtype = "area", "building"
            if len(pts) < 4 or pts[0] != pts[-1]:
                return
        self.features.append((kind, subtype, pts, t.get("name:fa") or t.get("name") or "", bb))

    def node(self, n) -> None:
        t = n.tags
        place = t.get("place")
        if place not in ("city", "town", "suburb", "neighbourhood", "quarter"):
            return
        if not n.location.valid():
            return
        if not (WEST <= n.lon <= EAST and SOUTH <= n.lat <= NORTH):
            return
        name = t.get("name:fa") or t.get("name")
        if name:
            self.places.append((name, n.lon, n.lat, place))


def download_pbf(path: Path) -> None:
    if path.exists() and path.stat().st_size > 50_000_000:
        print("Using existing verified-size OSM PBF", flush=True)
        return
    error = None
    for url in SOURCE_URLS:
        try:
            print("Downloading raw OSM data:", url, flush=True)
            req = urllib.request.Request(url, headers={
                "User-Agent": "RahaTehranOfflineMapBuilder/0.1 (github.com/Hosseinronaghi/Tehran-Transit)"
            })
            with urllib.request.urlopen(req, timeout=120) as response, path.open("wb") as out:
                while True:
                    block = response.read(1024 * 1024)
                    if not block:
                        break
                    out.write(block)
            if path.stat().st_size < 50_000_000:
                raise RuntimeError("Unexpectedly small Iran PBF")
            return
        except Exception as e:
            error = e
            print("Source failed:", e, flush=True)
            if path.exists():
                path.unlink()
    raise RuntimeError(f"Unable to download OSM PBF: {error}")


def get_font(size: int):
    if FONT.is_file():
        return ImageFont.truetype(str(FONT), size=size)
    return ImageFont.load_default()


def draw_label(draw, x, y, text, font, fill):
    if not text or len(text) > 42:
        return
    try:
        bbox = draw.textbbox((0, 0), text, font=font, direction="rtl")
        width = bbox[2] - bbox[0]
        if x - width / 2 < 5 or x + width / 2 > SIZE - 5:
            return
        draw.text((x, y), text, font=font, fill=fill, anchor="mm",
                  stroke_width=2, stroke_fill=PREFILL, direction="rtl")
    except (ValueError, KeyError):
        # Pillow builds without libraqm can still draw without bidi shaping.
        draw.text((x, y), text, font=font, fill=fill)


def render(extract: Extract, out: Path) -> None:
    db = sqlite3.connect(out)
    db.execute("PRAGMA journal_mode = OFF")
    db.execute("PRAGMA synchronous = OFF")
    db.execute("CREATE TABLE metadata (name TEXT, value TEXT)")
    db.execute("CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)")
    db.execute("CREATE UNIQUE INDEX tile_index on tiles (zoom_level, tile_column, tile_row)")
    edition = date.today()
    metadata = {
        "name": "Raha Tehran offline OSM streets",
        "type": "baselayer",
        "version": f"{edition.year}-{edition.month:02d}-{edition.day:02d}",
        "description": "Self-rendered from Geofabrik Iran raw OSM PBF. Roads, parks, water, buildings.",
        "format": "jpg",
        "bounds": f"{WEST},{SOUTH},{EAST},{NORTH}",
        "center": "51.389,35.689,12",
        "minzoom": str(MIN_ZOOM),
        "maxzoom": str(MAX_ZOOM),
        "attribution": "© OpenStreetMap contributors (ODbL 1.0), source Geofabrik",
    }
    db.executemany("INSERT INTO metadata VALUES (?,?)", list(metadata.items()))
    road_priority = {
        "footway": 0, "path": 0, "steps": 0, "cycleway": 0,
        "service": 1, "pedestrian": 1, "living_street": 2,
        "residential": 3, "unclassified": 3,
        "tertiary": 4, "secondary": 5, "primary": 6,
        "trunk": 7, "motorway": 8,
    }
    labels_font = {z: get_font(max(11, z + 1)) for z in range(MIN_ZOOM, MAX_ZOOM + 1)}
    tile_count = 0
    try:
        for z in range(MIN_ZOOM, MAX_ZOOM + 1):
            xleft, ybottom = tile_xy(WEST, SOUTH, z)
            xright, ytop = tile_xy(EAST, NORTH, z)
            start_x, end_x = int(xleft), int(xright)
            start_y, end_y = int(ytop), int(ybottom)
            bucket = defaultdict(list)
            # Direct spatial bucketing avoids O(tiles * all streets) rendering.
            for kind, subtype, pts, name, bb in extract.features:
                if kind == "area" and subtype == "building" and z < 15:
                    continue
                if kind == "road" and (
                    (subtype in SMALL and z < 15) or
                    (subtype in MEDIUM and z < 13) or
                    (subtype == "tertiary" and z < 12)
                ):
                    continue
                a, d = tile_xy(bb[0], bb[1], z)
                b, c = tile_xy(bb[2], bb[3], z)
                lo_x = max(start_x, int(min(a, b)))
                hi_x = min(end_x, int(max(a, b)))
                lo_y = max(start_y, int(min(c, d)))
                hi_y = min(end_y, int(max(c, d)))
                if lo_x > hi_x or lo_y > hi_y:
                    continue
                coords = [tile_xy(lon, lat, z) for lon, lat in pts]
                record = (kind, subtype, coords, name)
                for x in range(lo_x, hi_x + 1):
                    for y in range(lo_y, hi_y + 1):
                        bucket[(x, y)].append(record)
            place_bucket = defaultdict(list)
            if z >= 11:
                for name, lon, lat, kind in extract.places:
                    x, y = tile_xy(lon, lat, z)
                    coord = (int(x), int(y))
                    if start_x <= coord[0] <= end_x and start_y <= coord[1] <= end_y:
                        place_bucket[coord].append((name, x, y, kind))
            print(f"Rendering zoom {z} ({(end_x-start_x+1)*(end_y-start_y+1)} tiles)", flush=True)
            for x in range(start_x, end_x + 1):
                for y in range(start_y, end_y + 1):
                    im = Image.new("RGB", (SIZE, SIZE), PREFILL)
                    d = ImageDraw.Draw(im)
                    features = bucket.get((x, y), [])
                    polys = [f for f in features if f[0] == "area"]
                    for kind, subtype, points, name in polys:
                        coords = [((px-x)*SIZE, (py-y)*SIZE) for px, py in points]
                        if subtype == "water":
                            color = (181, 215, 229)
                        elif subtype == "park":
                            color = (214, 236, 213)
                        else:
                            color = (229, 233, 233)
                        if len(coords) >= 3:
                            d.polygon(coords, fill=color)
                    for kind, subtype, points, name in features:
                        if kind == "waterway":
                            coords = [((px-x)*SIZE, (py-y)*SIZE) for px, py in points]
                            d.line(coords, fill=(166, 210, 229), width=2 if z < 14 else 3)
                    roads = [f for f in features if f[0] == "road"]
                    roads.sort(key=lambda f: road_priority.get(f[1], 0))
                    for kind, subtype, points, name in roads:
                        coords = [((px-x)*SIZE, (py-y)*SIZE) for px, py in points]
                        width = (2 if z <= 12 else 3 if z <= 13 else 4)
                        if subtype in MAJOR:
                            width += 2
                        if subtype == "motorway":
                            width += 1
                        if subtype in SMALL:
                            width = 1 if z < 15 else 2
                        d.line(coords, fill=(209, 214, 216), width=width + 2, joint="curve")
                        d.line(coords, fill=COLORS.get(subtype, (255,255,255)),
                               width=width, joint="curve")
                    if z >= 14:
                        seen = set()
                        for kind, subtype, points, name in roads:
                            if not name or name in seen or subtype in SMALL:
                                continue
                            p = points[len(points)//2]
                            px, py = (p[0]-x)*SIZE, (p[1]-y)*SIZE
                            if 30 <= px <= SIZE-30 and 25 <= py <= SIZE-25:
                                draw_label(d, px, py, name, labels_font[z], (68, 77, 86))
                                seen.add(name)
                    for name, lon, lat, kind in place_bucket.get((x, y), []):
                        if kind in ("city", "town") or z >= 12:
                            draw_label(d, (lon-x)*SIZE, (lat-y)*SIZE,
                                       name, labels_font[z], (30, 75, 91))
                    buff = BytesIO()
                    im.save(buff, "JPEG", quality=78, optimize=True, subsampling=2)
                    db.execute("INSERT INTO tiles VALUES (?,?,?,?)",
                               (z, x, (2**z - 1 - y), sqlite3.Binary(buff.getvalue())))
                    tile_count += 1
                db.commit()
            print(f"zoom {z} complete; {tile_count} cumulative tiles", flush=True)
    finally:
        db.commit()
        db.close()
    if tile_count < 700:
        raise RuntimeError("Too few city map tiles; source or bounds invalid")
    print(f"Created {out} with {tile_count} tiles, {out.stat().st_size / 1048576:.1f} MiB", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=Path("/tmp/iran-latest.osm.pbf"))
    parser.add_argument("--output", type=Path, default=Path("tehran.mbtiles"))
    args = parser.parse_args()
    download_pbf(args.input)
    parsed = Extract()
    parsed.apply_file(str(args.input), locations=True)
    print("OSM Tehran features:", len(parsed.features),
          "roads:", parsed.road_count, "places:", len(parsed.places), flush=True)
    if parsed.road_count < 12000:
        raise RuntimeError("Insufficient Tehran roads to publish a map")
    if args.output.exists():
        args.output.unlink()
    render(parsed, args.output)


if __name__ == "__main__":
    main()
