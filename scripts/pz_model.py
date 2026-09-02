"""Render a Project Zomboid world model - binary FBX plus its texture - to an RGBA image.

Pure Python, no 3D library: these meshes are a couple of hundred triangles each, so a
painter's algorithm with a z-buffer runs faster than a dependency installs. make_art.py
uses it to put the game's own cooler and our bag of ice on the poster.
"""
import math
import struct
import zlib

from PIL import Image


# --------------------------------------------------------------------------
# Binary FBX 7.3/7.4: nested records of {end offset, properties, name, children}.
# --------------------------------------------------------------------------

_SCALAR = {"Y": "<h", "C": "<b", "I": "<i", "F": "<f", "D": "<d", "L": "<q"}
_ARRAY = {"f": "f", "d": "d", "l": "q", "b": "b", "i": "i", "c": "B"}


def _read_node(data, off, version):
    if version >= 7500:
        end, nprops, _ = struct.unpack_from("<QQQ", data, off)
        off += 24
    else:
        end, nprops, _ = struct.unpack_from("<III", data, off)
        off += 12
    name_len = data[off]
    off += 1
    name = data[off:off + name_len].decode("utf-8", "replace")
    off += name_len
    if end == 0:
        return None, off                      # the null record that closes a child list

    props = []
    for _ in range(nprops):
        kind = chr(data[off])
        off += 1
        if kind in _SCALAR:
            fmt = _SCALAR[kind]
            props.append(struct.unpack_from(fmt, data, off)[0])
            off += struct.calcsize(fmt)
        elif kind in _ARRAY:
            count, encoding, length = struct.unpack_from("<III", data, off)
            off += 12
            raw = data[off:off + length]
            off += length
            if encoding == 1:
                raw = zlib.decompress(raw)
            props.append(list(struct.unpack("<%d%s" % (count, _ARRAY[kind]), raw)))
        elif kind in "SR":
            length = struct.unpack_from("<I", data, off)[0]
            off += 4
            props.append(data[off:off + length])
            off += length
        else:
            raise ValueError("unknown FBX property type %r" % kind)

    children = []
    while off < end:
        child, off = _read_node(data, off, version)
        if child is None:
            break
        children.append(child)
    return {"name": name, "props": props, "children": children}, end


def _parse(path):
    with open(path, "rb") as handle:
        data = handle.read()
    version = struct.unpack_from("<I", data, 23)[0]
    off, roots = 27, []
    while off < len(data) - 160:              # the footer is never a record
        node, off = _read_node(data, off, version)
        if node is None:
            break
        roots.append(node)
    return roots


def _walk(nodes, name):
    for node in nodes:
        if node["name"] == name:
            yield node
        for found in _walk(node["children"], name):
            yield found


# --------------------------------------------------------------------------
# Geometry
# --------------------------------------------------------------------------

_cache = {}


