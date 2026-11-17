#!/usr/bin/env bash
# Start core-rdk-image under QEMU (GTK + virgl) via kas-container.
#
# Usage:
#   scripts/start-qemu.sh                      # qemuarm (default)
#   scripts/start-qemu.sh --machine qemux86-64
#   scripts/start-qemu.sh --no-snapshot
#   scripts/start-qemu.sh --qemuparams '-smp 2'
#
# Env:
#   KAS_CONTAINER_IMAGE   default: rdk-kas-builder:latest
#   KAS_CONTAINER         path to kas-container (auto-detected)
#   MACHINE               qemuarm | qemux86-64 (overridden by --machine)
#   DISPLAY               auto-detected from /tmp/.X11-unix if unset
#   SSH_HOST_PORT         guest SSH via qemu hostfwd (default 2222; informational)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MACHINE="${MACHINE:-qemuarm}"
SNAPSHOT=1
EXTRA_QEMUPARAMS=()

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --gtk|gtk) ;; # default; accepted for compatibility
        --machine)
            shift
            [[ $# -gt 0 ]] || { echo "error: --machine needs qemuarm or qemux86-64" >&2; exit 2; }
            MACHINE="$1"
            ;;
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

case "$MACHINE" in
    qemuarm)
        KAS_YML="kas/core-rdk-qemuarm.yml"
        QEMU_SYSTEM_NAME="qemu-system-arm"
        ;;
    qemux86-64)
        KAS_YML="kas/core-rdk-qemux86-64.yml"
        QEMU_SYSTEM_NAME="qemu-system-x86_64"
        ;;
    *)
        echo "error: unsupported MACHINE=$MACHINE (use qemuarm or qemux86-64)" >&2
        exit 2
        ;;
esac

KAS_CONTAINER_IMAGE="${KAS_CONTAINER_IMAGE:-rdk-kas-builder:latest}"
export KAS_CONTAINER_IMAGE

SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"

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

