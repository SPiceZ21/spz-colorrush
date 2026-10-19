"""Export the six tile drawables as native .ydr + embedded .ytd into the
resource's stream/ folder.

NATIVE  -> real binary .ydr (not .ydr.xml, which FiveM cannot stream)
GEN8    -> GTA V legacy asset version, which is what FiveM loads
"""
import bpy, os, glob

OUT = r"E:\spz-race-core\spz-colorrush\stream"
os.makedirs(OUT, exist_ok=True)

before = set(glob.glob(os.path.join(OUT, "*")))

roots = [o for o in bpy.data.objects
         if getattr(o, "sollum_type", None) == "sollumz_drawable"
         and o.name.startswith("spz_cr_tile")]

bpy.ops.object.select_all(action="DESELECT")
for r in roots:
    r.select_set(True)
    for c in r.children_recursive:
        c.select_set(True)
bpy.context.view_layer.objects.active = roots[0] if roots else None

err = None
try:
    bpy.ops.sollumz.export_assets(
        directory=OUT,
        target_formats={"NATIVE"},
        target_versions={"GEN8"},
        limit_to_selected=True,
        export_ytds=True,
        export_ytds_include="SELECTED",
        apply_transforms=False,
        direct_export=True,
        use_custom_settings=True,
    )
except Exception as e:
    err = repr(e)

after = sorted(glob.glob(os.path.join(OUT, "*")))
result = {
    "selected_roots": [r.name for r in roots],
    "export_error": err,
    "new_files": [(os.path.basename(f), os.path.getsize(f)) for f in after if f not in before],
    "all_files_in_stream": [(os.path.basename(f), os.path.getsize(f)) for f in after],
}
