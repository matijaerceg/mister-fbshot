#!/bin/sh
# fbshot - save the MiSTer's Linux framebuffer (/dev/fb0) as a PNG.
#
# The built-in screenshot (Win+PrtScn) grabs the core's video out of the
# scaler's buffer in DDR. It never looks at /dev/fb0, so anything that draws
# to the framebuffer layer - the MiSTer menu, MisterZine, other fb apps -
# cannot be captured with it. This grabs that layer instead.
#
#   sh fbshot.sh                 save to /media/fat/screenshots/framebuffer/
#   sh fbshot.sh -o shot.png     save somewhere else
#   sh fbshot.sh -o -            write the PNG to stdout
#   sh fbshot.sh -s 3            enlarge 3x, nearest neighbour
#   sh fbshot.sh -d 5            wait 5 seconds, then capture
#
# Needs nothing but the python3 already on every recent MiSTer image.

set -e

PY=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
if [ -z "$PY" ]; then
	echo "fbshot: no python3 on this system" >&2
	exit 1
fi

exec "$PY" - "$@" <<'FBSHOT_PY'
import os
import stat
import struct
import sys
import time
import zlib

try:
    import fcntl  # absent on Windows, where only --dev FILE --geom works
except ImportError:
    fcntl = None

FBIOGET_VSCREENINFO = 0x4600
FBIOGET_FSCREENINFO = 0x4602
FBIO_WAITFORVSYNC = 0x40044620

# (bit offset, width) per channel when nothing better is known.
RGB888 = ((16, 8), (8, 8), (0, 8))
RGB565 = ((11, 5), (5, 6), (0, 5))

USAGE = """usage: fbshot [-o FILE|-] [-s N] [-d SECONDS] [--dev PATH]
              [--geom WxHxBPP] [--stride BYTES] [--rgb R,G,B]

  -o FILE   where to write the PNG; - means stdout
            (default: /media/fat/screenshots/framebuffer/fb-<date>.png)
  -s N      enlarge by N, nearest neighbour (default 1)
  -d SECS   sleep this long before capturing
  --dev     framebuffer device, or a raw dump to convert (default /dev/fb0)
  --geom    override the geometry, e.g. 320x240x32 (needed with a raw dump;
            16bpp dumps are assumed to be RGB565)
  --stride  bytes per row, if it is not width * bytes-per-pixel
  --rgb     byte order within a 32bpp pixel, e.g. 2,1,0 for XRGB
"""


def die(msg):
    sys.stderr.write("fbshot: %s\n" % msg)
    raise SystemExit(1)


def parse_args(argv):
    a = {"out": None, "scale": 1, "delay": 0.0, "dev": "/dev/fb0",
         "geom": None, "stride": None, "rgb": None}
    i = 0
    while i < len(argv):
        f = argv[i]
        v = argv[i + 1] if i + 1 < len(argv) else None
        if f in ("-h", "--help"):
            sys.stderr.write(USAGE)
            raise SystemExit(0)
        elif f == "-o" and v is not None:
            a["out"] = v
        elif f == "-s" and v is not None:
            a["scale"] = int(v)
        elif f == "-d" and v is not None:
            a["delay"] = float(v)
        elif f == "--dev" and v is not None:
            a["dev"] = v
        elif f == "--geom" and v is not None:
            a["geom"] = v
        elif f == "--stride" and v is not None:
            a["stride"] = int(v)
        elif f == "--rgb" and v is not None:
            a["rgb"] = v
        else:
            sys.stderr.write(USAGE)
            die("unknown or incomplete option: %s" % f)
        i += 2
    if a["scale"] < 1:
        die("scale must be 1 or more")
    return a


