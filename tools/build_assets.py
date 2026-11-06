# Headless Blender asset build: models the Wakeline runner + arena pylon,
# writes Resources/*.mesh and renders the System Settings thumbnail.
# Run: Blender -b --python tools/build_assets.py -- <out_dir>
import bpy, bmesh, math, struct, os, sys
from mathutils import Matrix, Vector

OUT = sys.argv[sys.argv.index("--") + 1]
DARK, GLOW, CHROME, RUBBER = 0, 1, 2, 3
SHARP_ANGLE = math.radians(32)


def materials():
    defs = [("dark", (0.012, 0.014, 0.02, 1), 0.85, 0.28, 0),
            ("glow", (0.1, 1.0, 0.45, 1), 0, 0.3, 26),
            ("chrome", (0.55, 0.58, 0.64, 1), 1.0, 0.16, 0),
            ("rubber", (0.008, 0.008, 0.01, 1), 0, 0.72, 0)]
    mats = []
    for name, col, metal, rough, emit in defs:
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
        b.inputs["Base Color"].default_value = col
        b.inputs["Metallic"].default_value = metal
        b.inputs["Roughness"].default_value = rough
        if emit:
            b.inputs["Emission Color"].default_value = col
            b.inputs["Emission Strength"].default_value = emit
        mats.append(m)
    return mats


def to_object(bm, name, mat, subsurf=0, bevel=0.0, part="body"):
    for f in bm.faces:
        f.material_index = mat
        f.smooth = True
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in MATS:
        me.materials.append(m)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    if bevel:
        mod = ob.modifiers.new("b", "BEVEL")
        mod.width, mod.segments, mod.limit_method = bevel, 2, "ANGLE"
        mod.angle_limit = math.radians(35)
    if subsurf:
        ob.modifiers.new("s", "SUBSURF").levels = subsurf
    ob["part"] = part
    return ob


def loft(sections, mat, n=14, subsurf=1, part="body", power=2.6, x=0.0):
    """sections: (y, z, half_w, half_h). Superellipse rings skinned tail→nose."""
    bm = bmesh.new()
    rings = []
    for y, z, hw, hh in sections:
        ring = []
        for i in range(n):
            a = 2 * math.pi * i / n
            ca, sa = math.cos(a), math.sin(a)
            px = math.copysign(abs(ca) ** (2 / power), ca) * hw
            pz = math.copysign(abs(sa) ** (2 / power), sa) * hh
            ring.append(bm.verts.new((x + px, y, z + pz)))
        rings.append(ring)
    for a, b in zip(rings, rings[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bm.faces.new(rings[0][::-1])
    bm.faces.new(rings[-1])
    return to_object(bm, "loft", mat, subsurf=subsurf, part=part)


def lathe(profile, center, mat, segs=96, arc=(0.0, 2 * math.pi), part="body", name="lathe"):
    """Revolve a closed (radius, x) profile around the X axis through center."""
    bm = bmesh.new()
    full = abs(arc[1] - arc[0] - 2 * math.pi) < 1e-5
    count = segs if full else segs + 1
    rings = []
    for s in range(count):
        a = arc[0] + (arc[1] - arc[0]) * s / segs
        ring = []
        for r, x in profile:
            ring.append(bm.verts.new((center[0] + x, center[1] + r * math.cos(a), center[2] + r * math.sin(a))))
        rings.append(ring)
    n = len(profile)
    for s in range(segs):
        if not full and s == count - 1:
            break
        a, b = rings[s], rings[(s + 1) % count]
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if not full:
        bm.faces.new(rings[0][::-1])
        bm.faces.new(rings[-1])
    return to_object(bm, name, mat, part=part)


def plate(outline, x, thick, mat, part="body", bevel=0.012):
    """Extrude a (y, z) outline along X into a sharp armor plate."""
    bm = bmesh.new()
    left = [bm.verts.new((x - thick / 2, y, z)) for y, z in outline]
    right = [bm.verts.new((x + thick / 2, y, z)) for y, z in outline]
    n = len(outline)
    bm.faces.new(left)
    bm.faces.new(right[::-1])
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((left[i], left[j], right[j], right[i]))
    return to_object(bm, "plate", mat, bevel=bevel, part=part)


def wing(outline, z, thick, mat, part="body"):
    """Horizontal blade from an (x, y) outline; this is what reads from overhead."""
    bm = bmesh.new()
    low = [bm.verts.new((x, y, z - thick / 2)) for x, y in outline]
    high = [bm.verts.new((x, y, z + thick / 2)) for x, y in outline]
    n = len(outline)
    bm.faces.new(low[::-1])
    bm.faces.new(high)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((low[i], low[j], high[j], high[i]))
    return to_object(bm, "wing", mat, bevel=0.01, part=part)


def box(cen, size, mat, rot_x=0.0, part="body"):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        c = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]))
        cy, sy = math.cos(rot_x), math.sin(rot_x)
        c = Vector((c.x, c.y * cy - c.z * sy, c.y * sy + c.z * cy))
        v.co = c + Vector(cen)
    return to_object(bm, "box", mat, part=part)


