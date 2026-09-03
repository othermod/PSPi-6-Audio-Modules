#!/usr/bin/env bash
#
# Build PSPi kernel modules for the image releases PSPi ships.
#
# This repo does not contain module source. Each module's driver source and
# patch live in the PSPi-Version-6 repo; this script downloads that repo at a
# chosen ref, copies in the module dirs it is told to build, and compiles
# them against the kernel source described by a per-image "facts" file.
#
# A facts file is shell-sourceable and describes one supported image:
#
#   IMAGE             short id, also used as the dist/ subdirectory name
#   ARCH              arm64 | arm
#   VERMAGIC          the image kernel's vermagic (from `modinfo -F vermagic`)
#   MODVERSIONS       off | on   (on: a Module.symvers must be provided)
#   SYMVERS           path (repo-relative) to a harvested Module.symvers
#   UPSTREAM_COMMIT   raspberrypi/linux commit matching the image kernel
#   KERNEL_CONFIG     path (repo-relative) to the kernel .config
#   MODULES           space-separated module dir names (under rpi/audio/ in
#                     the PSPi repo, e.g. snd-bcm2835-mono rp1-aout-mono)
#
# Usage:
#   build.sh kernels/lakka-6.1-cm4.facts
#   build.sh kernels/*.facts                       (build everything)
#   build.sh --pspi-ref main ...                   (pin the PSPi source ref)
#
# Output: dist/<IMAGE>/<module>.ko plus dist/<IMAGE>/manifest.txt

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK_ROOT="${KMOD_WORK_DIR:-$HERE/work}"
DIST_DIR="${KMOD_DIST_DIR:-$HERE/dist}"
PSPi_REPO="othermod/PSPi-Version-6"
PSPi_REF="main"
PSPi_SRC=""

