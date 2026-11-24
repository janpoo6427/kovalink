#!/usr/bin/env python3
"""Generate the KovaLink basic example vehicle (assets/vehicles/kovalink_basic).

Self-made low-poly car, released under CC0-1.0 by the KovaLink project.
It follows docs/VEHICLE_MODEL_PACK.md exactly so it doubles as the reference
pack for model authors:

- glTF 2.0 binary, meters, right-handed, +X right, +Y up, +Z forward
- origin on the ground, centered between the rear wheels (rearAxleGround)
- named nodes and KL_* materials for paint, glass, lamps and wheels

Usage: python3 tool/make_basic_vehicle_glb.py [output.glb]
Output is deterministic (same bytes on every run).
"""

import json
import math
import struct
import sys

LENGTH, WIDTH, HEIGHT, WHEELBASE = 4.60, 1.86, 1.50, 2.80
OVERHANG = (LENGTH - WHEELBASE) / 2  # front == rear overhang
REAR_Z, FRONT_Z = -OVERHANG, WHEELBASE + OVERHANG
WHEEL_R, WHEEL_W = 0.34, 0.24
TRACK = WIDTH / 2 - 0.13

MATERIALS = [
    # name, baseColor RGBA, metallic, roughness, emissive RGB
    ("KL_BodyPaint", (0.33, 0.37, 0.42, 1.0), 0.55, 0.32, (0, 0, 0)),
    ("KL_Glass", (0.05, 0.08, 0.11, 1.0), 0.1, 0.08, (0, 0, 0)),
    ("KL_Trim", (0.06, 0.07, 0.08, 1.0), 0.2, 0.6, (0, 0, 0)),
    ("KL_Tire", (0.03, 0.03, 0.03, 1.0), 0.0, 0.9, (0, 0, 0)),
    ("KL_Rim", (0.62, 0.65, 0.68, 1.0), 0.9, 0.3, (0, 0, 0)),
    ("KL_Tail", (0.55, 0.05, 0.08, 1.0), 0.0, 0.4, (0.25, 0.0, 0.02)),
    ("KL_Brake", (0.75, 0.06, 0.10, 1.0), 0.0, 0.4, (0, 0, 0)),
    ("KL_TurnLeft", (0.95, 0.55, 0.05, 1.0), 0.0, 0.4, (0, 0, 0)),
    ("KL_TurnRight", (0.95, 0.55, 0.05, 1.0), 0.0, 0.4, (0, 0, 0)),
    ("KL_Reverse", (0.92, 0.94, 0.96, 1.0), 0.0, 0.3, (0, 0, 0)),
    ("KL_Head", (0.92, 0.95, 1.0, 1.0), 0.0, 0.2, (0.6, 0.65, 0.7)),
]
MAT = {m[0]: i for i, m in enumerate(MATERIALS)}


def box(x0, x1, y0, y1, z0, z1, taper=0.0):
    """Flat-shaded box; `taper` pulls the top face inward (cabin shape)."""
    t = taper
    top = [(x0 + t, y1, z0 + t), (x1 - t, y1, z0 + t), (x1 - t, y1, z1 - t), (x0 + t, y1, z1 - t)]
    bot = [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)]
    faces = [
        [bot[0], bot[3], bot[2], bot[1]],  # bottom
        [top[0], top[1], top[2], top[3]],  # top
        [bot[0], bot[1], top[1], top[0]],  # rear (-Z)
        [bot[2], bot[3], top[3], top[2]],  # front (+Z)
        [bot[3], bot[0], top[0], top[3]],  # left (-X)
        [bot[1], bot[2], top[2], top[1]],  # right (+X)
    ]
    return quads(faces)


def quads(faces):
    pos, nrm, idx = [], [], []
    for f in faces:
        n = normal(f[0], f[1], f[2])
        base = len(pos)
        pos.extend(f)
        nrm.extend([n] * 4)
        idx.extend([base, base + 1, base + 2, base, base + 2, base + 3])
    return pos, nrm, idx


def normal(a, b, c):
    u = [b[i] - a[i] for i in range(3)]
    v = [c[i] - a[i] for i in range(3)]
    n = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
    length = math.sqrt(sum(x * x for x in n)) or 1.0
    return tuple(x / length for x in n)


