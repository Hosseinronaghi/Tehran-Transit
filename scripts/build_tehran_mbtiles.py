#!/usr/bin/env python3
"""Generate a legally distributable raster Tehran MBTiles basemap from OSM PBF.

This reads raw ODbL OpenStreetMap data (e.g. Geofabrik's Iran extract); it does
NOT download/prefetch any public OSM tile servers. It renders the street map
with Pillow and the bundled Vazir font. The style is deliberately lightweight.
"""
from __future__ import annotations

import argparse
import collections
import io
import math
from pathlib import Path
import sqlite3
import sys
import time

from PIL import Image, ImageDraw, ImageFont
import osmium

BBOX = (50.86, 35.43, 51.78, 35.95)  # west, south, east, north (Tehran)
MIN_ZOOM = 9
MAX_ZOOM = 15
BACKGROUND = "#f1f3ef"
COLORS = {
    "park": "#cbe8c3",
    "water": "#a8d9ee",
    "building": "#e4e6e4",
    "rail": "#9b8b9c",
    "motorway": "#f0b07d",
    "trunk": "#f3c493",
    "primary": "#ffe0a0",
    "secondary": "#ffe9b4",
    "tertiary": "#fff7d8",
    "minor": "#fdfdfd",
    "outline": "#d7d8d4",
    "text": "#45545d",
}
ROAD_MAJOR = {"motorway", "motorway_link", "trunk", "trunk_link", "primary",
              "primary_link", "secondary", "secondary_link", "tertiary"}
ROAD_MINOR = {"residential", "living_street", "service", "unclassified",
              "pedestrian", "footway", "path", "track", "cycleway", "steps"}
PARK_VALUES = {"park", "garden", "grass", "forest", "wood", "recreation_ground",
               "cemetery", "pitch", "meadow"}
ZMIN = {
    "park": 10, "water": 10, "building": 15, "rail": 13,
    "motorway": 9, "trunk": 9, "primary": 10, "secondary": 11,
    "tertiary": 12, "minor": 13,
}
ORDER = {
    "park": 0, "water": 1, "building": 2, "minor": 3,
    "tertiary": 4, "secondary": 5, "primary": 6,
    "trunk": 7, "motorway": 8, "rail": 9,
}


def in_city(lon: float, lat: float) -> bool:
    w, s, e, n = BBOX
    return w <= lon <= e and s <= lat <= n


def project(lon: float, lat: float, z: int) -> tuple[float, float]:
    scale = 256 * (1 << z)
    lat = max(-85.05112878, min(85.05112878, lat))
    sinlat = math.sin(math.radians(lat))
    return ((lon + 180.0) / 360.0 * scale,
            (0.5 - math.log((1 + sinlat) / (1 - sinlat)) / (4 * math.pi))
            * scale)