die() { echo "ERROR: $*" >&2; exit 1; }
# stderr: functions invoked via command substitution return values on stdout.
log() { echo ":: $*" >&2; }
say() { echo "   $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit "${1:-0}"; }

# ---------------------------------------------------------------- fetch pspi
#
# Download the PSPi repo tarball at the chosen ref and extract once.
# Returns the path to the extracted tree on stdout.
fetch_pspi() {
    local ref="$1"
    # --pspi-src: use a local checkout instead of downloading (dev/testing).
    if [[ -n "$PSPi_SRC" ]]; then
        [[ -d "$PSPi_SRC/rpi/audio" ]] \
            || die "--pspi-src: no rpi/audio under $PSPi_SRC"
        echo "$PSPi_SRC"
        return
    fi
    local dir="$WORK_ROOT/pspi-$ref"
    if [[ -d "$dir/rpi/audio" ]]; then
        echo "$dir"
        return
    fi
    local tarball="$WORK_ROOT/pspi-$ref.tar.gz"
    if [[ ! -f "$tarball" ]]; then
        log "downloading $PSPi_REPO @ $ref"
        curl -fsSL --max-time 300 \
            "https://codeload.github.com/$PSPi_REPO/tar.gz/refs/heads/$ref" \
            -o "$tarball" \
            || curl -fsSL --max-time 300 \
            "https://codeload.github.com/$PSPi_REPO/tar.gz/refs/tags/$ref" \
            -o "$tarball"
    fi
    rm -rf "$dir" "$WORK_ROOT/.pspi-untar"
    mkdir -p "$WORK_ROOT/.pspi-untar"
    tar xzf "$tarball" -C "$WORK_ROOT/.pspi-untar"
    mv "$WORK_ROOT/.pspi-untar"/* "$dir"
    rmdir "$WORK_ROOT/.pspi-untar"
    echo "$dir"
}

# ---------------------------------------------------------------- prepare
#
# Fetch the kernel source at the facts' commit, drop in the config, run
# modules_prepare. stdout carries ONLY the kdir path; work output goes to
# stderr and the build log.
prepare_kdir() {
    local facts="$1" log="$2"
    local kdir="$WORK_ROOT/linux-$UPSTREAM_COMMIT-$ARCH"

    if [[ -f "$kdir/.prepared" ]]; then
        log "cached"
    else
        log "fetching kernel source @ ${UPSTREAM_COMMIT:0:12}"

    local tarball="$WORK_ROOT/linux-$UPSTREAM_COMMIT.tar.gz"
    # Verify integrity when the facts file provides the archive sha256 (the
    # distro's package recipe usually publishes it). A corrupt/truncated
    # tarball is deleted so the re-download is automatic.
    if [[ -n "${UPSTREAM_SHA256:-}" && -f "$tarball" ]]; then
        if ! echo "$UPSTREAM_SHA256  $tarball" | sha256sum -c --status 2>/dev/null; then
            log "cached tarball failed sha256; re-downloading"
            rm -f "$tarball"
        fi
    fi
    if [[ ! -f "$tarball" ]]; then
        curl -fsSL --max-time 900 \
            "https://github.com/raspberrypi/linux/archive/$UPSTREAM_COMMIT.tar.gz" \
            -o "$tarball"
        if [[ -n "${UPSTREAM_SHA256:-}" ]]; then
            echo "$UPSTREAM_SHA256  $tarball" | sha256sum -c --status \
                || die "kernel archive sha256 mismatch (expected $UPSTREAM_SHA256)"
        fi
    fi
    rm -rf "$kdir" "$WORK_ROOT/.untar"
    mkdir -p "$WORK_ROOT/.untar"
    tar xzf "$tarball" -C "$WORK_ROOT/.untar"
    mv "$WORK_ROOT/.untar"/* "$kdir"
    rmdir "$WORK_ROOT/.untar"
    cp "$HERE/$KERNEL_CONFIG" "$kdir/.config"

    log "oldconfig + modules_prepare"
    {
        ( cd "$kdir" && yes "" | make ARCH="$ARCH" oldconfig )
        # Fragment merge (buildroot-style): some distros layer a fragment on
        # top of their base defconfig at build time; reproduce that with the
        # kernel's own merge tool, then settle the result.
        if [[ -n "${KERNEL_CONFIG_FRAGMENT:-}" ]]; then
            say "merging config fragment: $KERNEL_CONFIG_FRAGMENT"
            ( cd "$kdir" && ./scripts/kconfig/merge_config.sh -m .config "$HERE/$KERNEL_CONFIG_FRAGMENT" )
            ( cd "$kdir" && yes "" | make ARCH="$ARCH" oldconfig )
        fi
        make -C "$kdir" ARCH="$ARCH" -j"$(nproc)" modules_prepare
    } > "$log" 2>&1 || { tail -30 "$log" >&2; die "kernel prepare failed ($log)"; }
    fi

    # modversions image: the harvested symvers supplies real symbol CRCs so
    # modpost stamps them instead of zeros (which would fail insmod). Applied
    # on EVERY run (not only first prepare) so updated facts take effect even
    # against a cached tree.
    if [[ "$MODVERSIONS" == "on" ]]; then
        [[ -n "${SYMVERS:-}" ]] || die "$FACTS: MODVERSIONS=on but no SYMVERS file given"
        [[ -f "$HERE/$SYMVERS" ]] || die "$FACTS: symvers file not found: $SYMVERS"
        cp "$HERE/$SYMVERS" "$kdir/Module.symvers"
        say "using harvested symvers: $SYMVERS"
    fi

    if [[ ! -f "$kdir/.prepared" ]]; then
        touch "$kdir/.prepared"
    fi
    echo "$kdir"
}

# ---------------------------------------------------------------- build one
build_module() {
    local pspi="$1" kdir="$2" module="$3" log="$4"
    local src="$pspi/rpi/audio/$module"
    [[ -d "$src" ]] || die "module dir not found in PSPi repo: rpi/audio/$module"

    local bdir="$WORK_ROOT/build-$IMAGE-$module"
    rm -rf "$bdir"; mkdir -p "$bdir"
    cp -r "$src/." "$bdir/"

    log "building $module"
    {
        make -C "$bdir" \
            UPSTREAM_COMMIT="$UPSTREAM_COMMIT" \
            KDIR="$kdir" \
            ARCH="$ARCH" \
            CROSS_COMPILE="${CROSS_COMPILE:-}" \
            all
    } > "$log" 2>&1 || { tail -30 "$log" >&2; die "build of $module failed ($log)"; }

    # Guard against silent CRC zeroes on modversions kernels: modpost warns
    # "no CRC" when an import is missing from the symvers; treat as fatal.
    if [[ "$MODVERSIONS" == "on" ]] && grep -q "no CRC" "$log"; then
        grep "no CRC" "$log" | head -5 >&2
        die "$module imports symbols missing from the symvers -- refusing to ship"
    fi

    local ko
    ko="$(find "$bdir/upstream" -name '*.ko' | head -1)"
    [[ -n "$ko" ]] || die "no .ko produced for $module"

    mkdir -p "$DIST_DIR/$IMAGE"
    cp "$ko" "$DIST_DIR/$IMAGE/$module.ko"
    echo "$DIST_DIR/$IMAGE/$module.ko"
}

# ---------------------------------------------------------------- verify
verify_ko() {
    local ko="$1"
    local got
    got="$(readelf -p .modinfo "$ko" 2>/dev/null | sed -n 's/.*vermagic=//p')"
    say "vermagic: $got"
    [[ "$got" == "$VERMAGIC" ]] \
        || die "$ko vermagic mismatch (want: $VERMAGIC)"
}

# ---------------------------------------------------------------- one image
build_image() {
    local facts="$1"
    # shellcheck disable=SC1090
    source "$facts"
    FACTS="$facts"
    [[ -n "${IMAGE:-}" && -n "${ARCH:-}" && -n "${VERMAGIC:-}" ]] \
        || die "$facts: IMAGE, ARCH and VERMAGIC are required"
    [[ -f "$HERE/$KERNEL_CONFIG" ]] || die "$facts: config not found: $KERNEL_CONFIG"
    [[ -n "${MODULES:-}" ]] || die "$facts: MODULES is required"

    log "=== $IMAGE ($ARCH, kernel ${KERNEL_RELEASE:-?}, modversions $MODVERSIONS) ==="

    local pspi kdir
    pspi="$(fetch_pspi "$PSPi_REF")"

    local log="$WORK_ROOT/logs"
    mkdir -p "$log"

    kdir="$(prepare_kdir "$facts" "$log/$IMAGE-prepare.log")"

    for module in $MODULES; do
        local ko
        ko="$(build_module "$pspi" "$kdir" "$module" "$log/$IMAGE-$module.log")"
        verify_ko "$ko"
        say "built: $ko"
    done

    # Manifest: what was built, against what, and how to check it.
    local manifest="$DIST_DIR/$IMAGE/manifest.txt"
    {
        echo "image: $IMAGE"
        echo "kernel: ${KERNEL_RELEASE:-} ($UPSTREAM_COMMIT)"
        echo "vermagic: $VERMAGIC"
        echo "modversions: $MODVERSIONS"
        echo "pspi-source: $PSPi_REPO @ $PSPi_REF"
        echo "built: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        for module in $MODULES; do
            echo "module: $module  sha256: $(sha256sum "$DIST_DIR/$IMAGE/$module.ko" | cut -d' ' -f1)"
        done
    } > "$manifest"
    say "manifest: $manifest"
}

# ---------------------------------------------------------------- main

main() {
    need bash; need curl; need git; need patch; need make; need gcc; need readelf

    local -a facts_files=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pspi-ref)       PSPi_REF="$2"; shift 2 ;;
            --pspi-src)       PSPi_SRC="$2"; shift 2 ;;
            --cross-compile)  CROSS_COMPILE="$2"; shift 2 ;;
            --work-dir)       WORK_ROOT="$2"; shift 2 ;;
            --dist-dir)       DIST_DIR="$2"; shift 2 ;;
            -h|--help)    usage 0 ;;
            -*)           die "unknown arg: $1" ;;
            *)            facts_files+=("$1"); shift ;;
        esac
    done
    ((${#facts_files[@]})) || { usage 1; }

    mkdir -p "$WORK_ROOT/logs" "$DIST_DIR"

    local f
    for f in "${facts_files[@]}"; do
        [[ -f "$f" ]] || die "facts file not found: $f"
        build_image "$f"
    done
    log "done"
}

main "$@"
