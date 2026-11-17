#!/usr/bin/env python3
"""Fail early if the generated SQLite asset is empty or has broken route references."""
import sqlite3,sys,json,pathlib
path=pathlib.Path(sys.argv[1])
assert path.is_file() and path.stat().st_size>10000, f'Invalid SQLite asset: {path}'
db=sqlite3.connect(path)
counts={table:db.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0] for table in ('stations','routes','route_variants','route_stops')}
assert counts['stations']>1000 and counts['routes']>50 and counts['route_stops']>1000, counts
assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
assert db.execute('SELECT COUNT(*) FROM route_stops rs LEFT JOIN stations s ON rs.station_id=s.id WHERE s.id IS NULL').fetchone()[0]==0
print('Validated SQLite:',counts)
if len(sys.argv)>2:
    geo=json.loads(pathlib.Path(sys.argv[2]).read_text())
    assert geo['type']=='FeatureCollection'
    features=geo['features']
    print('Metro/BRT GeoJSON features:',len(features))
    if not features: print('WARNING: no metro/BRT features were returned by OSM')
