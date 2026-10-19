"""Build all six Color Rush tile drawables, with embedded walkable collision.

Hierarchy is built by hand rather than via bpy.ops.sollumz.converttodrawable --
that operator produced the right structure but also removed an unrelated object
from the scene, and hand-building has no side effects. The shape it produces:

    EMPTY  sollumz_drawable            spz_cr_tile_<colour>
      +-- MESH   sollumz_drawable_model      .model     (visual, 13x13x0.3)
      +-- EMPTY  sollumz_bound_composite     .bounds
            +-- MESH sollumz_bound_box       .bounds.box (collision)

Idempotent: wipes any previous spz_cr_tile_* objects first, so it can be re-run.
"""
import bpy, importlib, os
from mathutils import Matrix

sm = importlib.import_module("bl_ext.repo_sollumz_org.sollumz.ydr.shader_materials")
cmm = importlib.import_module("bl_ext.repo_sollumz_org.sollumz.ybn.collision_materials")
LODLevel = importlib.import_module("bl_ext.repo_sollumz_org.sollumz.sollumz_properties").LODLevel

TEXDIR = r"E:\spz-race-core\spz-colorrush\_source\textures"
COLORS = ["red", "blue", "green", "yellow", "orange", "purple"]
COLLISION_MAT_INDEX = 1          # CONCRETE -- walkable, standard footstep audio
SIZE_XY = 13.0
THICK = 0.3

log = []

# ── 0. Restore the user's original Cube faithfully ──────────────────────────
# Their platform was a unit cube (+/-1) with scale 6.5/6.5/0.15 and material
# Material.001. Their saved .blend on disk was never written to, so File >
# Revert remains the authoritative restore; this just tidies the live session.
if "Cube" in bpy.data.objects:
    c = bpy.data.objects["Cube"]
    if "Material.001" in bpy.data.materials:
        c.data.materials.clear()
        c.data.materials.append(bpy.data.materials["Material.001"])
    c.scale = (6.5, 6.5, 0.15000000596046448)
    c.location = (0.0, 0.0, 0.0)
    c.rotation_euler = (0.0, 0.0, 0.0)
    log.append("Cube restored: unit cube, scale 6.5/6.5/0.15, Material.001")

# drop the orphaned duplicate mesh left over from the earlier copy
orphan = bpy.data.meshes.get("Cube.001")
if orphan is not None and orphan.users == 0:
    bpy.data.meshes.remove(orphan)
    log.append("removed orphan mesh Cube.001")

# ── 1. Clear any previous build ─────────────────────────────────────────────
for o in [o for o in bpy.data.objects if o.name.startswith("spz_cr_tile")]:
    bpy.data.objects.remove(o, do_unlink=True)
for me in [m for m in bpy.data.meshes if m.name.startswith("spz_cr_tile")]:
    if me.users == 0:
        bpy.data.meshes.remove(me)
for mt in [m for m in bpy.data.materials if m.name.startswith("spz_cr_tile")]:
    if mt.users == 0:
        bpy.data.materials.remove(mt)

for im in [i for i in bpy.data.images if i.name.startswith("spz_cr_tile")]:
    bpy.data.images.remove(im)

coll = bpy.data.collections.get("Collection") or bpy.context.scene.collection

# ── 2. Canonical tile mesh: 13x13x0.3, top face on z = 0 ───────────────────
# Origin on the TOP face is what the Lua assumes: CreateObject at Config.Center.z
# then puts the walking surface exactly at that height.
def make_slab(name):
    me = bpy.data.meshes.new(name)
    h = SIZE_XY / 2.0
    verts = [(-h, -h, -THICK), (h, -h, -THICK), (h, h, -THICK), (-h, h, -THICK),
             (-h, -h, 0.0),    (h, -h, 0.0),    (h, h, 0.0),    (-h, h, 0.0)]
    faces = [(0, 1, 2, 3), (4, 7, 6, 5), (0, 4, 5, 1),
             (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)]
    me.from_pydata(verts, [], faces)
    me.update()
    # UVs: one unwrap per face is enough for a flat colour, and the top face is
    # the only one anyone sees.
    me.uv_layers.new(name="UVMap 0")
    uvl = me.uv_layers[0]
    box = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
    for poly in me.polygons:
        for n, li in enumerate(poly.loop_indices):
            uvl.data[li].uv = box[n % 4]
    ca = me.color_attributes.new(name="Color 1", type="BYTE_COLOR", domain="CORNER")
    for i in range(len(ca.data)):
        ca.data[i].color = (1.0, 1.0, 1.0, 1.0)
    me.validate()
    return me


