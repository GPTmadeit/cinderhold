#!/usr/bin/env python3
"""Build the Times Square map data from OpenStreetMap.

Fetches buildings, streets and subway entrances around Times Square from the
Overpass API (or reads a cached copy), turns Manhattan's grid square to the
game's axes, scales it down and writes scripts/world/maps/times_square_data.gd.

Map data (c) OpenStreetMap contributors, available under the Open Database
License (ODbL): https://www.openstreetmap.org/copyright

  tools/manhattan/build_times_square.py [cached.json]
"""
import base64, json, math, os, struct, sys, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "scripts/world/maps/times_square_data.gd")
BBOX = (40.7552, -73.9893, 40.7608, -73.9822)
LAT0, LON0 = 40.7580, -73.9857
GRID_DEG = 29.14            # Manhattan's avenues, degrees east of north
K = 0.2                     # game metres per real metre (1:5)
HEIGHT_K = 0.35             # heights shrink less, so the streets stay canyons
MIN_H, MAX_H = 4.5, 72.0
U0, U1, V0, V1 = -75.0, 125.0, -255.0, 175.0   # play area, real metres: 7th Av's west row to past Broadway, 42nd to 47th St
FINE = 8                    # street-level raster: 8 per game metre
SKY = 4                     # skyline raster: 4 per game metre
MARGIN = 30.0               # skyline beyond the play area, game metres

QUERY = """[out:json][timeout:90];
(
  way["building"]({s},{w},{n},{e});
  relation["building"]({s},{w},{n},{e});
  way["building:part"]({s},{w},{n},{e});
  relation["building:part"]({s},{w},{n},{e});
  way["highway"]({s},{w},{n},{e});
  node["railway"="subway_entrance"]({s},{w},{n},{e});
);
out body;
>;
out skel qt;""".format(s=BBOX[0], w=BBOX[1], n=BBOX[2], e=BBOX[3])


MIRRORS = ["https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter",
           "https://overpass.private.coffee/api/interpreter"]


def fetch():
    for url in MIRRORS:
        req = urllib.request.Request(url, data=urllib.parse.urlencode({"data": QUERY}).encode(),
            headers={"User-Agent": "Cinderhold-mapgen (github.com/GPTmadeit/cinderhold)"})
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                return json.load(r)
        except (OSError, ValueError) as err:
            print("overpass: %s failed (%s), trying the next server" % (url, err), file=sys.stderr)
    raise SystemExit("no Overpass server answered")


TH = math.radians(GRID_DEG)


def game_xy(lat, lon):
    x = (lon - LON0) * 111320 * math.cos(math.radians(LAT0))
    y = (lat - LAT0) * 110574
    u = x * math.cos(TH) - y * math.sin(TH)
    v = x * math.sin(TH) + y * math.cos(TH)
    return ((u - U0) * K, (V1 - v) * K)


def fill_polygon(poly, res, ox, oz, w, h, grid, value):
    """Scanline-fill `poly` (game metres) into grid[w*h] at `res` cells per metre."""
    zs = [p[1] for p in poly]
    r0 = max(0, int(math.floor((min(zs) - oz) * res)))
    r1 = min(h - 1, int(math.ceil((max(zs) - oz) * res)))
    n = len(poly)
    for r in range(r0, r1 + 1):
        zc = oz + (r + 0.5) / res
        xs = []
        for i in range(n):
            (x1, z1), (x2, z2) = poly[i], poly[(i + 1) % n]
            if (z1 > zc) != (z2 > zc):
                xs.append(x1 + (zc - z1) * (x2 - x1) / (z2 - z1))
        xs.sort()
        for a, b in zip(xs[0::2], xs[1::2]):
            c0 = max(0, int(math.ceil((a - ox) * res - 0.5)))
            c1 = min(w - 1, int(math.floor((b - ox) * res - 0.5)))
            for c in range(c0, c1 + 1):
                grid[r * w + c] = value


def distance(grid_open, w, h):
    """Chamfer distance (in cells) from every cell to the nearest non-open cell."""
    INF = 1 << 20
    d = [0 if not grid_open[i] else INF for i in range(w * h)]
    for r in range(h):
        for c in range(w):
            i = r * w + c
            if d[i]:
                best = d[i]
                if c > 0: best = min(best, d[i - 1] + 3)
                if r > 0:
                    best = min(best, d[i - w] + 3)
                    if c > 0: best = min(best, d[i - w - 1] + 4)
                    if c < w - 1: best = min(best, d[i - w + 1] + 4)
                d[i] = best
    for r in range(h - 1, -1, -1):
        for c in range(w - 1, -1, -1):
            i = r * w + c
            if d[i]:
                best = d[i]
                if c < w - 1: best = min(best, d[i + 1] + 3)
                if r < h - 1:
                    best = min(best, d[i + w] + 3)
                    if c < w - 1: best = min(best, d[i + w + 1] + 4)
                    if c > 0: best = min(best, d[i + w - 1] + 4)
                d[i] = best
    return [x / 3.0 for x in d]


