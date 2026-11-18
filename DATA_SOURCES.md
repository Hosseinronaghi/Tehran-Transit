# Sources and data quality — Tehran Transit 0.4

## Included offline metro/BRT GeoJSON
Path: `assets/data/rail_brt.geojson`

This is a **derived database distributed under ODbL 1.0**. Source repositories:

1. Tehran Metro graph: [mostafa-kheibary/tehran-metro-data](https://github.com/mostafa-kheibary/tehran-metro-data), file `data/stations.json`, Git blob `78a2a3b50ad61c3bca62b9253b9fe37ddf6406f2`, ODbL 1.0.
2. Tehran bus and BRT graph: [mosayeb-a/tehran-bus-data](https://github.com/mosayeb-a/tehran-bus-data), file `data/stations.json`, Git blob `248e0d433832047a846be56bd56834cb104ba7da`, ODbL 1.0.

See the original repositories for their licensing notices and full data.

### Conversion
- Metro: include graph stations with `disabled == false` and geographically valid coordinates (133 points). Connect pairs named in `relations` only when both stations are active and share a metro line (137 straight-line features).
- BRT: take station records with valid coordinates from the bus graph and positions in route-code ranges `101–110` (day), `121–171` (special), or `901–910` (night). This yielded 452 unique station points. Connect adjacent stops by the line and direction's source `position` values; deduplicate bidirectional identical station pairs (1,463 straight-line features). Skip 20 links with a geographical gap over 2.5 km as potentially misleading; no missing coordinates are invented.
- Each generated segment is a **schematic straight link between two station coordinates**, not the actual road or underground track geometry. Geometry metadata marks this distinction.
- Do not include BRT coordinates equal to 0. The separately examined [iran-public-transport](https://github.com/MohammadAmin-Andy/iran-public-transport) BRT JSON had only 2 valid geolocated stations among 52, so it was **not** used for geometry.

### Generated feature counts
| Mode | Station points | Schematic segment features |
|---|---:|---:|
| Metro | 133 | 137 |
| BRT | 452 | 1,463 |
| Total | 585 | 1,600 |

### Critical limitations
These data are volunteer-maintained snapshots and are **not a certified current network map**. They must be validated against a current official source before depending on accessibility, operational status, travel times, or exact transfers. Straight station links do not represent the true BRT/metro path or pedestrian interchange distance. OpenStreetMap online tiles remain separate and require internet access.

### Build policy
The shipped GeoJSON and the compact source bus JSON are checked into the Git repository and validated by CI. GitHub Actions does **not** request Overpass to regenerate it. The bus SQLite is generated from the pinned ODbL snapshot `assets/data/tehran_bus_stations.json` (4,759 station records, including 9,511 position entries). This compact snapshot preserves the source names, coordinates and route-position information needed to reproduce the SQLite database. No transit dataset is downloaded during GitHub Actions builds. Flutter and Android tools are still downloaded as part of the build.

To update geometry, explicitly fetch/review fresh upstream sources, regenerate features, validate positions and line coverage, and commit the updated GeoJSON with source revision metadata. Do **not** silently replace the pinned data with an unvalidated empty feed.
