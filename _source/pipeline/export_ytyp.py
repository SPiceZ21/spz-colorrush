"""Build the tiles, export the .ydr drawables AND the .ytyp archetype file.

The .ytyp is what lets the game spawn the models: a .ydr in stream/ is only a
drawable, and CreateObject/RequestModel fail on a hash with no archetype.

Headless, no MCP socket needed:
    "C:\\Program Files\\Blender Foundation\\Blender 5.2\\blender.exe" -b ^
        --python E:\\spz-race-core\\spz-colorrush\\_source\\pipeline\\export_ytyp.py
"""
import bpy, os, glob, json, traceback

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = r"E:\spz-race-core\spz-colorrush\stream"
YTYP_NAME = "spz_colorrush"
REPORT = os.path.join(HERE, "export_report.json")

report = {}
try:
    # 1. tiles (idempotent) -- same builder as the MCP pipeline
    ns = {"__name__": "build_all"}
    exec(open(os.path.join(HERE, "build_all.py"), encoding="utf-8").read(), ns)
    report["built"] = ns.get("result", {}).get("built")

    # 1b. Textures in a SEPARATE .ytd per tile, not embedded in the .ydr: the
    # embedded route loaded as plain white in game. Each .ytd is named after
    # its tile, and the archetype's texture_dictionary points at it (below).
    txds = bpy.context.scene.sz_txds
    while len(txds.texture_dictionaries):
        txds.texture_dictionaries.remove(0)
    tex_of = {}
    for mat in bpy.data.materials:
        if not mat.name.startswith("spz_cr_tile") or not mat.node_tree:
            continue
        for n in mat.node_tree.nodes:
            if n.type == "TEX_IMAGE" and n.image is not None:
                tp = getattr(n, "texture_properties", None)
                if tp is not None:
                    tp.embedded = False
                tex_of[mat.name] = n.image
    for name, img in sorted(tex_of.items()):
        txd = txds.new_texture_dictionary(name)
        txd.new_texture(img)
    report["txds"] = [t.name for t in txds.texture_dictionaries]

    # 2. .ydr export -- same settings as export_tiles.py
    ns = {"__name__": "export_tiles"}
    exec(open(os.path.join(HERE, "export_tiles.py"), encoding="utf-8").read(), ns)
    report["ydr"] = ns.get("result")

    # 3. .ytyp: one BASE archetype per tile drawable
    scene = bpy.context.scene
    while len(scene.ytyps):
        scene.ytyps.remove(0)
    bpy.ops.sollumz.createytyp()
    ytyp = scene.ytyps[scene.ytyp_index]
    ytyp.name = YTYP_NAME

    roots = sorted((o for o in bpy.data.objects
                    if getattr(o, "sollum_type", None) == "sollumz_drawable"
                    and o.name.startswith("spz_cr_tile")), key=lambda o: o.name)
    for r in roots:
        a = ytyp.new_archetype()
        a.asset = r                 # update_asset fills asset_name / asset_type
        a.name = r.name
        a.lod_dist = 500.0          # arena is viewed from across the deck
        a.hd_texture_dist = 100.0
        a.texture_dictionary = r.name   # stream/<tile>.ytd
        # 13 x 13 x 0.3 slab, top face at z = 0
        a.bb_min = (-6.5, -6.5, -0.3)
        a.bb_max = (6.5, 6.5, 0.0)
        a.bs_center = (0.0, 0.0, -0.15)
        a.bs_radius = 9.2
    report["archetypes"] = [a.name for a in ytyp.archetypes]

    before = set(glob.glob(os.path.join(OUT, "*")))
    txds.texture_dictionaries.select_all() if hasattr(txds.texture_dictionaries, "select_all") else None
    bpy.ops.sollumz.export_ytd(
        directory=OUT,
        target_formats={"NATIVE"},
        target_versions={"GEN8"},
        direct_export=True,
        use_custom_settings=True,
    )
    bpy.ops.sollumz.export_ytyp_io(
        directory=OUT,
        target_formats={"NATIVE"},
        target_versions={"GEN8"},
        direct_export=True,
        use_custom_settings=True,
    )
    after = sorted(glob.glob(os.path.join(OUT, "*")))
    report["new_files"] = [(os.path.basename(f), os.path.getsize(f)) for f in after if f not in before]
    report["stream"] = [(os.path.basename(f), os.path.getsize(f)) for f in after]
except Exception:
    report["error"] = traceback.format_exc()

with open(REPORT, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, default=repr)
print("SPZ_REPORT", json.dumps(report, default=repr))
