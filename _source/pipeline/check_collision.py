"""Re-import each exported tile and report whether its collision survived."""
import bpy, json, os
STREAM = r"E:\spz-race-core\spz-colorrush\stream"
out = {}
for f in sorted(os.listdir(STREAM)):
    if not f.endswith(".ydr"):
        continue
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    try:
        bpy.ops.sollumz.import_assets(directory=STREAM, files=[{"name": f}])
        box = next((o for o in bpy.data.objects if getattr(o, "sollum_type", "") == "sollumz_bound_box"), None)
        on = lambda fl: [k for k in fl.__annotations__ if getattr(fl, k, False) is True] if fl else []
        out[f] = {"box": bool(box),
                  "type_flags": on(box.composite_flags1) if box else None,
                  "include_flags": len(on(box.composite_flags2)) if box else None}
    except Exception as e:
        out[f] = "ERR " + repr(e)
print("SPZ_COLL", json.dumps(out))
