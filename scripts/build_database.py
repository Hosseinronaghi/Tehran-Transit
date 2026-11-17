#!/usr/bin/env python3
"""Generate a minimal read-only SQLite asset from the upstream Tehran bus JSON."""
import json, sqlite3, pathlib, sys
source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
target.parent.mkdir(parents=True, exist_ok=True)
data = json.loads(source.read_text(encoding='utf-8'))
if target.exists(): target.unlink()
db = sqlite3.connect(target)
db.executescript("""
CREATE TABLE stations(id INTEGER PRIMARY KEY, name_fa TEXT NOT NULL, latitude REAL, longitude REAL);
CREATE TABLE routes(id INTEGER PRIMARY KEY, route_code TEXT NOT NULL, name_fa TEXT NOT NULL, mode TEXT NOT NULL);
CREATE TABLE route_variants(id INTEGER PRIMARY KEY, route_id INTEGER NOT NULL, direction TEXT NOT NULL);
CREATE TABLE route_stops(route_variant_id INTEGER NOT NULL, station_id INTEGER NOT NULL, stop_sequence INTEGER NOT NULL);
CREATE INDEX idx_stops_variant ON route_stops(route_variant_id,stop_sequence);
""")
for key, item in data.items():
    try: lat=float(item.get('latitude')); lon=float(item.get('longitude'))
    except (TypeError, ValueError): lat=lon=None
    db.execute("INSERT INTO stations VALUES (?,?,?,?)",(int(key),item.get('name') or 'بدون نام',lat,lon))
lines = sorted({int(p['line']) for s in data.values() for p in s.get('positions',[])})
for line in lines:
    mode = 'brt' if 101 <= line <= 110 or 121 <= line <= 171 else 'regular'
    db.execute("INSERT INTO routes VALUES (?,?,?,?)",(line,str(line),f'خط {line}',mode))
groups={}
for key,item in data.items():
    for pos in item.get('positions',[]):
        line=int(pos['line']); forward=bool(pos.get('is_forward'))
        direction='outbound' if forward else 'inbound'
        groups.setdefault((line,direction),[]).append((int(pos['position']),int(key)))
for i,((line,direction),stops) in enumerate(sorted(groups.items()),1):
    db.execute("INSERT INTO route_variants VALUES (?,?,?)",(i,line,direction))
    db.executemany("INSERT INTO route_stops VALUES (?,?,?)",[(i,station,position) for position,station in sorted(set(stops))])
db.commit()
print(f"Imported {db.execute('select count(*) from stations').fetchone()[0]} stations and {len(lines)} lines")
db.close()
