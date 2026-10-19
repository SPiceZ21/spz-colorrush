"""Write one flat-colour DDS per Color Rush colour.

Sollumz refuses to embed anything but DDS into a .ytd, so the PNGs are replaced
with uncompressed A8R8G8B8 DDS. At 64x64 that is 16 KB each -- irrelevant next
to DXT compression savings, and it avoids a DXT encoder dependency entirely
while keeping the colour byte-exact against Config.Colors.

Includes the full mip chain (64 down to 1): GTA expects mips on world textures,
and without them the slabs shimmer badly at distance.
"""
import os, struct

OUT = r"E:\spz-race-core\spz-colorrush\_source\textures"

COLORS = {
    "red":    (214,  40,  40),
    "blue":   ( 40, 110, 225),
    "green":  ( 40, 190,  90),
    "yellow": (240, 205,  50),
    "orange": (240, 130,  35),
    "purple": (150,  70, 210),
}

SIZE = 64
BORDER = 3

# DDS header flags
DDSD_CAPS, DDSD_HEIGHT, DDSD_WIDTH, DDSD_PITCH = 0x1, 0x2, 0x4, 0x8
DDSD_PIXELFORMAT, DDSD_MIPMAPCOUNT = 0x1000, 0x20000
DDPF_ALPHAPIXELS, DDPF_RGB = 0x1, 0x40
DDSCAPS_COMPLEX, DDSCAPS_TEXTURE, DDSCAPS_MIPMAP = 0x8, 0x1000, 0x400


def mip_levels(size):
    n, s = [], size
    while s >= 1:
        n.append(s)
        s //= 2
    return n


def surface(size, rgb, with_border):
    """BGRA bytes for one mip level."""
    r, g, b = rgb
    dark = (int(r * 0.72), int(g * 0.72), int(b * 0.72))
    px = bytearray()
    for y in range(size):
        for x in range(size):
            edge = with_border and (x < BORDER or y < BORDER
                                    or x >= size - BORDER or y >= size - BORDER)
            cr, cg, cb = dark if edge else (r, g, b)
            px += bytes((cb, cg, cr, 255))      # B, G, R, A
    return bytes(px)


def write_dds(path, rgb, size=SIZE):
    levels = mip_levels(size)

    header = b"DDS "
    header += struct.pack(
        "<IIIIIII",
        124,                                                        # dwSize
        DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PITCH
        | DDSD_PIXELFORMAT | DDSD_MIPMAPCOUNT,                      # dwFlags
        size, size,                                                 # height, width
        size * 4,                                                   # pitch
        0,                                                          # depth
        len(levels),                                                # mipMapCount
    )
    header += b"\x00" * 44                                          # dwReserved1[11]
    header += struct.pack(
        "<IIIIIIII",
        32,                                                         # ddspf.dwSize
        DDPF_RGB | DDPF_ALPHAPIXELS,                                # ddspf.dwFlags
        0,                                                          # dwFourCC
        32,                                                         # RGBBitCount
        0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000,             # R, G, B, A masks
    )
    header += struct.pack(
        "<IIIII",
        DDSCAPS_TEXTURE | DDSCAPS_COMPLEX | DDSCAPS_MIPMAP,         # dwCaps
        0, 0, 0, 0,
    )
    assert len(header) == 128, len(header)

    body = b"".join(surface(s, rgb, with_border=(s >= 16)) for s in levels)
    with open(path, "wb") as f:
        f.write(header + body)
    return len(header) + len(body), levels


os.makedirs(OUT, exist_ok=True)
for name, rgb in COLORS.items():
    fn = os.path.join(OUT, "spz_cr_tile_%s_d.dds" % name)
    n, levels = write_dds(fn, rgb)
    print("%-32s %-16s %6d bytes  %d mips" % (os.path.basename(fn), rgb, n, len(levels)))

# the PNGs are superseded; drop them so nothing picks up the wrong file
removed = 0
for name in COLORS:
    p = os.path.join(OUT, "spz_cr_tile_%s_d.png" % name)
    if os.path.exists(p):
        os.remove(p)
        removed += 1
print("\nwrote %d DDS, removed %d superseded PNG" % (len(COLORS), removed))
