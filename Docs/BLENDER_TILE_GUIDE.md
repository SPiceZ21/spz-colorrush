# Color Rush — tile models: what was built and how to rebuild it

The six tile props are **already built and exported** into [`stream/`](../stream).
This is the record of how, so it can be re-run or retuned.

## What shipped

| File | Contents |
|---|---|
| `stream/spz_cr_tile_{red,blue,green,yellow,orange,purple}.ydr` | Six drawables, ~990 B each on disk, inflating to 40,960 B. Version 165 (GEN8), `RSC7` header. |
| `_source/spz_cr_tiles.blend` | The Blender source for all six. |
| `_source/textures/*.dds` | The six flat-colour diffuse textures (embedded in the `.ydr`, kept here as source). |
| `_source/pipeline/*.py` | The scripts that generated the above. |

Each tile is a **13 m × 13 m × 0.3 m** slab — one *section* of the platform, not
a small mosaic tile. 5 × 5 of them makes the 65 m × 65 m arena.

## Why six models instead of one tinted one

`SET_OBJECT_TINT_INDEX` only works on props authored with a tint palette, and it
buys nothing here: every section has to be its own entity regardless, because
they despawn individually. One mesh exported six times is the same modelling
work with no native to fight and no palette to author.

## The decisions baked into the models

- **Origin sits on the top face** (mesh spans z −0.3 → 0.0). The Lua spawns tiles
  at `Config.Center.z`, so this puts the walking surface exactly at that height.
  If the origin were centred, every section would float half its thickness high.
- **Footprint is exactly `Config.TileSize`** (13.0 m). Any mismatch gaps or overlaps.
- **Embedded collision**: a `sollumz_bound_composite` → `sollumz_bound_box` child
  with the `CONCRETE` collision material. Without it players fall straight through.
- **Textures are uncompressed A8R8G8B8 DDS with a full 7-level mip chain.** Mips
  matter — without them 25 flat slabs shimmer badly at distance. Written by hand
  (`make_dds.py`) rather than through Blender's colour management so the bytes
  match `Config.Colors` exactly; the colour a player sees has to match the HUD
  banner telling them where to run.
- **A 3 px darker border** on each texture so the seam between two adjacent
  same-colour sections is readable instead of one flat sheet.

## Three Sollumz gotchas this hit

Worth writing down, because none of them are obvious and all three fail quietly:

1. **Sollumz reads geometry and materials through its LOD system**, not
   `object.data.materials`. A hand-built `sollumz_drawable_model` whose
   `sz_lods` was never populated exports as *"has no Sollumz materials"* even
   with the material clearly assigned. Fix: set
   `obj.sz_lods.get_lod(LODLevel.HIGH).mesh = obj.data`.
2. **The UV layer must be named `UVMap 0`**, not Blender's default `UVMap`, and
   a `Color 1` byte-colour attribute must exist on the mesh (white = no tint).
   Both only produce warnings, and the model exports looking fine but renders wrong.
3. **Only DDS can be embedded.** A PNG is silently skipped, leaving an untextured
   drawable that still exports "successfully".

`bpy.ops.sollumz.converttodrawable()` sets up (1) correctly, but it also removed
an unrelated object from the scene when used here, so `build_all.py` constructs
the hierarchy by hand instead:

```
EMPTY  sollumz_drawable            spz_cr_tile_<colour>
  ├── MESH   sollumz_drawable_model      .model        (visual)
  └── EMPTY  sollumz_bound_composite     .bounds
        └── MESH sollumz_bound_box       .bounds.box   (collision)
```

## Rebuilding

Blender must be running with the MCP extension listening on `127.0.0.1:9876`
(Blender 5.2's official `mcp` extension, plus Sollumz). Then, from `_source/pipeline/`:

```bash
python make_dds.py && python bl.py build_all.py && python bl.py export_tiles.py
```

`build_all.py` is idempotent — it wipes any previous `spz_cr_tile*` objects,
meshes, materials and images first, so it is safe to re-run.

To change a colour, edit the RGB in **both** `make_dds.py` and `Config.Colors`
(they must agree), then re-run the three commands.

To change the section size, edit `SIZE_XY` in `build_all.py` and `Config.TileSize`
together, then re-run. `Config.Grid` × `Config.TileSize` is the arena width.

## Verifying in game

```bash
restart spz-colorrush
```

Each failure mode looks distinct:

- **Tiles missing entirely** → not streamed. The client names the offending model
  and refuses to start the round.
- **Players fall through visible tiles** → collision bound missing.
- **Players sink to their knees / float** → origin is not on the top face.
- **Seams or overlaps between sections** → footprint ≠ `Config.TileSize`.
- **Every section the same colour** → duplicate texture names across the `.ydr`s.
  Verified not to be the case: each one embeds its own uniquely-named texture.
- **Untextured grey slabs** → the DDS did not embed; check for the PNG warning.

## Is a platform base model needed?

No. The sections *are* the walkable surface and the gaps are meant to be holes.
A base would only be for looks from underneath.