def seg_dist(px, pz, a, b):
    (ax, az), (bx, bz) = a, b
    dx, dz = bx - ax, bz - az
    L = dx * dx + dz * dz
    t = 0.0 if L == 0 else max(0.0, min(1.0, ((px - ax) * dx + (pz - az) * dz) / L))
    return math.hypot(px - (ax + t * dx), pz - (az + t * dz))


def rle(values):
    out = bytearray()
    i = 0
    while i < len(values):
        v = values[i]
        j = i
        while j < len(values) and values[j] == v and j - i < 65535:
            j += 1
        out += struct.pack("<HH", v, j - i)
        i = j
    return base64.b64encode(bytes(out)).decode()


def tag_height(t):
    """Height in real metres from height or building:levels tags, or 0."""
    try:
        h = float(str(t.get("height", "0")).split()[0] or 0)
    except (ValueError, IndexError):
        h = 0.0
    if not h and t.get("building:levels"):
        try:
            h = float(t["building:levels"]) * 3.6
        except ValueError:
            h = 0.0
    return h


def inside(pt, poly):
    x, z = pt
    hit = False
    for i in range(len(poly)):
        (x0, z0), (x1, z1) = poly[i], poly[i - 1]
        if (z0 > z) != (z1 > z) and x < x0 + (z - z0) * (x1 - x0) / (z1 - z0):
            hit = not hit
    return hit