def ellipse(cx, cr, hw, hr, n=20):
    out = []
    for i in range(n):
        a = 2 * math.pi * i / n
        out.append((cr + hr * math.sin(a), cx + hw * math.cos(a)))
    return out


def wheel(cy, part):
    R, cz = 0.56, 0.56
    c = (0, cy, cz)
    # Hubless rim: open centre, the tyre carries the glow and the lugs show the spin.
    lathe(ellipse(0, R - 0.085, 0.165, 0.085), c, RUBBER, segs=128, part=part, name="tyre")
    lathe(ellipse(0, R - 0.215, 0.085, 0.05), c, CHROME, segs=128, part=part, name="rim")
    lathe(ellipse(0, R - 0.272, 0.022, 0.014, 8), c, GLOW, segs=128, part=part, name="glowring")
    for side in (-1, 1):
        for k in range(6):
            a = k / 6 * 2 * math.pi
            lathe(ellipse(side * 0.158, R - 0.118, 0.011, 0.016, 8), c, GLOW, segs=12,
                  arc=(a, a + 0.62), part=part, name="tick")
    for k in range(44):
        a = k / 44 * 2 * math.pi
        y, z = cy + (R - 0.002) * math.cos(a), cz + (R - 0.002) * math.sin(a)
        box((0, y, z), (0.27, 0.05, 0.03), RUBBER, rot_x=a + math.pi / 2, part=part)
    for k in range(5):
        a = k / 5 * 2 * math.pi
        y, z = cy + (R - 0.325) * math.cos(a), cz + (R - 0.325) * math.sin(a)
        box((0, y, z), (0.05, 0.05, 0.12), CHROME, rot_x=a + math.pi / 2, part=part)


