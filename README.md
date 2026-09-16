# fbshot - Save the MiSTer's Linux framebuffer as a PNG.

MiSTer's built-in screenshot (`Win`+`PrtScn`) reads the core's video out of the
scaler's buffer in DDR. It never looks at `/dev/fb0`, so anything living in the
framebuffer layer — the MiSTer menu wallpaper, MisterZine, other framebuffer
apps — can't be captured with it. fbshot grabs that layer instead.

One POSIX shell script with a Python 3 program inside it. Nothing to install,
nothing to build, nothing to leave behind: the `python3` every current MiSTer
image ships with is the only dependency.

## One command

From your PC, with the PNG landing next to you. Replace `192.168.1.100` with
your own MiSTer's IP address — the OSD shows it under System Information, and
your router's client list will have it as `MiSTer`:

```sh
curl -sL https://raw.githubusercontent.com/matijaerceg/mister-fbshot/main/fbshot.sh | ssh root@192.168.1.100 "sh -s -- -o -" > fbshot.png
```

Your PC fetches the script, ssh hands it to the MiSTer's shell, the PNG comes
back down the same connection. Nothing touches the SD card. The default
password is `1`.

Or on the MiSTer itself, saving to `/media/fat/screenshots/framebuffer/`:

```sh
wget -qO- https://raw.githubusercontent.com/matijaerceg/mister-fbshot/main/fbshot.sh | sh
```

`wget` rather than `curl` on the MiSTer because a stock image has no CA bundle
where curl looks for one, so HTTPS fails with "unable to get local issuer
certificate". If you'd rather use curl there, point it at the bundle the
updater leaves behind: `curl -sL --cacert /etc/ssl/certs/cacert.pem ...`.

## Options

```
sh fbshot.sh                 save to /media/fat/screenshots/framebuffer/
sh fbshot.sh -o shot.png     save somewhere else
sh fbshot.sh -o -            write the PNG to stdout
sh fbshot.sh -s 3            enlarge 3x, nearest neighbour
sh fbshot.sh -d 5            wait 5 seconds, then capture
```

## Keeping it on the SD card

```sh
wget -O /media/fat/Scripts/fbshot.sh https://raw.githubusercontent.com/matijaerceg/mister-fbshot/main/fbshot.sh
```

It then shows up in the MiSTer's Scripts menu — but note that running a script
puts the Linux console on screen, and the console draws into the very
framebuffer you're capturing, so that's what you'll get. The Scripts entry is
handy for `-d`-delayed grabs and for checking that it works; SSH is the way to
capture what's normally on screen.

## What you get

* The framebuffer exactly as the FPGA reads it: the pixels an app wrote, before
  the scaler, so no scanlines, no filters, no HDMI scaling.
* Whatever resolution the framebuffer is in — often much smaller than your TV's.
  MisterZine, for instance, runs it at 320x240, so `-s 3` or `-s 4` is worth it.

## What you don't

* **The core's video.** A running core paints through the scaler, not the
  framebuffer; the built-in `Win`+`PrtScn` is the right tool for that (add
  `LShift` for the core's native resolution instead of a rescaled copy).
* **The OSD.** Main builds the menu overlay in its own buffer and pushes it to
  the FPGA over SPI, so it's composited downstream of anything readable here.
* **A guaranteed-clean frame.** fbshot waits for a vblank before it starts, but
  the read isn't atomic; a fast-moving screen can tear.

## How it works

`/dev/fb0` on a MiSTer is an ordinary Linux framebuffer (`MiSTer_fb`, 32bpp
ARGB by default). fbshot asks the kernel for the geometry with
`FBIOGET_VSCREENINFO`/`FBIOGET_FSCREENINFO` — resolution, stride, bit depth and
the red/green/blue offsets within a pixel, rather than assuming them — waits on
`FBIO_WAITFORVSYNC`, reads the visible page, and writes a PNG with `zlib` from
the standard library. 16bpp (RGB565) framebuffers work too.

If the ioctls are refused it falls back to `/sys/class/graphics/fb0/`. You can
also convert a raw dump taken any other way, on any machine with Python:

```sh
ssh root@192.168.1.100 "cat /sys/class/graphics/fb0/virtual_size"   # e.g. 320,240
ssh root@192.168.1.100 "cat /dev/fb0" > fb.raw
sh fbshot.sh --dev fb.raw --geom 320x240x32 -o fb.png
```

## Prior art

[Screenshot_MiSTer](https://github.com/alanswx/Screenshot_MiSTer) by alanswx is
the other half of this picture: it reads ascal's buffer at `0x20000000` through
`/dev/mem` to grab the core's video. That code grew into `scaler.cpp` in
[Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) and is what the
`Win`+`PrtScn` key does today. The Linux framebuffer sits 32MB further up in
DDR and neither of them touches it.

## Licence

MIT.