def main():
    # build_times_square.py [cached.json]; with --fetch out.json it downloads first and keeps a copy
    if len(sys.argv) > 2 and sys.argv[1] == "--fetch":
        data = fetch()
        json.dump(data, open(sys.argv[2], "w"))
    else:
        data = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else fetch()
    nodes = {e["id"]: (e["lat"], e["lon"]) for e in data["elements"] if e["type"] == "node" and "lat" in e}
    ways = {e["id"]: e for e in data["elements"] if e["type"] == "way"}
    W, H = int(round((U1 - U0) * K)), int(round((V1 - V0) * K))

    # --- buildings ---
    raw = []
    for e in data["elements"]:
        t = e.get("tags", {})
        if not t.get("building") or t.get("building") in ("roof", "train_station") or t.get("location") == "underground":
            continue
        rings = []
        if e["type"] == "way":
            rings = [e["nodes"]]
        elif e["type"] == "relation":
            rings = [ways[m["ref"]]["nodes"] for m in e["members"] if m["type"] == "way" and m.get("role") == "outer" and m["ref"] in ways]
        for ring in rings:
            pts = [game_xy(*nodes[n]) for n in ring if n in nodes]
            if len(pts) >= 4 and ring[0] == ring[-1]:
                raw.append((pts[:-1], t))
    # 3D parts (towers are often mapped as a footprint plus parts carrying the heights)
    parts = []
    for e in data["elements"]:
        t = e.get("tags", {})
        if e["type"] == "way" and t.get("building:part") and tag_height(t):
            pts = [game_xy(*nodes[n]) for n in e["nodes"] if n in nodes]
            if len(pts) >= 4:
                parts.append(((sum(p[0] for p in pts[:-1]) / (len(pts) - 1), sum(p[1] for p in pts[:-1]) / (len(pts) - 1)), tag_height(t)))
    buildings = []
    tkts = (0.0, 0.0, 0.0, 0.0)
    for pts, t in raw:
        h = max([tag_height(t)] + [ph for c, ph in parts if inside(c, pts)])
        kind = "theatre" if (t.get("building") == "theatre" or t.get("amenity") == "theatre") else (
            "hotel" if t.get("building") == "hotel" or t.get("tourism") == "hotel" else "")
        if not h:
            h = 24.0 if kind == "theatre" else 22.0
        gh = max(MIN_H, min(MAX_H, h * HEIGHT_K))
        if kind == "" and h > 120:
            kind = "tower"
        elif kind == "" and h < 32:
            kind = "lowrise"
        elif kind == "":
            kind = "office"
        cx = sum(p[0] for p in pts) / len(pts)
        cz = sum(p[1] for p in pts) / len(pts)
        area = abs(sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))) / 2
        if area < 1.5:
            continue          # statue plinths and kiosks: too small to be buildings at this scale
        if t.get("name") == "TKTS":
            # the red steps in Duffy Square are a prop, not a building
            tkts = (min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts), max(p[1] for p in pts))
            continue
        if -MARGIN < cx < W + MARGIN and -MARGIN < cz < H + MARGIN:
            buildings.append({"name": t.get("name", ""), "h": round(gh, 2), "kind": kind, "poly": pts, "c": (cx, cz)})
    # big first: a smaller building sitting on a bigger footprint wins its cells
    buildings.sort(key=lambda b: -abs(sum(b["poly"][i][0] * b["poly"][(i + 1) % len(b["poly"])][1] - b["poly"][(i + 1) % len(b["poly"])][0] * b["poly"][i][1] for i in range(len(b["poly"])))))

    # --- street level raster (play area, 8 per metre) ---
    fw, fh = W * FINE, H * FINE
    fine = [0] * (fw * fh)       # 0 = open, else building index + 1
    for i, b in enumerate(buildings):
        fill_polygon(b["poly"], FINE, 0.0, 0.0, fw, fh, fine, i + 1)

    # roads: carriageways around their centrelines; Broadway through the square is plaza
    roads = []
    for e in ways.values():
        t = e.get("tags", {})
        if t.get("highway") in ("primary", "secondary", "tertiary", "residential", "unclassified", "living_street") and t.get("name"):
            if t.get("highway") == "living_street" or (t.get("name") == "Broadway" and t.get("highway") != "secondary"):
                continue
            # real curb-to-curb widths: avenues 18 m, 42nd St 14 m, side streets 10.5 m
            name = t.get("name")
            half = (9.0 if "Avenue" in name else (7.0 if "42nd" in name else 5.25)) * K
            pts = [game_xy(*nodes[n]) for n in e["nodes"] if n in nodes]
            roads.append((pts, half, t.get("name")))
    road = [False] * (fw * fh)
    for pts, half, _n in roads:
        for a, b in zip(pts, pts[1:]):
            x0, x1 = max(0, int((min(a[0], b[0]) - half) * FINE)), min(fw - 1, int((max(a[0], b[0]) + half) * FINE) + 1)
            z0, z1 = max(0, int((min(a[1], b[1]) - half) * FINE)), min(fh - 1, int((max(a[1], b[1]) + half) * FINE) + 1)
            for r in range(z0, z1 + 1):
                for c in range(x0, x1 + 1):
                    i = r * fw + c
                    if not fine[i] and not road[i] and seg_dist((c + 0.5) / FINE, (r + 0.5) / FINE, a, b) <= half:
                        road[i] = True
    to_building = distance([v == 0 for v in fine], fw, fh)     # in fine cells
    to_road = distance([not x for x in road], fw, fh)
    # surface codes for open columns (< 64): 0 plaza, 1 sidewalk, 2 road, 3 crosswalk, 4 lane line, 5 curb
    out = [0] * (fw * fh)
    for i in range(fw * fh):
        if fine[i]:
            out[i] = 63 + fine[i]              # building index + 64
            continue
        if road[i]:
            out[i] = 2
        elif to_building[i] <= 1.05 * FINE and to_road[i] > 0.5:
            out[i] = 1
        elif to_road[i] <= 1.0:
            out[i] = 5                         # a granite curb along the roadway
        else:
            out[i] = 0
    # Zebra crossings where streets meet 7th Avenue (bars run with the traffic,
    # so walkers step across them) and white dashed lane lines on the avenue.
    seventh = [p for p, h, n in roads if n == "7th Avenue"]
    streets = [(p, h) for p, h, n in roads if "Avenue" not in n]
    av_half = 9.0 * K
    for i in range(fw * fh):
        if out[i] != 2:
            continue
        r, c = divmod(i, fw)
        x, z = (c + 0.5) / FINE, (r + 0.5) / FINE
        near_av = min((seg_dist(x, z, a, b) for pts in seventh for a, b in zip(pts, pts[1:])), default=99)
        if av_half < near_av < av_half + 0.9:
            out[i] = 3 if (r // 3) % 2 == 0 else 2            # across a side street
            continue
        if near_av <= av_half:
            near_st = min(((seg_dist(x, z, a, b), h) for pts, h in streets for a, b in zip(pts, pts[1:])), default=(99, 0))
            if near_st[1] < near_st[0] < near_st[1] + 0.9:
                out[i] = 3 if (c // 3) % 2 == 0 else 2        # across the avenue
            elif any(abs(near_av - av_half * f) < 0.07 for f in (0.33, 0.66)) and (r // 12) % 2 == 0:
                out[i] = 4                                     # lane dashes

    # --- gameplay grid (1 m cells) ---
    layout = []
    for gz in range(H):
        row = ""
        for gx in range(W):
            n = 0
            for r in range(gz * FINE, gz * FINE + FINE):
                for c in range(gx * FINE, gx * FINE + FINE):
                    n += 1 if fine[r * fw + c] else 0
            row += "#" if n * 2 >= FINE * FINE else "."
        layout.append(row)
    # pockets of open ground walled off from the streets become solid
    seen = set()
    stack = [(x, z) for x in range(W) for z in (0, H - 1) if layout[z][x] == "."]
    stack += [(x, z) for z in range(H) for x in (0, W - 1) if layout[z][x] == "."]
    while stack:
        x, z = stack.pop()
        if (x, z) in seen or not (0 <= x < W and 0 <= z < H) or layout[z][x] != ".":
            continue
        seen.add((x, z))
        stack += [(x + 1, z), (x - 1, z), (x, z + 1), (x, z - 1)]
    layout = ["".join(ch if ch == "#" or (x, z) in seen else "#" for x, ch in enumerate(row)) for z, row in enumerate(layout)]

    # --- skyline raster (play area + margin, 4 per metre) ---
    sw, sh = int((W + 2 * MARGIN) * SKY), int((H + 2 * MARGIN) * SKY)
    sky = [0] * (sw * sh)
    for i, b in enumerate(buildings):
        fill_polygon(b["poly"], SKY, -MARGIN, -MARGIN, sw, sh, sky, i + 1)

    subways = []
    for e in data["elements"]:
        if e["type"] == "node" and e.get("tags", {}).get("railway") == "subway_entrance":
            x, z = game_xy(e["lat"], e["lon"])
            if 0 <= x < W and 0 <= z < H:
                subways.append((round(x, 2), round(z, 2)))
    labels = {}
    for pts, half, name in roads:
        for p in pts:
            if 0.5 < p[0] < W - 0.5 and 0.5 < p[1] < H - 0.5:
                labels.setdefault(name, []).append(p)

    with open(OUT, "w") as f:
        f.write("extends RefCounted\n")
        f.write("## Times Square, generated by tools/manhattan/build_times_square.py from\n")
        f.write("## OpenStreetMap data. Map data (c) OpenStreetMap contributors, ODbL\n")
        f.write("## (https://www.openstreetmap.org/copyright). Don't edit by hand.\n\n")
        f.write("const W := %d\nconst H := %d\nconst FINE := %d\nconst SKY := %d\nconst MARGIN := %.1f\n\n" % (W, H, FINE, SKY, MARGIN))
        f.write("const LAYOUT := [\n" + "".join('\t"%s",\n' % row for row in layout) + "]\n\n")
        f.write("## [name, height m, kind, centre x, centre z]; raster values 64+i / i+1 refer to these\n")
        f.write("const BUILDINGS := [\n")
        for b in buildings:
            f.write('\t["%s", %.2f, "%s", %.2f, %.2f],\n' % (b["name"].replace('"', "'"), b["h"], b["kind"], b["c"][0], b["c"][1]))
        f.write("]\n\n")
        f.write("## street level, %d x %d: (value, run) uint16 pairs. <64 ground (0 plaza, 1 sidewalk,\n" % (fw, fh))
        f.write("## 2 road, 3 crosswalk, 4 lane line, 5 curb), else building 64 + index\n")
        f.write('const STREET := "%s"\n\n' % rle(out))
        f.write("## skyline, %d x %d from (-MARGIN, -MARGIN): 0 open, else building index + 1\n" % (sw, sh))
        f.write('const SKYLINE := "%s"\n\n' % rle(sky))
        f.write("const SUBWAY := [%s]\n" % ", ".join("Vector2(%s, %s)" % s for s in subways))
        f.write("## the red steps in Duffy Square: x0, z0, x1, z1\n")
        f.write("const TKTS := Rect2(%.2f, %.2f, %.2f, %.2f)\n" % (tkts[0], tkts[1], tkts[2] - tkts[0], tkts[3] - tkts[1]))
        f.write("const STREET_NAMES := {\n")
        for name, pts in labels.items():
            f.write('\t"%s": [%s],\n' % (name, ", ".join("Vector2(%.1f, %.1f)" % p for p in pts[:6])))
        f.write("}\n")
    print("wrote", OUT, "| grid %dx%d, %d buildings, street raster %dx%d, skyline %dx%d, %d subway entrances"
          % (W, H, len(buildings), fw, fh, sw, sh, len(subways)))
    print("\n".join(layout))


if __name__ == "__main__":
    main()
