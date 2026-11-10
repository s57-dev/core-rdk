#!/usr/bin/env bash
# Start core-rdk-image under QEMU via kas-container.
#
# Usage:
#   scripts/start-qemu.sh              # serial console (default)
#   scripts/start-qemu.sh --vnc        # virtio-gpu + egl-headless + VNC :5900
#   scripts/start-qemu.sh --gtk        # X11 GTK + virgl (default for graphics)
#   scripts/start-qemu.sh --gtk --gl   # same (gl is implied with --gtk)
#   scripts/start-qemu.sh --gtk --nogl # GTK window without virgl
#   scripts/start-qemu.sh --serial --snapshot
#
# Phase-1 default ships egl-headless+vnc; enable gtk+ in repos-core.yml and
# rebuild qemu-system-native for a real X11 window (--gtk).
#
# Env:
#   KAS_CONTAINER_IMAGE   default: rdk-kas-builder:latest
#   KAS_CONTAINER         path to kas-container (auto-detected)
#   DISPLAY               auto-detected from /tmp/.X11-unix if unset
#   SSH_HOST_PORT         host port for guest SSH (default 2222)
#   VNC_HOST_PORT         host port for VNC when --vnc (default 5900)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE=serial
WANT_GL=-1   # -1 = default with gtk; 0 = force off; 1 = gl; 2 = gl-es
SNAPSHOT=1
EXTRA_QEMUPARAMS=()

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --serial|serial|nographic) MODE=serial ;;
        --vnc|vnc) MODE=vnc ;;
        --gtk|gtk) MODE=gtk ;;
        --gl|gl) WANT_GL=1 ;;
        --gl-es|gl-es) WANT_GL=2 ;;
        --nogl|nogl) WANT_GL=0 ;;
        --snapshot) SNAPSHOT=1 ;;
        --no-snapshot) SNAPSHOT=0 ;;
        --qemuparams)
            shift
            [[ $# -gt 0 ]] || { echo "error: --qemuparams needs a value" >&2; exit 2; }
            EXTRA_QEMUPARAMS+=("$1")
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage 2
            ;;
    esac
    shift
done

KAS_CONTAINER_IMAGE="${KAS_CONTAINER_IMAGE:-rdk-kas-builder:latest}"
export KAS_CONTAINER_IMAGE

SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"
VNC_HOST_PORT="${VNC_HOST_PORT:-5900}"

find_kas_container() {
    if [[ -n "${KAS_CONTAINER:-}" && -x "${KAS_CONTAINER}" ]]; then
        echo "${KAS_CONTAINER}"
        return
    fi
    local c
    for c in \
        "${ROOT}/../rdk-monorepo-build/venv/bin/kas-container" \
        "${ROOT}/venv/bin/kas-container" \
        "$(command -v kas-container 2>/dev/null || true)"
    do
        if [[ -n "$c" && -x "$c" ]]; then
            echo "$c"
            return
        fi
    done
    echo "error: kas-container not found (set KAS_CONTAINER or install kas in a venv)" >&2
    exit 1
}

# Return 0 if built qemu-system-arm lists gtk as a display backend.
qemu_has_gtk() {
    local q
    q="$(find "${ROOT}/build/tmp-glibc/work/x86_64-linux/qemu-helper-native" \
        -type f -name qemu-system-arm 2>/dev/null | head -n 1 || true)"
    [[ -n "$q" && -x "$q" ]] || return 1
    "$q" -display help 2>&1 | grep -qw gtk
}

# Pick a usable DISPLAY for GTK (XFCE/NoMachine often uses :1002 etc.).
resolve_display() {
    if [[ -n "${DISPLAY:-}" ]]; then
        echo "${DISPLAY}"
        return
    fi
    local sock
    # Prefer higher-numbered sockets (user sessions) over :0 if both exist.
    for sock in $(ls -1 /tmp/.X11-unix/X* 2>/dev/null | sort -V -r); do
        [[ -S "$sock" ]] || continue
        echo ":${sock##*/X}"
        return
    done
    return 1
}

# Find the XAUTHORITY file actually used by the session on $DISPLAY.
resolve_xauthority() {
    local disp="$1"
    local num="${disp#:}"
    num="${num%%.*}"

    if [[ -n "${XAUTHORITY:-}" && -f "${XAUTHORITY}" ]]; then
        echo "${XAUTHORITY}"
        return
    fi

    # NoMachine / NX keeps per-session authority under ~/.nx/
    local nx
    nx="$(ps e -u "${USER}" 2>/dev/null | tr ' ' '\n' | \
        sed -n 's/^XAUTHORITY=//p' | grep -E "C-.*-${num}-|/unix:${num}|:${num}$" | sort -u | head -n 1 || true)"
    if [[ -z "$nx" ]]; then
        # Direct path glob used by NX node sessions
        nx="$(ls -1 "${HOME}/.nx/node/C-"*-"${num}"-*/authority 2>/dev/null | head -n 1 || true)"
    fi
    if [[ -n "$nx" && -f "$nx" ]]; then
        echo "$nx"
        return
    fi

    # Fallback: any process env that references this display number
    local cand
    cand="$(ps e -u "${USER}" 2>/dev/null | tr ' ' '\n' | \
        sed -n 's/^XAUTHORITY=//p' | while read -r p; do
            [[ -f "$p" ]] || continue
            if DISPLAY="$disp" XAUTHORITY="$p" xauth list "$disp" 2>/dev/null | grep -q .; then
                echo "$p"
                break
            fi
        done)"
    if [[ -n "$cand" && -f "$cand" ]]; then
        echo "$cand"
        return
    fi

    if [[ -f "${HOME}/.Xauthority" ]]; then
        echo "${HOME}/.Xauthority"
        return
    fi
    return 1
}

# Build an xauth file docker/root can use (FamilyWild cookies).
prepare_docker_xauth() {
    local disp="$1"
    local src_auth="$2"
    local out="${TMPDIR:-/tmp}/core-rdk-docker-xauth-${USER}"
    mkdir -p "$(dirname "$out")"
    rm -f "$out"
    touch "$out"
    chmod 666 "$out"

    # Extract cookies for this display and rewrite as FamilyWild (ffff).
    if command -v xauth >/dev/null 2>&1; then
        DISPLAY="$disp" XAUTHORITY="$src_auth" xauth nlist "$disp" 2>/dev/null \
            | sed -e 's/^..../ffff/' \
            | XAUTHORITY="$out" xauth nmerge - 2>/dev/null || true
        # Also try without screen suffix
        local bare="${disp%%.*}"
        if [[ "$bare" != "$disp" ]]; then
            DISPLAY="$disp" XAUTHORITY="$src_auth" xauth nlist "$bare" 2>/dev/null \
                | sed -e 's/^..../ffff/' \
                | XAUTHORITY="$out" xauth nmerge - 2>/dev/null || true
        fi
    fi

    # Still empty? copy source as last resort
    if [[ ! -s "$out" ]]; then
        cp -f "$src_auth" "$out"
        chmod 666 "$out"
    fi
    echo "$out"
}

allow_x11_clients() {
    local disp="$1"
    if command -v xhost >/dev/null 2>&1; then
        DISPLAY="$disp" xhost +local: >/dev/null 2>&1 || true
        DISPLAY="$disp" xhost +SI:localuser:root >/dev/null 2>&1 || true
        DISPLAY="$disp" xhost +SI:localuser:"${USER}" >/dev/null 2>&1 || true
    fi
}

KAS_BIN="$(find_kas_container)"

if [[ ! -f "${ROOT}/kas/core-rdk-qemuarm.yml" ]]; then
    echo "error: missing kas/core-rdk-qemuarm.yml" >&2
    exit 1
fi

if [[ "$MODE" == gtk ]]; then
    if ! qemu_has_gtk; then
        echo "error: qemu-system-native has no gtk+ display backend yet." >&2
        echo "       Rebuild with: kas-container shell kas/core-rdk-qemuarm.yml -c \\" >&2
        echo "         'bitbake qemu-system-native qemu-helper-native'" >&2
        echo "       (kas/include/repos-core.yml now enables PACKAGECONFIG gtk+)." >&2
        echo "       Meanwhile use: ./scripts/start-qemu.sh --vnc" >&2
        exit 1
    fi
    if ! DISPLAY_RESOLVED="$(resolve_display)"; then
        echo "error: no X11 DISPLAY (set DISPLAY or start XFCE)." >&2
        exit 1
    fi
    export DISPLAY="${DISPLAY_RESOLVED}"
    if ! XAUTH_SRC="$(resolve_xauthority "${DISPLAY}")"; then
        echo "error: no XAUTHORITY for ${DISPLAY} (NoMachine/XFCE session cookie)." >&2
        exit 1
    fi
    DOCKER_XAUTH="$(prepare_docker_xauth "${DISPLAY}" "${XAUTH_SRC}")"
    allow_x11_clients "${DISPLAY}"
    echo "X11:     DISPLAY=${DISPLAY}  XAUTHORITY=${XAUTH_SRC}"
    echo "         docker xauth -> ${DOCKER_XAUTH}"
fi

# runqemu machine args
RUNQEMU_ARGS=(qemuarm slirp)

RUNTIME_ARGS=()
# SSH port publish only when not using --network=host (gtk mode).
if [[ "$MODE" != gtk ]]; then
    RUNTIME_ARGS+=(-p "${SSH_HOST_PORT}:2222")
fi

case "$MODE" in
    serial)
        RUNQEMU_ARGS+=(nographic)
        ;;
    vnc)
        # Phase-1 qemu-native: egl-headless + vnc (no gtk/sdl window).
        RUNQEMU_ARGS+=(egl-headless publicvnc)
        RUNTIME_ARGS+=(-p "${VNC_HOST_PORT}:5900")
        ;;
    gtk)
        RUNQEMU_ARGS+=(gtk)
        # Keep guest serial on stdio, not mon:vc. Otherwise the GTK window
        # defaults to the serial VC (blinking cursor) instead of virtio-gpu.
        RUNQEMU_ARGS+=(serialstdio)
        # Default to virgl with GTK so Westeros can page-flip on virtio-gpu-gl.
        if [[ "$WANT_GL" -eq -1 || "$WANT_GL" -eq 1 ]]; then
            RUNQEMU_ARGS+=(gl)
        elif [[ "$WANT_GL" -eq 2 ]]; then
            RUNQEMU_ARGS+=(gl-es)
        fi
        # kas-container runs as root; use FamilyWild xauth + host IPC for MIT-SHM.
        RUNTIME_ARGS+=(
            --network=host
            --ipc=host
            -e "DISPLAY=${DISPLAY}"
            -e "XAUTHORITY=${DOCKER_XAUTH}"
            -e "QT_X11_NO_MITSHM=1"
            -v /tmp/.X11-unix:/tmp/.X11-unix
            -v "${DOCKER_XAUTH}:${DOCKER_XAUTH}:rw"
            -v /dev/dri:/dev/dri
            --group-add=video
        )
        ;;