def wheel(radius, width, segments=16):
    """Cylinder around the X axis, centered at the node origin."""
    pos, nrm, idx = [], [], []
    hw = width / 2
    ring = [(math.cos(2 * math.pi * i / segments), math.sin(2 * math.pi * i / segments)) for i in range(segments)]
    for i in range(segments):
        (c0, s0), (c1, s1) = ring[i], ring[(i + 1) % segments]
        quad = [(-hw, s0 * radius, c0 * radius), (hw, s0 * radius, c0 * radius),
                (hw, s1 * radius, c1 * radius), (-hw, s1 * radius, c1 * radius)]
        mid = (0, (s0 + s1) / 2, (c0 + c1) / 2)
        length = math.sqrt(mid[1] ** 2 + mid[2] ** 2)
        base = len(pos)
        pos.extend(quad)
        nrm.extend([(0, mid[1] / length, mid[2] / length)] * 4)
        idx.extend([base, base + 2, base + 1, base, base + 3, base + 2])
    tire = (pos, nrm, idx)
    rim_pos, rim_nrm, rim_idx = [], [], []
    for side in (-1, 1):
        center = len(rim_pos)
        rim_pos.append((side * (hw + 0.002), 0, 0))
        rim_nrm.append((side, 0, 0))
        for c, s in ring:
            rim_pos.append((side * (hw + 0.002), s * radius * 0.62, c * radius * 0.62))
            rim_nrm.append((side, 0, 0))
        for i in range(segments):
            a, b = center + 1 + i, center + 1 + (i + 1) % segments
            rim_idx.extend([center, a, b] if side > 0 else [center, b, a])
    return tire, (rim_pos, rim_nrm, rim_idx)


def build():
    meshes = []  # (name, [(geometry, material)])
    nodes = []

    def add_node(name, parts, translation=None, children=None):
        mesh_index = None
        if parts:
            mesh_index = len(meshes)
            meshes.append((name, parts))
        node = {"name": name}
        if mesh_index is not None:
            node["mesh"] = mesh_index
        if translation:
            node["translation"] = list(translation)
        if children:
            node["children"] = children
        nodes.append(node)
        return len(nodes) - 1

    x0, x1 = -WIDTH / 2, WIDTH / 2
    children = []
    children.append(add_node("Cabin", [(box(x0 + 0.10, x1 - 0.10, 0.92, HEIGHT - 0.04, 0.10, 2.70, taper=0.12), MAT["KL_Glass"])]))
    children.append(add_node("Roof", [(box(x0 + 0.24, x1 - 0.24, HEIGHT - 0.06, HEIGHT, 0.40, 2.40), MAT["KL_BodyPaint"])]))
    children.append(add_node("Bumper_R", [(box(x0 + 0.04, x1 - 0.04, 0.22, 0.42, REAR_Z - 0.03, REAR_Z + 0.10), MAT["KL_Trim"])]))
    children.append(add_node("Bumper_F", [(box(x0 + 0.04, x1 - 0.04, 0.22, 0.42, FRONT_Z - 0.10, FRONT_Z + 0.03), MAT["KL_Trim"])]))
    lamp_z = REAR_Z - 0.012
    for name, mat, (lx0, lx1, ly0, ly1) in [
        ("Tail_L", "KL_Tail", (x0 + 0.06, x0 + 0.40, 0.70, 0.80)),
        ("Tail_R", "KL_Tail", (x1 - 0.40, x1 - 0.06, 0.70, 0.80)),
        ("Brake_C", "KL_Brake", (-0.30, 0.30, HEIGHT - 0.14, HEIGHT - 0.09)),
        ("Brake_L", "KL_Brake", (x0 + 0.06, x0 + 0.30, 0.62, 0.70)),
        ("Brake_R", "KL_Brake", (x1 - 0.30, x1 - 0.06, 0.62, 0.70)),
        ("Turn_RL", "KL_TurnLeft", (x0 + 0.30, x0 + 0.42, 0.62, 0.70)),
        ("Turn_RR", "KL_TurnRight", (x1 - 0.42, x1 - 0.30, 0.62, 0.70)),
        ("Reverse_L", "KL_Reverse", (x0 + 0.50, x0 + 0.62, 0.30, 0.38)),
        ("Reverse_R", "KL_Reverse", (x1 - 0.62, x1 - 0.50, 0.30, 0.38)),
    ]:
        children.append(add_node(name, [(box(lx0, lx1, ly0, ly1, lamp_z - 0.02, lamp_z + 0.02), MAT[mat])]))
    head_z = FRONT_Z + 0.012
    for name, mat, (lx0, lx1) in [
        ("Head_L", "KL_Head", (x0 + 0.10, x0 + 0.46)),
        ("Head_R", "KL_Head", (x1 - 0.46, x1 - 0.10)),
        ("Turn_FL", "KL_TurnLeft", (x0 + 0.04, x0 + 0.12)),
        ("Turn_FR", "KL_TurnRight", (x1 - 0.12, x1 - 0.04)),
    ]:
        children.append(add_node(name, [(box(lx0, lx1, 0.66, 0.74, head_z - 0.02, head_z + 0.02), MAT[mat])]))
    tire, rim = wheel(WHEEL_R, WHEEL_W)
    for name, x, z in [("Wheel_FL", -TRACK, WHEELBASE), ("Wheel_FR", TRACK, WHEELBASE),
                       ("Wheel_RL", -TRACK, 0.0), ("Wheel_RR", TRACK, 0.0)]:
        children.append(add_node(name, [(tire, MAT["KL_Tire"]), (rim, MAT["KL_Rim"])], translation=(x, WHEEL_R, z)))
    body = add_node("Body", [(box(x0, x1, 0.20, 0.92, REAR_Z, FRONT_Z, taper=0.03), MAT["KL_BodyPaint"])], children=children)
    return meshes, nodes, body