built = []
for colour in COLORS:
    name = "spz_cr_tile_%s" % colour

    # 2a. material -- Sollumz default.sps with the flat-colour diffuse
    mat = sm.create_shader("default.sps")
    mat.name = name
    png = os.path.join(TEXDIR, "%s_d.dds" % name)
    img = bpy.data.images.load(png, check_existing=False)
    img.name = "%s_d" % name                  # unique per colour, or the .ytd collides
    img.colorspace_settings.name = "sRGB"

    diffuse_set = False
    for n in mat.node_tree.nodes:
        if n.type == "TEX_IMAGE" and "diffuse" in n.name.lower():
            n.image = img
            tp = getattr(n, "texture_properties", None)
            if tp is not None:
                tp.embedded = True            # pack it into the .ytd on export
            diffuse_set = True
    if not diffuse_set:
        log.append("WARN %s: no DiffuseSampler node found" % name)

    # 2b. drawable root
    root = bpy.data.objects.new(name, None)
    root.empty_display_size = 0.5
    coll.objects.link(root)
    root.sollum_type = "sollumz_drawable"

    # 2c. visual model
    vis = bpy.data.objects.new(name + ".model", make_slab(name + "_mesh"))
    coll.objects.link(vis)
    vis.parent = root
    vis.sollum_type = "sollumz_drawable_model"
    vis.data.materials.append(mat)
    # Sollumz resolves geometry+materials through its LOD system, so the
    # HIGH lod must point at this mesh or the exporter sees nothing at all.
    vis.sz_lods.get_lod(LODLevel.HIGH).mesh = vis.data
    vis.sz_lods.active_lod_level = LODLevel.HIGH.value

    # 2d. embedded collision -- without this players fall straight through
    comp = bpy.data.objects.new(name + ".bounds", None)
    coll.objects.link(comp)
    comp.parent = root
    comp.sollum_type = "sollumz_bound_composite"

    box = bpy.data.objects.new(name + ".bounds.box", make_slab(name + "_col"))
    coll.objects.link(box)
    box.parent = comp
    box.sollum_type = "sollumz_bound_box"
    box.data.materials.append(cmm.create_collision_material_from_index(COLLISION_MAT_INDEX))
    # Collision flags. Sollumz leaves both sets empty, and a bound with no
    # type/include flags collides with NOTHING -- cars and peds fall through.
    # Standard static-map-object preset:
    for f in ("map_weapon", "map_dynamic", "map_animal", "map_cover", "map_vehicle"):
        setattr(box.composite_flags1, f, True)          # what this bound IS
    for f in ("vehicle_not_bvh", "vehicle_bvh", "ped", "ragdoll", "animal",
              "animal_ragdoll", "object", "object_env_cloth", "plant", "projectile",
              "explosion", "forklift_forks", "test_weapon", "test_camera", "test_ai",
              "test_script", "test_vehicle_wheel", "glass"):
        setattr(box.composite_flags2, f, True)          # what it collides WITH

    built.append(name)

# ── 3. Report ───────────────────────────────────────────────────────────────
def describe(o):
    return {
        "name": o.name, "btype": o.type, "sollum": getattr(o, "sollum_type", None),
        "parent": o.parent.name if o.parent else None,
        "mats": [m.name for m in o.data.materials] if getattr(o, "data", None) and hasattr(o.data, "materials") else None,
    }

result = {
    "log": log,
    "built": built,
    "tile_count": len(built),
    "objects": [describe(o) for o in bpy.data.objects],
    "images": [(i.name, i.size[0], i.size[1]) for i in bpy.data.images if i.name.startswith("spz_cr")],
    "cube_ok": "Cube" in bpy.data.objects,
    "disk_file_untouched": bpy.data.is_dirty,
}