def build_runner():
    wheel(1.72, "wheelF")
    wheel(-1.72, "wheelR")
    # Arched spine: rises over both wheels, dips to the reactor between them.
    loft([(-2.48, 1.36, .03, .02), (-2.2, 1.4, .13, .05), (-1.75, 1.34, .2, .1), (-1.25, 1.2, .24, .13),
          (-.7, 1.02, .25, .15), (-.1, .98, .22, .14), (.5, 1.03, .24, .15), (1.0, 1.17, .26, .15),
          (1.5, 1.27, .25, .12), (2.0, 1.27, .19, .08), (2.38, 1.17, .09, .04), (2.56, 1.08, .012, .012)], DARK, n=16)
    # Reactor pod slung under the spine.
    loft([(-1.02, .6, .05, .05), (-.8, .57, .2, .2), (-.45, .55, .29, .27), (.35, .55, .29, .27),
          (.75, .58, .2, .2), (.98, .62, .05, .05)], DARK, n=16)
    # Exposed core: bright cylinder with ribs cut across it.
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=32, radius1=.165, radius2=.165, depth=.98)
    for v in bm.verts:
        v.co = Vector((v.co.x * 1.04, v.co.z - .05, v.co.y + .55))
    # Sits proud of the pod's flanks so it reads from the side.
    bmesh.ops.scale(bm, vec=(1.95, 1, 1.0), verts=bm.verts, space=Matrix.Translation((0, 0, -.55)))
    to_object(bm, "core", GLOW, part="body")
    for y in (-.42, -.2, .02, .24):
        box((0, y, .55), (.66, .05, .5), CHROME)
    for side in (-1, 1):
        # Swing arms reach to the stationary bearing ring on each wheel.
        plate([(.75, .6), (1.15, .78), (1.74, .78), (1.74, .66), (1.2, .58), (.8, .42)], side * .225, .05, DARK)
        plate([(-.75, .6), (-1.15, .8), (-1.74, .8), (-1.74, .68), (-1.2, .58), (-.8, .42)], side * .225, .05, DARK)
        lathe(ellipse(side * .225, .34, .03, .045, 10), (0, 1.72, .56), CHROME, segs=72)
        lathe(ellipse(side * .225, .34, .03, .045, 10), (0, -1.72, .56), CHROME, segs=72)
        # Twin swept tail fins, glowing on the trailing edge.
        plate([(-1.38, 1.3), (-1.95, 1.42), (-2.7, 1.86), (-2.56, 1.9), (-1.9, 1.62), (-1.42, 1.46)], side * .17, .03, DARK)
        loft([(-1.95, 1.47, .012, .012), (-2.2, 1.6, .016, .016), (-2.62, 1.86, .012, .012)], GLOW, n=8, subsurf=0, x=side * .17)
        # Flank armour with a running light.
        plate([(-1.05, .95), (-.3, .72), (.55, .72), (1.25, 1.02), (1.6, 1.18), (1.25, 1.14), (.45, .86), (-.3, .88)], side * .26, .035, CHROME)
        loft([(-.3, .8, .01, .02), (.45, .79, .01, .02), (1.2, 1.08, .01, .015)], GLOW, n=8, subsurf=0, x=side * .282)
    # Delta wings and canards give the overhead view its arrowhead silhouette.
    for side in (-1, 1):
        wing([(side * .22, 1.0), (side * .86, -1.5), (side * .9, -2.1), (side * .62, -1.72), (side * .22, -1.25)], 1.14, .05, DARK)
        wing([(side * .86, -1.5), (side * .9, -2.1), (side * .84, -2.0), (side * .8, -1.5), (side * .2, .92), (side * .22, 1.0)], 1.17, .03, GLOW)
        wing([(side * .22, 2.1), (side * .5, 1.5), (side * .52, 1.22), (side * .22, 1.42)], 1.2, .04, DARK)
        wing([(side * .5, 1.5), (side * .52, 1.22), (side * .47, 1.28), (side * .45, 1.5), (side * .2, 2.05), (side * .22, 2.1)], 1.23, .025, GLOW)
    wing([(-.11, 1.9), (.11, 1.9), (.15, 1.0), (.15, -.4), (0, -1.1), (-.15, -.4), (-.15, 1.0)], 1.44, .02, GLOW)
    # Dorsal light strip, nose to tail.
    loft([(-2.3, 1.46, .022, .012), (-1.25, 1.34, .022, .012), (-.7, 1.18, .022, .012), (-.1, 1.13, .022, .012),
          (.5, 1.19, .022, .012), (1.0, 1.33, .022, .012), (1.5, 1.4, .022, .012), (2.0, 1.36, .018, .012),
          (2.42, 1.2, .012, .01)], GLOW, n=8)
    # Tail emitter: the wall leaves the bike here.
    box((0, -2.46, 1.26), (.34, .05, .05), GLOW)
    box((0, -2.46, .82), (.04, .05, .84), GLOW)
    plate([(-2.2, 1.34), (-2.5, 1.3), (-2.5, .4), (-2.34, .4)], 0, .05, DARK)


def build_pylon():
    # Tapered arena marker with light slits. Instanced around the perimeter.
    bm = bmesh.new()
    rings = []
    for z, r in ((0, 3.0), (3, 2.3), (34, .8), (40, .02)):
        rings.append([bm.verts.new((r * math.cos(a), r * math.sin(a), z)) for a in (math.pi / 4 + k * math.pi / 2 for k in range(4))])
    for a, b in zip(rings, rings[1:]):
        for i in range(4):
            j = (i + 1) % 4
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bm.faces.new(rings[0][::-1])
    to_object(bm, "pylon", DARK, part="body")
    for k in range(4):
        a = math.pi / 2 * k
        ca, sa = math.cos(a), math.sin(a)
        bm = bmesh.new()
        ring0 = []
        for off in (-.1, .1):
            ring0.append(bm.verts.new((ca * 1.98 - sa * off * 1.6, sa * 1.98 + ca * off * 1.6, 5)))
        for off in (.1, -.1):
            ring0.append(bm.verts.new((ca * .78 - sa * off, sa * .78 + ca * off, 34.5)))
        bm.faces.new(ring0)
        to_object(bm, "slit", GLOW, part="body")