# Return 0 if built qemu-system-* lists gtk as a display backend.
qemu_has_gtk() {
    local q
    q="$(find "${ROOT}/build/tmp-glibc/work/x86_64-linux/qemu-helper-native" \
        -type f -name "${QEMU_SYSTEM_NAME}" 2>/dev/null | head -n 1 || true)"
    # Fall back to any built qemu-system-* with gtk (shared PACKAGECONFIG).
    if [[ -z "$q" || ! -x "$q" ]]; then
        q="$(find "${ROOT}/build/tmp-glibc/work/x86_64-linux/qemu-helper-native" \
            -type f -name 'qemu-system-*' 2>/dev/null | head -n 1 || true)"
    fi
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
        nx="$(ls -1 "${HOME}/.nx/node/C-"*-"${num}"-*/authority 2>/dev/null | head -n 1 || true)"
    fi
    if [[ -n "$nx" && -f "$nx" ]]; then
        echo "$nx"
        return
    fi

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

    if command -v xauth >/dev/null 2>&1; then
        DISPLAY="$disp" XAUTHORITY="$src_auth" xauth nlist "$disp" 2>/dev/null \
            | sed -e 's/^..../ffff/' \
            | XAUTHORITY="$out" xauth nmerge - 2>/dev/null || true
        local bare="${disp%%.*}"
        if [[ "$bare" != "$disp" ]]; then
            DISPLAY="$disp" XAUTHORITY="$src_auth" xauth nlist "$bare" 2>/dev/null \
                | sed -e 's/^..../ffff/' \
                | XAUTHORITY="$out" xauth nmerge - 2>/dev/null || true
        fi
    fi

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

if [[ ! -f "${ROOT}/${KAS_YML}" ]]; then
    echo "error: missing ${KAS_YML}" >&2
    exit 1
fi

if ! qemu_has_gtk; then
    echo "error: qemu-system-native has no gtk+ display backend yet." >&2
    echo "       Rebuild with: kas-container shell ${KAS_YML} -c \\" >&2
    echo "         'bitbake qemu-system-native qemu-helper-native'" >&2
    echo "       (kas/include/repos-core.yml enables PACKAGECONFIG gtk+)." >&2
    exit 1
fi

if ! DISPLAY_RESOLVED="$(resolve_display)"; then
    echo "error: no X11 DISPLAY (set DISPLAY or start XFCE/NoMachine)." >&2
    exit 1
fi
export DISPLAY="${DISPLAY_RESOLVED}"

if ! XAUTH_SRC="$(resolve_xauthority "${DISPLAY}")"; then
    echo "error: no XAUTHORITY for ${DISPLAY} (NoMachine/XFCE session cookie)." >&2
    exit 1
fi
DOCKER_XAUTH="$(prepare_docker_xauth "${DISPLAY}" "${XAUTH_SRC}")"
allow_x11_clients "${DISPLAY}"

# serialstdio keeps guest serial on stdio so the GTK window shows the GPU
# framebuffer (otherwise runqemu defaults the window to the serial VC).
RUNQEMU_ARGS=("${MACHINE}" slirp gtk serialstdio gl)

# qemux86-64 without KVM is TCG software emulation — WPE feels unusable.
# Prefer KVM when the host exposes /dev/kvm (pass the device into kas-container).
USE_KVM=0
if [[ "$MACHINE" == "qemux86-64" ]]; then
    if [[ -c /dev/kvm ]]; then
        USE_KVM=1
        RUNQEMU_ARGS+=(kvm)
    else
        echo "warning: /dev/kvm missing; qemux86-64 will use slow TCG emulation" >&2
    fi
fi

RUNTIME_ARGS=(
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
if [[ "$USE_KVM" -eq 1 ]]; then
    # Use numeric GID — kas image often has no "kvm" group name.
    RUNTIME_ARGS+=(--device /dev/kvm --group-add="$(stat -c '%g' /dev/kvm)")
fi

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

echo "X11:     DISPLAY=${DISPLAY}  XAUTHORITY=${XAUTH_SRC}"
echo "         docker xauth -> ${DOCKER_XAUTH}"
echo "Image:   KAS_CONTAINER_IMAGE=${KAS_CONTAINER_IMAGE}"
echo "Kas:     ${KAS_BIN}"
echo "Machine: ${MACHINE}  (${KAS_YML})"
echo "SSH:     localhost:${SSH_HOST_PORT}  -> guest :22  (root, empty password)"
echo "DISPLAY: ${DISPLAY}"
echo "runqemu: ${RUNQEMU_ARGS[*]}"
echo

RUNTIME_ARGS_STR=$(printf '%q ' "${RUNTIME_ARGS[@]}")
RUNTIME_ARGS_STR="${RUNTIME_ARGS_STR% }"

RUNQEMU_JOINED=$(printf '%q ' "${RUNQEMU_ARGS[@]}")
RUNQEMU_JOINED="${RUNQEMU_JOINED% }"

# kas shell sanitizes the environment (drops DISPLAY/XAUTHORITY), so export
# X11 vars inside the -c script rather than relying on docker -e alone.
# kas drops to uid builder without docker --group-add; chmod kvm so os.access works.
KVM_SETUP=""
if [[ "$USE_KVM" -eq 1 ]]; then
    KVM_SETUP='sudo -n chmod 666 /dev/kvm 2>/dev/null || true; '
fi
INNER=$(printf 'export DISPLAY=%q XAUTHORITY=%q QT_X11_NO_MITSHM=1 GDK_BACKEND=x11; %scd /work/build && exec runqemu %s' \
    "${DISPLAY}" "${DOCKER_XAUTH}" "${KVM_SETUP}" "${RUNQEMU_JOINED}")

exec "${KAS_BIN}" \
    --runtime-args "${RUNTIME_ARGS_STR}" \
    shell "${KAS_YML}" \
    -c "${INNER}"