def tile_range(z: int) -> tuple[range, range]:
    w, s, e, n = BBOX
    left, top = project(w, n, z)
    right, bottom = project(e, s, z)
    return (range(int(left // 256), int(right // 256) + 1),
            range(int(top // 256), int(bottom // 256) + 1))


class RoadFeature:
    __slots__ = ("kind", "name", "coords", "bounds")
    def __init__(self, kind: str, name: str, coords: tuple[tuple[float, float], ...]):
        self.kind = kind
        self.name = name
        self.coords = coords
        self.bounds = (
            min(pt[0] for pt in coords), min(pt[1] for pt in coords),
            max(pt[0] for pt in coords), max(pt[1] for pt in coords)
        )


class Collector(osmium.SimpleHandler):
    def __init__(self) -> None:
        super().__init__()
        self.features: list[RoadFeature] = []
        self.places: list[tuple[float, float, str, str]] = []
        self.count = collections.Counter()

    def node(self, node) -> None:
        place = node.tags.get("place")
        if place not in ("city", "town", "suburb", "neighbourhood",
                         "village", "hamlet"):
            return
        name = node.tags.get("name:fa") or node.tags.get("name")
        if not name:
            return
        try:
            lon, lat = node.location.lon, node.location.lat
        except osmium.InvalidLocationError:
            return
        if in_city(lon, lat):
            self.places.append((lon, lat, name, place))

    def way(self, way) -> None:
        tags = way.tags
        highway = tags.get("highway")
        waterway = tags.get("waterway")
        natural = tags.get("natural")
        landuse = tags.get("landuse")
        leisure = tags.get("leisure")
        kind = None
        if highway:
            if highway in ROAD_MAJOR:
                kind = highway.removesuffix("_link")
                if kind not in ZMIN:
                    kind = "minor"
            elif highway in ROAD_MINOR:
                kind = "minor"
        elif natural in ("water", "bay") or landuse in ("reservoir", "basin"):
            kind = "water"
        elif waterway in ("stream", "river", "canal"):
            kind = "water"
        elif leisure in PARK_VALUES or landuse in PARK_VALUES or natural in ("wood",):
            kind = "park"
        elif tags.get("building") and tags.get("building") != "no":
            kind = "building"
        elif tags.get("railway") in ("rail", "subway", "tram", "light_rail"):
            kind = "rail"
        if kind is None:
            return
        try:
            coords = tuple((node.location.lon, node.location.lat)
                           for node in way.nodes if node.location.valid())
        except osmium.InvalidLocationError:
            return
        if len(coords) < 2:
            return
        w, s, e, n = BBOX
        mnlon = min(pt[0] for pt in coords)
        mxlon = max(pt[0] for pt in coords)
        mnlat = min(pt[1] for pt in coords)
        mxlat = max(pt[1] for pt in coords)
        if mxlon < w or mnlon > e or mxlat < s or mnlat > n:
            return
        if kind == "building" and (len(coords) < 4 or coords[0] != coords[-1]):
            return
        name = tags.get("name:fa") or tags.get("name") or ""
        self.features.append(RoadFeature(kind, name, coords))
        self.count[kind] += 1


def map_width(z: int, kind: str) -> int:
    size = {"motorway": 10, "trunk": 8, "primary": 7,
            "secondary": 6, "tertiary": 5, "minor": 3, "rail": 2}
    base = size.get(kind, 2)
    if z <= 11:
        return max(1, int(base * 0.35))
    if z == 12:
        return max(1, int(base * 0.5))
    if z == 13:
        return max(1, int(base * 0.7))
    if z == 14:
        return max(1, int(base * 0.85))
    return base


def _font(z: int, path: Path) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(path), 10 if z == 13 else
                              12 if z == 14 else 13)


def render_tile(features: list[RoadFeature], place_labels, z: int, x: int,
                y: int, font: ImageFont.FreeTypeFont) -> bytes:
    im = Image.new("RGB", (256, 256), BACKGROUND)
    dr = ImageDraw.Draw(im)
    origin_x = x * 256
    origin_y = y * 256
    labels = []
    for f in features:
        k = f.kind
        if z < ZMIN[k]:
            continue
        points = [(round(px - origin_x), round(py - origin_y))
                  for px, py in (project(lon, lat, z) for lon, lat in f.coords)]
        if k in ("park", "water", "building") and f.coords[0] == f.coords[-1]:
            dr.polygon(points, fill=COLORS[k])
        elif k in ("park", "water", "building"):
            if k == "water":
                dr.line(points, fill=COLORS[k], width=map_width(z, k))
        elif k == "rail":
            dr.line(points, fill=COLORS[k], width=map_width(z, k))
        else:
            width = map_width(z, k)
            dr.line(points, fill=COLORS["outline"],
                    width=max(width + 2, 2), joint="curve")
            dr.line(points, fill=COLORS[k], width=width, joint="curve")
            if f.name and z >= 13 and k != "minor":
                mid = points[len(points) // 2]
                if 22 < mid[0] < 234 and 20 < mid[1] < 236:
                    labels.append((mid[0], mid[1], f.name))
            elif f.name and z == 15 and k == "minor":
                mid = points[len(points) // 2]
                if 22 < mid[0] < 234 and 20 < mid[1] < 236:
                    labels.append((mid[0], mid[1], f.name))
    used = set()
    for lx, ly, name in labels[:40]:
        loc = (int(lx / 70), int(ly / 40))
        if loc in used:
            continue
        used.add(loc)
        if len(name) > 28:
            continue
        try:
            dr.text((lx, ly), name, font=font, fill=COLORS["text"],
                    stroke_width=2, stroke_fill=BACKGROUND,
                    anchor="mm", direction="rtl")
        except ValueError:
            dr.text((lx, ly), name, font=font, fill=COLORS["text"],
                    stroke_width=2, stroke_fill=BACKGROUND, anchor="mm")
    for lon, lat, name, kind in place_labels:
        gx, gy = project(lon, lat, z)
        px, py = gx - origin_x, gy - origin_y
        if not (15 < px < 241 and 16 < py < 240):
            continue
        if kind in ("neighbourhood", "hamlet") and z < 14:
            continue
        if kind in ("village", "suburb") and z < 12:
            continue
        try:
            dr.text((px, py), name, font=font, fill="#145070",
                    stroke_width=2, stroke_fill=BACKGROUND,
                    anchor="mm", direction="rtl")
        except ValueError:
            dr.text((px, py), name, font=font, fill="#145070",
                    stroke_width=2, stroke_fill=BACKGROUND, anchor="mm")
    buffer = io.BytesIO()
    im.save(buffer, format="WEBP", quality=79, method=3)
    return buffer.getvalue()


def write_tiles(collector: Collector, output: Path, minzoom: int,
                maxzoom: int, font_file: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()
    with sqlite3.connect(output) as db:
        db.execute("CREATE TABLE metadata (name TEXT, value TEXT)")
        db.execute(
            "CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER,"
            " tile_row INTEGER, tile_data BLOB)"
        )
        db.execute("CREATE UNIQUE INDEX idx_tile ON tiles "
                   "(zoom_level, tile_column, tile_row)")
        metadata = {
            "name": "Raha Tehran OSM streets",
            "type": "baselayer", "version": "1.0", "format": "webp",
            "description": "Lightweight Tehran raster map drawn from OSM raw data",
            "attribution": "© OpenStreetMap contributors (ODbL 1.0)",
            "bounds": ",".join(str(v) for v in BBOX),
            "center": "51.389,35.689,12",
            "minzoom": str(minzoom), "maxzoom": str(maxzoom),
        }
        db.executemany("INSERT INTO metadata VALUES (?,?)", metadata.items())
        collector.features.sort(key=lambda feature: ORDER[feature.kind])
        for z in range(minzoom, maxzoom + 1):
            started = time.monotonic()
            x_range, y_range = tile_range(z)
            x_lo, x_hi = x_range.start, x_range.stop - 1
            y_lo, y_hi = y_range.start, y_range.stop - 1
            # Spatial index: each relevant feature is associated only with
            # the actual tiles it touches, never full-map O(n*m) scanning.
            indexed = collections.defaultdict(list)
            for feature in collector.features:
                if z < ZMIN[feature.kind]:
                    continue
                west, south, east, north = feature.bounds
                left, top = project(west, north, z)
                right, bottom = project(east, south, z)
                for tx in range(max(x_lo, int(left // 256)),
                                min(x_hi, int(right // 256)) + 1):
                    for ty in range(max(y_lo, int(top // 256)),
                                    min(y_hi, int(bottom // 256)) + 1):
                        indexed[(tx, ty)].append(feature)
            label_index = collections.defaultdict(list)
            for lon, lat, name, kind in collector.places:
                px, py = project(lon, lat, z)
                label_index[(int(px // 256), int(py // 256))].append(
                    (lon, lat, name, kind))
            font = _font(z, font_file)
            total = 0
            for x in x_range:
                for y in y_range:
                    blob = render_tile(indexed.get((x, y), []),
                                       label_index.get((x, y), []),
                                       z, x, y, font)
                    db.execute("INSERT INTO tiles VALUES (?,?,?,?)",
                               (z, x, (1 << z) - 1 - y, blob))
                    total += 1
                db.commit()
            print(f"z{z}: {total:,} tiles, {time.monotonic()-started:.1f}s",
                  flush=True)
        status = db.execute("PRAGMA integrity_check").fetchone()[0]
        if status != "ok":
            raise RuntimeError(f"Invalid MBTiles database: {status}")
        rows = db.execute("SELECT COUNT(*) FROM tiles").fetchone()[0]
        print(f"MBTiles ready: {rows:,} tiles, "
              f"{output.stat().st_size / 1048576:.1f} MiB", flush=True)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("pbf", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--minzoom", type=int, default=MIN_ZOOM)
    p.add_argument("--maxzoom", type=int, default=MAX_ZOOM)
    p.add_argument("--font", type=Path,
                   default=Path("assets/fonts/Vazir-Regular.ttf"))
    args = p.parse_args()
    if args.minzoom < 0 or args.maxzoom > 16 or args.maxzoom < args.minzoom:
        p.error("Invalid zoom range (0..16)")
    if not args.font.is_file():
        p.error("Missing Vazir font: " + str(args.font))
    handler = Collector()
    print("Loading ways and city labels from ODbL OSM PBF...", flush=True)
    started = time.monotonic()
    handler.apply_file(str(args.pbf), locations=True)
    print(f"Loaded {len(handler.features):,} ways, "
          f"{len(handler.places):,} place labels in "
          f"{time.monotonic()-started:.1f}s: {handler.count}", flush=True)
    if handler.count["primary"] + handler.count["secondary"] + \
            handler.count["minor"] < 2500:
        raise SystemExit("Incomplete Tehran street data, refusing to publish")
    write_tiles(handler, args.output, args.minzoom, args.maxzoom, args.font)


if __name__ == "__main__":
    main()