def export(path):
    deps = bpy.context.evaluated_depsgraph_get()
    parts = {}
    for ob in bpy.context.scene.objects:
        if ob.type != "MESH":
            continue
        me = bpy.data.meshes.new_from_object(ob.evaluated_get(deps))
        bm = bmesh.new()
        bm.from_mesh(me)
        for e in bm.edges:
            if len(e.link_faces) == 2 and e.calc_face_angle(0) > SHARP_ANGLE:
                e.smooth = False
        bm.to_mesh(me)
        bm.free()
        me.calc_loop_triangles()
        cn = me.corner_normals
        store = parts.setdefault(ob["part"], {"v": [], "i": [], "map": {}})
        for t in me.loop_triangles:
            ids = []
            for k in range(3):
                vi = me.loops[t.loops[k]].vertex_index
                p = ob.matrix_world @ me.vertices[vi].co
                n = cn[t.loops[k]].vector
                # Blender +Y forward / +Z up → engine -Z forward / +Y up (a pure rotation).
                key = (round(p.x, 4), round(p.z, 4), round(-p.y, 4), round(n.x, 3), round(n.z, 3), round(-n.y, 3), t.material_index)
                idx = store["map"].get(key)
                if idx is None:
                    idx = len(store["v"])
                    store["map"][key] = idx
                    store["v"].append((p.x, p.z, -p.y, n.x, n.z, -n.y, float(t.material_index)))
                ids.append(idx)
            store["i"].extend(ids)
        bpy.data.meshes.remove(me)
    pivots = {"wheelF": (0, .56, -1.72), "wheelR": (0, .56, 1.72)}
    with open(path, "wb") as f:
        f.write(b"WKLM")
        f.write(struct.pack("<II", 1, len(parts)))
        for name, s in parts.items():
            f.write(name.encode().ljust(16, b"\0"))
            f.write(struct.pack("<II3f", len(s["v"]), len(s["i"]), *pivots.get(name, (0, 0, 0))))
            for v in s["v"]:
                f.write(struct.pack("<7f", *v))
            f.write(struct.pack("<%dI" % len(s["i"]), *s["i"]))
    print("EXPORT", path, {k: (len(v["v"]), len(v["i"]) // 3) for k, v in parts.items()})


def clear_scene():
    for ob in list(bpy.context.scene.objects):
        bpy.data.objects.remove(ob)


def thumbnail(path):
    sc = bpy.context.scene
    bpy.ops.mesh.primitive_plane_add(size=80, location=(0, 0, 0))
    floor = bpy.context.object
    floor["part"] = "floor"
    m = bpy.data.materials.new("floor")
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (.004, .005, .008, 1)
    b.inputs["Metallic"].default_value = .4
    b.inputs["Roughness"].default_value = .14
    floor.data.materials.append(m)
    cam = bpy.data.cameras.new("c")
    cam.lens = 55
    co = bpy.data.objects.new("c", cam)
    sc.collection.objects.link(co)
    co.location = (6.4, 3.0, 1.15)
    d = Vector((0, .1, .74)) - co.location
    co.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    sc.camera = co
    for loc, col, e in (((3, -3, 5), (.5, .8, 1), 900), ((-4, 2, 3), (.1, 1, .5), 500)):
        l = bpy.data.lights.new("l", "AREA")
        l.size, l.color, l.energy = 5, col, e
        lo = bpy.data.objects.new("l", l)
        sc.collection.objects.link(lo)
        lo.location = loc
        lo.rotation_euler = (Vector((0, 0, .6)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
    w = bpy.data.worlds.new("w")
    w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (.002, .004, .01, 1)
    sc.world = w
    sc.render.engine = "BLENDER_EEVEE"
    sc.render.resolution_x, sc.render.resolution_y = 1200, 750
    sc.render.filepath = path
    sc.render.image_settings.file_format = "PNG"
    bpy.ops.render.render(write_still=True)


os.makedirs(OUT, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
MATS = materials()
build_runner()
export(os.path.join(OUT, "runner.mesh"))
thumbnail(os.path.join(OUT, "runner-render.png"))
clear_scene()
build_pylon()
export(os.path.join(OUT, "pylon.mesh"))