def pack(meshes, nodes, root):
    binary = bytearray()
    views, accessors, gl_meshes = [], [], []

    def add_view(data, target):
        while len(binary) % 4:
            binary.append(0)
        views.append({"buffer": 0, "byteOffset": len(binary), "byteLength": len(data), "target": target})
        binary.extend(data)
        return len(views) - 1

    for name, parts in meshes:
        primitives = []
        for (pos, nrm, idx), material in parts:
            p = add_view(b"".join(struct.pack("<3f", *v) for v in pos), 34962)
            n = add_view(b"".join(struct.pack("<3f", *v) for v in nrm), 34962)
            i = add_view(b"".join(struct.pack("<H", v) for v in idx), 34963)
            mins = [round(min(v[k] for v in pos), 6) for k in range(3)]
            maxs = [round(max(v[k] for v in pos), 6) for k in range(3)]
            accessors.append({"bufferView": p, "componentType": 5126, "count": len(pos), "type": "VEC3", "min": mins, "max": maxs})
            accessors.append({"bufferView": n, "componentType": 5126, "count": len(nrm), "type": "VEC3"})
            accessors.append({"bufferView": i, "componentType": 5123, "count": len(idx), "type": "SCALAR"})
            a = len(accessors)
            primitives.append({"attributes": {"POSITION": a - 3, "NORMAL": a - 2}, "indices": a - 1, "material": material})
        gl_meshes.append({"name": name, "primitives": primitives})

    while len(binary) % 4:
        binary.append(0)
    gltf = {
        "asset": {"version": "2.0", "generator": "kovalink tool/make_basic_vehicle_glb.py",
                  "copyright": "CC0-1.0, KovaLink project"},
        "scene": 0,
        "scenes": [{"name": "KovaLinkBasic", "nodes": [root]}],
        "nodes": nodes,
        "meshes": gl_meshes,
        "materials": [
            {"name": n, "pbrMetallicRoughness": {"baseColorFactor": list(c), "metallicFactor": m, "roughnessFactor": r},
             "emissiveFactor": list(e), "doubleSided": True}
            for n, c, m, r, e in MATERIALS
        ],
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": len(binary)}],
    }
    text = json.dumps(gltf, separators=(",", ":"), sort_keys=True).encode()
    text += b" " * ((4 - len(text) % 4) % 4)
    total = 12 + 8 + len(text) + 8 + len(binary)
    return (struct.pack("<III", 0x46546C67, 2, total) + struct.pack("<II", len(text), 0x4E4F534A) + text
            + struct.pack("<II", len(binary), 0x004E4942) + bytes(binary))


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "assets/vehicles/kovalink_basic/vehicle.glb"
    meshes, nodes, root = build()
    data = pack(meshes, nodes, root)
    with open(out, "wb") as f:
        f.write(data)
    tris = sum(len(idx) // 3 for _, parts in meshes for (_, _, idx), _ in parts)
    print(f"wrote {out}: {len(data)} bytes, {tris} triangles, {len(nodes)} nodes")
