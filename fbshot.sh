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
# Needs nothing but the python3 already on every current MiSTer image.

set -e

PY=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
if [ -z "$PY" ]; then
	echo "fbshot: no python3 on this system" >&2
	exit 1
fi

exec "$PY" - "$@" <<'FBSHOT_PY'
import os
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

USAGE = """usage: fbshot [-o FILE|-] [-s N] [-d SECONDS] [--dev PATH]
              [--geom WxHxBPP] [--rgb R,G,B]

  -o FILE   where to write the PNG; - means stdout
            (default: /media/fat/screenshots/framebuffer/fb-<date>.png)
  -s N      enlarge by N, nearest neighbour (default 1)
  -d SECS   sleep this long before capturing
  --dev     framebuffer device, or a raw dump to convert (default /dev/fb0)
  --geom    override the geometry, e.g. 320x240x32 (needed with a raw dump)
  --rgb     override the byte order within a pixel, e.g. 2,1,0 for ARGB
"""


def die(msg):
    sys.stderr.write("fbshot: %s\n" % msg)
    raise SystemExit(1)


def parse_args(argv):
    a = {"out": None, "scale": 1, "delay": 0.0, "dev": "/dev/fb0",
         "geom": None, "rgb": None}
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
    stride = struct.unpack_from("<I", fix, 44)[0]
    bpp = var[6]
    return {
        "w": var[0], "h": var[1], "xoff": var[4], "yoff": var[5], "bpp": bpp,
        # red/green/blue bit offsets; the pixel word is little-endian, so
        # offset 16 means the red byte sits third in memory.
        "r": var[8] // 8, "g": var[11] // 8, "b": var[14] // 8,
        "stride": stride or var[2] * (bpp // 8),
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
    # sysfs does not report the channel order; assume the MiSTer's ARGB.
    return {"w": w, "h": h, "xoff": 0, "yoff": 0, "bpp": bpp,
            "r": 2, "g": 1, "b": 0, "stride": stride or w * (bpp // 8)}


def geometry(fd, dev, override, rgb):
    if override:
        try:
            w, h, bpp = [int(n) for n in override.lower().split("x")]
        except ValueError:
            die("--geom wants WxHxBPP, e.g. 320x240x32")
        g = {"w": w, "h": h, "xoff": 0, "yoff": 0, "bpp": bpp,
             "r": 2, "g": 1, "b": 0, "stride": w * (bpp // 8)}
    elif fd is None:
        die("--geom is required when reading a plain file")
    else:
        try:
            if fcntl is None:
                raise OSError("no fcntl on this platform")
            g = geometry_from_ioctl(fd)
        except (OSError, struct.error) as e:
            sys.stderr.write("fbshot: ioctl failed (%s); trying sysfs\n" % e)
            g = geometry_from_sysfs(dev)
    if rgb:
        try:
            g["r"], g["g"], g["b"] = [int(n) for n in rgb.split(",")]
        except ValueError:
            die("--rgb wants three byte indices, e.g. 2,1,0")
    if g["bpp"] not in (16, 32):
        die("unsupported depth %d bpp" % g["bpp"])
    if g["w"] < 1 or g["h"] < 1:
        die("framebuffer reports %dx%d - nothing to capture" % (g["w"], g["h"]))
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
        die("short read: got %d of %d bytes" % (len(buf), want))
    return bytes(buf)


def rows_rgb(buf, g):
    """One RGB row per line of the visible area."""
    w, h, stride = g["w"], g["h"], g["stride"]
    px = g["bpp"] // 8
    x0 = g["xoff"] * px
    for y in range(h):
        line = buf[y * stride + x0: y * stride + x0 + w * px]
        row = bytearray(w * 3)
        if px == 4:
            # Three C-speed strided copies beat a per-pixel loop by a mile.
            row[0::3] = line[g["r"]::4]
            row[1::3] = line[g["g"]::4]
            row[2::3] = line[g["b"]::4]
        else:  # RGB565, little-endian
            for i, p in enumerate(struct.unpack("<%dH" % w, line)):
                row[i * 3] = ((p >> 11) & 0x1F) * 255 // 31
                row[i * 3 + 1] = ((p >> 5) & 0x3F) * 255 // 63
                row[i * 3 + 2] = (p & 0x1F) * 255 // 31
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
    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter: none
        raw += row
    out.write(b"\x89PNG\r\n\x1a\n")
    out.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
    out.write(chunk(b"IDAT", zlib.compress(bytes(raw), 6)))
    out.write(chunk(b"IEND", b""))


def default_path():
    stamp = time.strftime("%Y%m%d-%H%M%S")
    shots = "/media/fat/screenshots/framebuffer"
    if os.path.isdir("/media/fat"):
        return "%s/fb-%s.png" % (shots, stamp)
    return "fb-%s.png" % stamp


def main(argv):
    a = parse_args(argv)
    if a["delay"] > 0:
        time.sleep(a["delay"])

    if not os.path.exists(a["dev"]):
        die("%s does not exist - is this a MiSTer?" % a["dev"])
    fd = os.open(a["dev"], os.O_RDONLY)
    try:
        is_fb = os.path.basename(a["dev"]).startswith("fb")
        g = geometry(fd if is_fb else None, a["dev"], a["geom"], a["rgb"])
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
