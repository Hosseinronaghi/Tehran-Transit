#!/usr/bin/env python3
"""Validate the generated bus SQLite and bundled metro/BRT schematic GeoJSON.

Prevent packaging empty or obviously broken transport maps.
"""
import json
import pathlib
import sqlite3
import sys
from collections import Counter

database_path = pathlib.Path(sys.argv[1])
assert database_path.is_file() and database_path.stat().st_size > 10000, database_path

with sqlite3.connect(database_path) as db:
    counts = {
        table: db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        for table in ("stations", "routes", "route_variants", "route_stops")
    }
    assert counts["stations"] >= 4000, counts
    assert counts["routes"] >= 200, counts
    assert counts["route_stops"] >= 9000, counts
    assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    missing_stops = db.execute(
        "SELECT COUNT(*) FROM route_stops rs "
        "LEFT JOIN stations s ON rs.station_id = s.id WHERE s.id IS NULL"
    ).fetchone()[0]
    assert missing_stops == 0, missing_stops
    print("Validated offline bus SQLite:", counts)

if len(sys.argv) > 2:
    geo_path = pathlib.Path(sys.argv[2])
    geo = json.loads(geo_path.read_text(encoding="utf-8"))
    assert geo["type"] == "FeatureCollection"
    features = geo.get("features", [])
    counts = Counter(
        (f.get("properties", {}).get("mode"), f.get("properties", {}).get("kind"))
        for f in features
    )
    assert counts[("metro", "station")] >= 120, counts
    assert counts[("brt", "station")] >= 300, counts
    assert counts[("metro", "route")] >= 100, counts
    assert counts[("brt", "route")] >= 1000, counts
    for i, f in enumerate(features):
        geom = f["geometry"]
        coords = geom["coordinates"]
        points = [coords] if geom["type"] == "Point" else coords
        assert geom["type"] in ("Point", "LineString"), (i, geom["type"])
        assert len(points) >= (1 if geom["type"] == "Point" else 2), i
        for lon, lat in points:
            assert 49.0 <= float(lon) <= 54.0 and 34.0 <= float(lat) <= 37.0, (i, lat, lon)
    assert geo.get("metadata", {}).get("license") == "ODbL-1.0"
    print("Validated bundled offline metro/BRT data:", dict(counts))
