# PSPi-6 Audio Modules

Prebuilt kernel modules for the images PSPi Version 6 ships. The main
[PSPi-Version-6](https://github.com/othermod/PSPi-Version-6) patcher downloads
release artifacts from this repo instead of compiling anything itself.

Module **source** (driver patches) lives in the PSPi-Version-6 repo under
`rpi/audio/<module>/`. This repo holds only the **build system**: per-image
kernel facts, the build script, and CI that produces releases.

## Layout

```
kernels/<image>.facts      one file per supported image: kernel commit,
                           vermagic, config, symvers (if modversions), and
                           the list of modules to build
kernels/configs/           kernel .config files referenced by the facts files
build.sh                   builds every module named in a facts file
dist/<image>/              build output: <module>.ko + manifest.txt
```

## Supported images

| facts file | image | kernel | notes |
|---|---|---|---|
| `kernels/lakka-6.1-cm4.facts` | Lakka 6.1 (CM4, arm64) | 6.12.66 | modversions off |
| `kernels/batocera-43.1-cm4.facts` | Batocera 43.1 (CM4, arm64) | 6.12.62-v8 | modversions on; symvers harvested from stock module |

## Deployment notes

How the modules get onto a running device once built (the main patcher does
this automatically):

**Lakka 6.1** — copy the `.ko` to `/storage/snd-bcm2835.ko`; `boot.sh`
loads it at boot (a block at the top of `scripts/config/boot.sh` in the
PSPi repo). The `mono_mix` parameter cannot reach the kernel cmdline, so
`boot.sh` passes it as an insmod option.

**Batocera 43.1** — install the `.ko` into
`/lib/modules/<kver>/updates/`, run `depmod -b / <kver>` (the `updates/`
copy then shadows the stock module), and copy the updated
`pspi-audio-cm4-kernel6+.dtbo` from the PSPi repo to `/boot/overlays/`.
Run `batocera-save-overlay` to persist the root filesystem changes across
reboots. Batocera *does* honor the overlay's bootargs, so the cmdline's
`snd_bcm2835.mono_mix=1` activates the downmix with no extra hook.

## Building

Needs: bash, curl, git, patch, make, gcc, readelf. Runs on any Linux host
(aarch64 native or any host with `CROSS_COMPILE` set).

```
./build.sh kernels/lakka-6.1-cm4.facts
./build.sh kernels/batocera-43.1-cm4.facts
```

The script downloads the PSPi-Version-6 repo at `--pspi-ref` (default
`main`), copies in the module dirs named in the facts file, fetches the
kernel source at the pinned commit, prepares it, builds, and verifies each
`.ko`'s vermagic against the value probed from the booted image.

## Adding a new image

1. Boot the image, probe: `uname -r`, `uname -m`,
   `modinfo -F vermagic <stock module>`, and whether the kernel has
   `CONFIG_MODVERSIONS` (check for a `__versions` section in any shipped
   `.ko`).
2. Find the kernel source commit + config the distro builds with.
3. Write `kernels/<image>.facts`; commit the config (and fragment, if the
   distro merges one) under `kernels/configs/`.
4. If the kernel has modversions on, harvest a `Module.symvers` from the
   stock module's `__versions` section and commit it under `kernels/symvers/`.
5. Add the image to the table above.
