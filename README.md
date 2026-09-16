# fbshot - Save the MiSTer's Linux framebuffer as a PNG

MiSTer's built-in screenshot (`Win`+`PrtScn`) reads the core's video out of the
scaler's buffer in DDR. It never looks at `/dev/fb0`, so anything living in the
framebuffer layer — the MiSTer menu wallpaper, MisterZine, other framebuffer
apps — can't be captured with it. fbshot grabs that layer instead.

One POSIX shell script with a Python 3 program inside it. Nothing to install and
nothing to build: it runs out of the pipe and exits, and the `python3` on every
recent MiSTer image is the only dependency.

## One command

From your PC, with the PNG landing next to you. Replace `192.168.1.100` with
your own MiSTer's IP address — your router's client list will have it as
`MiSTer`, and the OSD shows it on the Misc. Options page under *Information*:

```sh
curl -fsSL https://raw.githubusercontent.com/matijaerceg/mister-fbshot/main/fbshot.sh | ssh root@192.168.1.100 "sh -s -- -o -" > fbshot.png
```

Your PC fetches the script, ssh hands it to the MiSTer's shell, the PNG comes
back down the same connection. Nothing touches the SD card. SSH is on by
default on a MiSTer and the password is `1`; the first connection will ask you
to accept the host key.

**On Windows, use Command Prompt, Git Bash or WSL — not PowerShell.** PowerShell
rewrites what passes through a pipe: it re-encodes the script on the way up (BOM
and CRLF, which the MiSTer's shell then refuses) and corrupts the PNG on the way
back down. You get a 0-byte file and, with `curl` aliased to `Invoke-WebRequest`,
a parameter error. If you're staying in PowerShell, run it on the MiSTer instead
and copy the file off:

```powershell
ssh root@192.168.1.100 "wget -O- https://raw.githubusercontent.com/matijaerceg/mister-fbshot/main/fbshot.sh | sh"
scp root@192.168.1.100:/media/fat/screenshots/framebuffer/fb-*.png .
```

That second form is also the one to use from the MiSTer's own console. It saves
to `/media/fat/screenshots/framebuffer/fb-<date>-<time>.png`, alongside the
per-core folders the built-in screenshot writes to.

`wget` rather than `curl` on the MiSTer because curl there isn't built to look
where the CA bundle actually is, so HTTPS fails with "unable to get local issuer
certificate". The image does ship one, at `/etc/ssl/certs/cacert.pem` on a
read-only rootfs, so `curl -fsSL --cacert /etc/ssl/certs/cacert.pem ...` works
if you prefer curl.

## Options

```
sh fbshot.sh                 save to /media/fat/screenshots/framebuffer/
sh fbshot.sh -o shot.png     save somewhere else
sh fbshot.sh -o -            write the PNG to stdout
sh fbshot.sh -s 3            enlarge 3x, nearest neighbour
sh fbshot.sh -d 5            wait 5 seconds, then capture
sh fbshot.sh -h              the rest: --dev, --geom, --stride, --rgb
```

Over ssh, the options go after `sh -s --`: the `-s` tells the remote shell to
read the script from the pipe, and everything past `--` is passed on to fbshot.
So a 3x capture to your PC is:

```sh
curl -fsSL https://raw.githubusercontent.com/matijaerceg/mister-fbshot/main/fbshot.sh | ssh root@192.168.1.100 "sh -s -- -s 3 -o -" > fbshot.png
```

## Keeping it on the SD card

```sh
wget -O /media/fat/Scripts/fbshot.sh https://raw.githubusercontent.com/matijaerceg/mister-fbshot/main/fbshot.sh
```

It then shows up in the MiSTer's Scripts menu, which is handy for checking that
it works — but not much else. Launching a script switches the screen to the
Linux console, and the console draws into the very framebuffer you're capturing,
so that's what you'll get; Main also runs Scripts entries with no arguments, so
there's no way to pass `-d` from there without wrapping it in a second script.
SSH is the way to capture what's normally on screen.

## What you get

* The framebuffer exactly as the FPGA reads it: the pixels an app wrote, before
  the scaler, so no scanlines, no filters, no HDMI scaling.
* Whatever resolution the framebuffer is in — often much smaller than your TV's.
  MisterZine, for instance, runs it at 320x240, where `-s 3` or `-s 4` is worth
  it. (At 1080p, leave `-s` alone and scale on your PC.)

## What you don't

* **The core's video.** A running core paints through the scaler, not the
  framebuffer; the built-in `Win`+`PrtScn` is the right tool for that (add
  `LShift` for the core's native resolution instead of a rescaled copy).
* **The OSD.** Main builds the menu overlay in its own buffer and pushes it to
  the FPGA over SPI, so it's composited downstream of anything readable here.
* **A guaranteed-clean frame.** fbshot waits for a vblank before it starts, but
  the read isn't atomic. At 320x240 it's done in 2ms of a 33ms frame and tearing
  is unlikely; at 1080p the read spans two frames, so a moving picture will tear.

## If the picture is black

Then nothing is drawing to the framebuffer right now, which is the normal state
while a core is running — the core's video goes through the scaler, and
`/dev/fb0` just holds whatever was written into it last. Open the MiSTer menu
(with a wallpaper set, if you want something recognisable) or start a
framebuffer app such as MisterZine, and try again.

## Speed and memory

A 320x240 capture is instant. 1080p takes about three seconds on a DE10-Nano
with the worst possible input (incompressible noise) and less with a real
screen. The PNG is compressed row by row as it's read, so peak memory stays
around 40MB whatever you pass to `-s`: enlarging costs time, not RAM.

## How it works

`/dev/fb0` on a MiSTer is an ordinary Linux framebuffer (`MiSTer_fb`, 32bpp
XRGB8888 by default — the fourth byte is unused, not alpha). fbshot asks the
kernel for the geometry with `FBIOGET_VSCREENINFO`/`FBIOGET_FSCREENINFO` —
resolution, stride, depth and the bit offset and width of each colour channel,
rather than assuming them — waits on `FBIO_WAITFORVSYNC`, reads the visible
page, and writes a PNG with `zlib` from the standard library. Because the
channel bitfields come from the driver, MiSTer's 16bpp modes (`565` and `1555`,
either of them with red and blue swapped) decode correctly too. 8bpp palette
mode is not supported.

If the ioctls are refused it falls back to `/sys/class/graphics/fb0/`. You can
also convert a raw dump taken any other way, on any machine with Python:

```sh
ssh root@192.168.1.100 "cd /sys/class/graphics/fb0 && cat virtual_size bits_per_pixel stride"
ssh root@192.168.1.100 "cat /dev/fb0" > fbdump.raw
sh fbshot.sh --dev fbdump.raw --geom 320x240x32 --stride 1280 -o fb.png
```

`--geom` assumes RGB565 for 16bpp dumps, since a plain file carries no channel
layout; `--rgb` overrides the byte order at 32bpp.

## Prior art

[Screenshot_MiSTer](https://github.com/alanswx/Screenshot_MiSTer) by alanswx is
the other half of this picture: it reads ascal's buffer at `0x20000000` through
/dev/mem to grab the core's video. That code grew into `scaler.cpp` in
[Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) and is what the
`Win`+`PrtScn` key does today. The Linux framebuffer sits 32MB further up in
DDR and neither of them touches it.

## Licence

MIT.
