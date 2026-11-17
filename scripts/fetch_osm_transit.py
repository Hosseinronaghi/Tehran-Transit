#!/usr/bin/env python3
"""Fetch metro and BRT route geometries and stations from OpenStreetMap Overpass.
OSM is community-maintained: coverage and operational status are not guaranteed.
Writes a compact GeoJSON FeatureCollection; do not fabricate missing routes.
"""
import json, urllib.parse, urllib.request, pathlib, sys, time
OUTPUT = pathlib.Path(sys.argv[1] if len(sys.argv)>1 else 'assets/data/rail_brt.geojson')
# Greater Tehran bounding box (south,west,north,east).
BBOX = '35.48,51.10,35.91,51.72'
QUERY = f"""[out:json][timeout:180];
(
  relation["type"="route"]["route"="subway"]({BBOX});
  relation["type"="route"]["route"="bus"]["name"~"BRT|بی آر تی|تندرو",i]({BBOX});
  nwr["railway"="station"]["station"="subway"]({BBOX});
  nwr["public_transport"="station"]["name"~"BRT|بی آر تی|تندرو",i]({BBOX});
);
out body geom;
"""
def fetch():
    payload=urllib.parse.urlencode({'data':QUERY}).encode()
    errors=[]
    for endpoint in ['https://overpass.kumi.systems/api/interpreter','https://overpass-api.de/api/interpreter']:
        try:
            req=urllib.request.Request(endpoint,data=payload,headers={'User-Agent':'TehranTransit/0.2 (OpenStreetMap attribution; public transport research)'})
            with urllib.request.urlopen(req,timeout=240) as res: return json.load(res)
        except Exception as exc: errors.append(f'{endpoint}: {exc}')
    raise RuntimeError('Overpass unavailable: '+'; '.join(errors))
def name(tags):
    return tags.get('name:fa') or tags.get('name') or 'بدون نام'
def mode(tags):
    return 'metro' if tags.get('route')=='subway' or tags.get('station')=='subway' else 'brt'
def feature(geom,properties):
    return {'type':'Feature','geometry':geom,'properties':properties}
def main():
    elements=fetch()['elements']
    features=[]
    seen=set()
    for el in elements:
        tags=el.get('tags',{})
        typ=mode(tags)
        ident=f"{el['type']}/{el['id']}"
        if el['type']=='relation':
            # Each member way is a segment, not necessarily sorted. Keep segments separate.
            for idx,m in enumerate(el.get('members',[])):
                if m.get('type')!='way' or len(m.get('geometry',[]))<2: continue
                coords=[[p['lon'],p['lat']] for p in m['geometry']]
                features.append(feature({'type':'LineString','coordinates':coords},{
                    'id':ident,'segment':idx,'mode':typ,'kind':'route','name':name(tags),
                    'ref':tags.get('ref',''),'colour':tags.get('colour',''),
                    'osm_id':el['id']}))
        else:
            pt=el if 'lat' in el else (el.get('center') or {})
            if 'lat' not in pt or 'lon' not in pt: continue
            key=(typ,round(pt['lat'],6),round(pt['lon'],6))
            if key in seen: continue
            seen.add(key)
            features.append(feature({'type':'Point','coordinates':[pt['lon'],pt['lat']]},{
                'id':ident,'mode':typ,'kind':'station','name':name(tags),'osm_id':el['id']}))
    OUTPUT.parent.mkdir(parents=True,exist_ok=True)
    OUTPUT.write_text(json.dumps({'type':'FeatureCollection','features':features},ensure_ascii=False,separators=(',',':')),encoding='utf-8')
    print(f'OSM: {len(elements)} elements, {len(features)} features -> {OUTPUT}')
if __name__=='__main__': main()