esac

QEMUPARAMS=()
if [[ "$SNAPSHOT" -eq 1 ]]; then
    QEMUPARAMS+=(-snapshot)
fi
if [[ ${#EXTRA_QEMUPARAMS[@]} -gt 0 ]]; then
    QEMUPARAMS+=("${EXTRA_QEMUPARAMS[@]}")
fi

if [[ ${#QEMUPARAMS[@]} -gt 0 ]]; then
    QEMUPARAMS_STR=$(printf '%s ' "${QEMUPARAMS[@]}")
    QEMUPARAMS_STR="${QEMUPARAMS_STR% }"
    RUNQEMU_ARGS+=("qemuparams=${QEMUPARAMS_STR}")
fi

echo "Image:   KAS_CONTAINER_IMAGE=${KAS_CONTAINER_IMAGE}"
echo "Kas:     ${KAS_BIN}"
echo "Mode:    ${MODE}"
echo "SSH:     localhost:${SSH_HOST_PORT}  -> guest :22  (root, empty password)"
if [[ "$MODE" == vnc ]]; then
    echo "VNC:     localhost:${VNC_HOST_PORT}  -> guest :5900"
    echo "         e.g. remote-viewer vnc://localhost:${VNC_HOST_PORT}"
elif [[ "$MODE" == gtk ]]; then
    echo "DISPLAY: ${DISPLAY}"
fi
echo "runqemu: ${RUNQEMU_ARGS[*]}"
echo

RUNTIME_ARGS_STR=$(printf '%q ' "${RUNTIME_ARGS[@]}")
RUNTIME_ARGS_STR="${RUNTIME_ARGS_STR% }"

RUNQEMU_JOINED=$(printf '%q ' "${RUNQEMU_ARGS[@]}")
RUNQEMU_JOINED="${RUNQEMU_JOINED% }"

# kas shell sanitizes the environment (drops DISPLAY/XAUTHORITY), so export
# X11 vars inside the -c script rather than relying on docker -e alone.
if [[ "$MODE" == gtk ]]; then
    INNER=$(printf 'export DISPLAY=%q XAUTHORITY=%q QT_X11_NO_MITSHM=1 GDK_BACKEND=x11; cd /work/build && exec runqemu %s' \
        "${DISPLAY}" "${DOCKER_XAUTH}" "${RUNQEMU_JOINED}")
else
    INNER="cd /work/build && exec runqemu ${RUNQEMU_JOINED}"
fi

exec "${KAS_BIN}" \
    --runtime-args "${RUNTIME_ARGS_STR}" \
    shell kas/core-rdk-qemuarm.yml \
    -c "${INNER}"