def geometry_from_ioctl(fd):
    """fb_var_screeninfo is 160 bytes and fb_fix_screeninfo 68 on arm32."""
    var = struct.unpack("<40I", fcntl.ioctl(fd, FBIOGET_VSCREENINFO, bytes(160)))
    fix = fcntl.ioctl(fd, FBIOGET_FSCREENINFO, bytes(68))
    bpp = var[6]
    # Channel positions exactly as the kernel reports them: bit offset and
    # width inside the little-endian pixel word. This is what makes 565,
    # 1555 and their red/blue-swapped variants come out right rather than
    # being assumed - MiSTer's fb_cmd can select any of them.
    bits = ((var[8], var[9]), (var[11], var[12]), (var[14], var[15]))
    if min(b[1] for b in bits) == 0:  # driver left the bitfields empty
        bits = RGB888 if bpp == 32 else RGB565
    return {
        "w": var[0], "h": var[1], "xoff": var[4], "yoff": var[5], "bpp": bpp,
        "bits": bits,
        "stride": struct.unpack_from("<I", fix, 44)[0] or var[2] * (bpp // 8),
    }


def geometry_from_sysfs(dev):
    """Fallback for kernels whose fb driver refuses the ioctls."""
    base = "/sys/class/graphics/%s" % os.path.basename(dev)
    with open(base + "/virtual_size") as f:
        w, h = [int(n) for n in f.read().strip().split(",")]
    with open(base + "/bits_per_pixel") as f:
        bpp = int(f.read().strip())
    with open(base + "/stride") as f:
        stride = int(f.read().strip())
    # sysfs does not report the channel layout; assume the MiSTer's default.
    return {"w": w, "h": h, "xoff": 0, "yoff": 0, "bpp": bpp,
            "bits": RGB888 if bpp == 32 else RGB565,
            "stride": stride or w * (bpp // 8)}


def geometry(fd, dev, a):
    if a["geom"]:
        try:
            w, h, bpp = [int(n) for n in a["geom"].lower().split("x")]
        except ValueError:
            die("--geom wants WxHxBPP, e.g. 320x240x32")
        g = {"w": w, "h": h, "xoff": 0, "yoff": 0, "bpp": bpp,
             "bits": RGB888 if bpp == 32 else RGB565,
             "stride": w * (bpp // 8)}
    elif fd is None:
        die("--geom is required when reading a plain file")
    else:
        try:
            if fcntl is None:
                raise OSError("no fcntl on this platform")
            g = geometry_from_ioctl(fd)
        except (OSError, struct.error) as e:
            sys.stderr.write("fbshot: ioctl failed (%s); trying sysfs\n" % e)
            try:
                g = geometry_from_sysfs(dev)
            except (OSError, ValueError) as e2:
                die("cannot read the geometry (%s); pass --geom" % e2)
    if g["bpp"] not in (16, 32):
        die("unsupported depth %d bpp" % g["bpp"])
    if g["w"] < 1 or g["h"] < 1:
        die("framebuffer reports %dx%d - nothing to capture" % (g["w"], g["h"]))
    if a["stride"]:
        g["stride"] = a["stride"]
    if a["rgb"]:
        if g["bpp"] != 32:
            die("--rgb applies to 32bpp only; 16bpp uses the reported bitfields")
        try:
            r, gr, b = [int(n) for n in a["rgb"].split(",")]
        except ValueError:
            die("--rgb wants three byte indices, e.g. 2,1,0")
        g["bits"] = ((r * 8, 8), (gr * 8, 8), (b * 8, 8))
    return g


def read_frame(fd, g):
    want = g["stride"] * g["h"]
    os.lseek(fd, g["yoff"] * g["stride"], os.SEEK_SET)
    buf = bytearray()
    while len(buf) < want:
        chunk = os.read(fd, want - len(buf))
        if not chunk:
            break
        buf += chunk
    if len(buf) < want:
        die("short read: got %d of %d bytes (wrong --geom or --stride?)"
            % (len(buf), want))
    return bytes(buf)


def rows_rgb(buf, g):
    """One RGB row per line of the visible area."""
    w, h, stride = g["w"], g["h"], g["stride"]
    px = g["bpp"] // 8
    x0 = g["xoff"] * px
    (ro, rl), (go, gl), (bo, bl) = g["bits"]
    for y in range(h):
        line = buf[y * stride + x0: y * stride + x0 + w * px]
        row = bytearray(w * 3)
        if px == 4:
            # Three C-speed strided copies beat a per-pixel loop by a mile.
            row[0::3] = line[ro // 8::4]
            row[1::3] = line[go // 8::4]
            row[2::3] = line[bo // 8::4]
        else:  # 16bpp bitfields: 565, 1555, or either with red and blue swapped
            rm, gm, bm = (1 << rl) - 1, (1 << gl) - 1, (1 << bl) - 1
            for i, p in enumerate(struct.unpack("<%dH" % w, line)):
                row[i * 3] = ((p >> ro) & rm) * 255 // rm
                row[i * 3 + 1] = ((p >> go) & gm) * 255 // gm
                row[i * 3 + 2] = ((p >> bo) & bm) * 255 // bm
        yield row


def scale_row(row, w, s):
    out = bytearray(w * s * 3)
    for c in range(3):
        for k in range(s):
            out[k * 3 + c:: s * 3] = row[c::3]
    return out


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data +
            struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def write_png(out, w, h, rows):
    out.write(b"\x89PNG\r\n\x1a\n")
    out.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
    # Compress row by row: a 1080p image never exists uncompressed in one
    # piece, which matters on a board with 512MB and a core running in it.
    co = zlib.compressobj(6)
    parts = []
    for row in rows:
        parts.append(co.compress(b"\0" + bytes(row)))  # filter: none
    parts.append(co.flush())
    out.write(chunk(b"IDAT", b"".join(parts)))
    out.write(chunk(b"IEND", b""))


def default_path():
    stamp = time.strftime("%Y%m%d-%H%M%S")
    if os.path.isdir("/media/fat"):
        return "/media/fat/screenshots/framebuffer/fb-%s.png" % stamp
    return "fb-%s.png" % stamp


def main(argv):
    a = parse_args(argv)
    if a["delay"] > 0:
        time.sleep(a["delay"])

    if not os.path.exists(a["dev"]):
        die("%s does not exist - is this a MiSTer?" % a["dev"])
    fd = os.open(a["dev"], os.O_RDONLY)
    try:
        # A character device is a framebuffer to ask; anything else is a dump
        # to convert. Going by the name would make fb.raw the wrong thing.
        is_fb = stat.S_ISCHR(os.fstat(fd).st_mode)
        g = geometry(fd if is_fb else None, a["dev"], a)
        if is_fb and fcntl is not None:
            try:  # land between frames when the driver offers it
                fcntl.ioctl(fd, FBIO_WAITFORVSYNC, struct.pack("I", 0))
            except OSError:
                pass
        buf = read_frame(fd, g)
    finally:
        os.close(fd)

    w, h, s = g["w"], g["h"], a["scale"]
    rows = rows_rgb(buf, g)
    if s > 1:
        rows = (scale_row(r, w, s) for r in rows for _ in range(s))

    dest = a["out"] or default_path()
    if dest == "-":
        out = getattr(sys.stdout, "buffer", sys.stdout)
        write_png(out, w * s, h * s, rows)
        out.flush()
    else:
        parent = os.path.dirname(os.path.abspath(dest))
        if not os.path.isdir(parent):
            os.makedirs(parent)
        tmp = dest + ".part"
        with open(tmp, "wb") as out:
            write_png(out, w * s, h * s, rows)
        os.rename(tmp, dest)
        sys.stderr.write("fbshot: %s (%dx%d %dbpp -> %dx%d)\n"
                         % (dest, g["w"], g["h"], g["bpp"], w * s, h * s))


main(sys.argv[1:])
FBSHOT_PY