def load(mesh_path):
    """(vertices, triangles, uv_of, normal_of, centre, radius) for one mesh."""
    if mesh_path in _cache:
        return _cache[mesh_path]

    geometry = next(_walk(_parse(mesh_path), "Geometry"))
    child = lambda parent, nm: next(c for c in parent["children"] if c["name"] == nm)

    flat = child(geometry, "Vertices")["props"][0]
    polygon_index = child(geometry, "PolygonVertexIndex")["props"][0]

    uv_layer = child(geometry, "LayerElementUV")
    uvs = child(uv_layer, "UV")["props"][0]
    reference = child(uv_layer, "ReferenceInformationType")["props"][0]
    uv_index = child(uv_layer, "UVIndex")["props"][0] if b"IndexToDirect" in reference else None
    normals = child(child(geometry, "LayerElementNormal"), "Normals")["props"][0]

    vertices = [(flat[i * 3], flat[i * 3 + 1], flat[i * 3 + 2]) for i in range(len(flat) // 3)]

    # PolygonVertexIndex marks the last corner of each polygon by negating it.
    triangles, polygon = [], []
    for corner, index in enumerate(polygon_index):
        last = index < 0
        polygon.append(((~index if last else index), corner))
        if last:
            for i in range(1, len(polygon) - 1):
                triangles.append((polygon[0], polygon[i], polygon[i + 1]))
            polygon = []

    def uv_of(corner):
        i = uv_index[corner] if uv_index is not None else corner
        return uvs[i * 2], uvs[i * 2 + 1]

    def normal_of(corner):
        return normals[corner * 3], normals[corner * 3 + 1], normals[corner * 3 + 2]

    axes = list(zip(*vertices))
    centre = tuple((min(a) + max(a)) / 2 for a in axes)
    radius = max(max(abs(v[i] - centre[i]) for i in range(3)) for v in vertices)

    _cache[mesh_path] = (vertices, triangles, uv_of, normal_of, centre, radius)
    return _cache[mesh_path]


def render(mesh_path, texture_path, size=512, yaw=45.0, pitch=25.0, supersample=3,
           zoom=1.0, light=(-0.45, -0.55, 0.70), ambient=0.55, gain=0.55):
    """The model on a transparent background, orthographic like the game's camera.

    `yaw` spins the model about its up axis, `pitch` tilts the camera down towards it.
    """
    vertices, triangles, uv_of, normal_of, (cx, cy, cz), radius = load(mesh_path)
    texture = Image.open(texture_path).convert("RGB")
    tex_w, tex_h = texture.size
    texel = texture.load()

    side = size * supersample
    image = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    pixel = image.load()
    depths = [[-1e9] * side for _ in range(side)]

    cos_y, sin_y = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    cos_p, sin_p = math.cos(math.radians(pitch)), math.sin(math.radians(pitch))
    scale = side / (radius * 2.45) * zoom

    def spin(x, y, z):
        x, y = x * cos_y - y * sin_y, x * sin_y + y * cos_y
        y, z = y * cos_p - z * sin_p, y * sin_p + z * cos_p
        return x, y, z

    def project(vertex):
        x, y, z = spin(vertex[0] - cx, vertex[1] - cy, vertex[2] - cz)
        # -y as the depth key so the near surface wins the z-test, not the far one.
        return side / 2 + x * scale, side / 2 - z * scale, -y

    length = math.sqrt(sum(c * c for c in light))
    lx, ly, lz = (c / length for c in light)

    for triangle in triangles:
        points = [project(vertices[v]) for v, _ in triangle]
        corner_uv = [uv_of(c) for _, c in triangle]
        corner_n = [spin(*normal_of(c)) for _, c in triangle]

        left = max(0, int(min(p[0] for p in points)))
        right = min(side - 1, int(max(p[0] for p in points)) + 1)
        top = max(0, int(min(p[1] for p in points)))
        bottom = min(side - 1, int(max(p[1] for p in points)) + 1)
        if right < left or bottom < top:
            continue

        (ax, ay, _), (bx, by, _), (mx, my, _) = points
        denominator = (by - my) * (ax - mx) + (mx - bx) * (ay - my)
        if abs(denominator) < 1e-9:
            continue

        for y in range(top, bottom + 1):
            for x in range(left, right + 1):
                px, py = x + 0.5, y + 0.5
                wa = ((by - my) * (px - mx) + (mx - bx) * (py - my)) / denominator
                wb = ((my - ay) * (px - mx) + (ax - mx) * (py - my)) / denominator
                wc = 1 - wa - wb
                if wa < 0 or wb < 0 or wc < 0:
                    continue
                depth = wa * points[0][2] + wb * points[1][2] + wc * points[2][2]
                if depth <= depths[y][x]:
                    continue
                depths[y][x] = depth

                u = wa * corner_uv[0][0] + wb * corner_uv[1][0] + wc * corner_uv[2][0]
                v = wa * corner_uv[0][1] + wb * corner_uv[1][1] + wc * corner_uv[2][1]
                r, g, b = texel[int(u % 1.0 * (tex_w - 1)), int((1 - v % 1.0) * (tex_h - 1))]

                nx = wa * corner_n[0][0] + wb * corner_n[1][0] + wc * corner_n[2][0]
                ny = wa * corner_n[0][1] + wb * corner_n[1][1] + wc * corner_n[2][1]
                nz = wa * corner_n[0][2] + wb * corner_n[1][2] + wc * corner_n[2][2]
                norm = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
                lambert = (nx * lx + ny * ly + nz * lz) / norm
                if lambert < 0:
                    lambert = -lambert * 0.35          # a little bounce, never black
                shade = ambient + gain * lambert
                pixel[x, y] = (min(255, int(r * shade)), min(255, int(g * shade)),
                               min(255, int(b * shade)), 255)

    return image.resize((size, size), Image.LANCZOS)
