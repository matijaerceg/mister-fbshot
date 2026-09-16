# fbshot - Save the MiSTer's Linux framebuffer as a PNG

Take a screenshot of the MiSTer's *own* screens — the menu, the wallpaper, and
apps like MisterZine that draw their own interface. The MiSTer's built-in
screenshot key can't: it only captures the game a core is running.

Nothing to install, nothing to build. One command, and the picture lands on
your computer.

## Take a screenshot

Run this on your computer — Terminal on macOS or Linux, **Command Prompt** on
Windows — with your MiSTer's own IP address in place of `192.168.1.100`:

```sh
curl -fsSL https://raw.githubusercontent.com/matijaerceg/mister-fbshot/main/fbshot.sh | ssh root@192.168.1.100 "sh -s -- -o -" > fbshot.png
```

`fbshot.png` appears in the folder you ran it from. Nothing is copied onto the
MiSTer's SD card.

- **Finding the IP:** it's in your router's device list as `MiSTer`, and on the
  MiSTer itself on the Misc. Options page, under *Information*.
- **The password** is `1`, unless you've changed it. The very first connection
  also asks you to type `yes` to accept the MiSTer's key.
- **On Windows, don't use PowerShell.** It garbles the file in both directions
  and leaves you an empty one. Command Prompt works, as do Git Bash and WSL —
  or run it on the MiSTer instead (see below).

## Got a black picture?

Then nothing was drawing to that layer at the time, which is normal while a core
is running: the game goes out to your TV without passing through it. Open the
MiSTer menu, or start an app like MisterZine, and take another.

## Bigger, or delayed

Options go between `--` and the closing quote. A 3x enlargement, five seconds
from now:

```sh
curl -fsSL https://raw.githubusercontent.com/matijaerceg/mister-fbshot/main/fbshot.sh | ssh root@192.168.1.100 "sh -s -- -s 3 -d 5 -o -" > fbshot.png
```

`-s N` enlarges N times (worth it on a 320x240 screen, skip it at 1080p), `-d N`
waits N seconds first, and `-o FILE` saves on the MiSTer instead of sending the
picture back. `-h` lists the rest.

<details>
<summary><b>Running it on the MiSTer instead</b> — for PowerShell users, or to keep it in the Scripts menu</summary>

From the MiSTer's own console, or over ssh from any shell. It saves to
`/media/fat/screenshots/framebuffer/fb-<date>-<time>.png`, alongside the
per-core folders the built-in screenshot uses:

```sh
ssh root@192.168.1.100 "wget -O- https://raw.githubusercontent.com/matijaerceg/mister-fbshot/main/fbshot.sh | sh"
scp root@192.168.1.100:/media/fat/screenshots/framebuffer/fb-*.png .
```

To keep a copy on the card:

```sh
wget -O /media/fat/Scripts/fbshot.sh https://raw.githubusercontent.com/matijaerceg/mister-fbshot/main/fbshot.sh
```

It then appears in the MiSTer's Scripts menu, which is handy for checking that
it works but not much else: launching a script switches the screen to the Linux
console, and the console draws into the very layer you're capturing, so that's
what you'll get. Main also runs Scripts entries with no arguments, so there's no
way to pass `-d` from there without wrapping it in a second script.

`wget` rather than `curl` on the MiSTer because curl there isn't built to look
where the CA bundle actually is, and HTTPS fails with "unable to get local
issuer certificate". The image does ship one, at `/etc/ssl/certs/cacert.pem` on
a read-only rootfs, so `curl -fsSL --cacert /etc/ssl/certs/cacert.pem ...` works
if you prefer curl.
</details>

<details>
<summary><b>What it can and can't capture</b></summary>

**Yes:** the framebuffer exactly as the FPGA reads it — the pixels an app wrote,
before the scaler, so no scanlines, no filters, no HDMI scaling. At whatever
resolution the framebuffer is in, which is often much smaller than your TV's;
MisterZine, for instance, runs it at 320x240.

**No:**

- **The core's video.** A running core paints through the scaler, not this
  layer. The built-in `Win`+`PrtScn` is the right tool for that — add `LShift`
  for the core's native resolution instead of a rescaled copy.
- **The OSD.** Main builds the menu overlay in its own buffer and pushes it to
  the FPGA over SPI, so it's composited downstream of anything readable here.
- **A guaranteed-clean frame.** fbshot waits for a vblank before it starts, but
  the read isn't atomic. At 320x240 it's done in 2ms of a 33ms frame and tearing
  is unlikely; at 1080p the read spans two frames, so a moving picture will tear.
</details>

<details>
<summary><b>How it works</b> — and speed, memory, raw dumps</summary>

`/dev/fb0` on a MiSTer is an ordinary Linux framebuffer (`MiSTer_fb`, 32bpp
XRGB8888 by default — the fourth byte is unused, not alpha). fbshot asks the
kernel for the geometry with `FBIOGET_VSCREENINFO`/`FBIOGET_FSCREENINFO` —
resolution, stride, depth and the bit offset and width of each colour channel,
rather than assuming them — waits on `FBIO_WAITFORVSYNC`, reads the visible
page, and writes a PNG with `zlib` from the standard library. Because the
channel bitfields come from the driver, MiSTer's 16bpp modes (`565` and `1555`,
either of them with red and blue swapped) decode correctly too. 8bpp palette
mode is not supported. If the ioctls are refused it falls back to
`/sys/class/graphics/fb0/`.

It's one POSIX shell script with a Python 3 program inside it; the `python3` on
every recent MiSTer image is the only dependency.

A 320x240 capture is instant. 1080p takes about three seconds on a DE10-Nano
with the worst possible input (incompressible noise) and less with a real
screen. The PNG is compressed row by row as it's read, so peak memory stays
around 40MB whatever you pass to `-s`: enlarging costs time, not RAM.

You can also convert a raw dump taken any other way, on any machine with Python:

```sh
ssh root@192.168.1.100 "cd /sys/class/graphics/fb0 && cat virtual_size bits_per_pixel stride"
ssh root@192.168.1.100 "cat /dev/fb0" > fbdump.raw
sh fbshot.sh --dev fbdump.raw --geom 320x240x32 --stride 1280 -o fb.png
```

`--geom` assumes RGB565 for 16bpp dumps, since a plain file carries no channel
layout; `--rgb` overrides the byte order at 32bpp.
</details>

## Prior art

[Screenshot_MiSTer](https://github.com/alanswx/Screenshot_MiSTer) by alanswx is
the other half of this picture: it reads ascal's buffer at `0x20000000` through
/dev/mem to grab the core's video. That code grew into `scaler.cpp` in
[Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) and is what the
`Win`+`PrtScn` key does today. The Linux framebuffer sits 32MB further up in
DDR and neither of them touches it.

MIT licence.
