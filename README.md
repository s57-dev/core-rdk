# RDK Core

Standalone next-generation **Core RDK** build: portable middleware on top of
OSS (poky / OpenEmbedded), authored in `meta-core-rdk`, driven by
[`../core-v-components.json`](../core-v-components.json).

## Decisions

| Item | Choice |
|------|--------|
| Layer | New empty `meta-core-rdk` (recipes re-authored, not copied from RDKE) |
| Distro | `rdk-core` |
| Machine | `qemuarm` (32-bit ARM) |
| BOM | Strict Core-V JSON |
| Exceptions | RDK Logger + Westeros in Core; ignore `InputOutput`; OpenSSL/BlueZ = OSS |

## Layout

```
core-rdk/
├── meta-core-rdk/          # Yocto layer + distro
├── kas/
│   ├── core-rdk-qemuarm.yml
│   └── include/
│       ├── repos-oss.yml
│       └── repos-core.yml
├── scripts/
│   ├── map-core-v.py       # JSON → BOM status table
│   └── start-qemu.sh       # runqemu wrapper (serial / VNC / GTK)
└── docs/bom.md             # generated mapping
```

## Prerequisites

- Docker
- Python 3 + venv + [kas](https://kas.readthedocs.io/)

```bash
python3 -m venv venv
source venv/bin/activate
pip install 'kas>=4.0'
```

Use a Yocto-capable container image (for example the monorepo `rdk-kas-builder:latest`,
or ghcr.io/siemens/kas).

## BOM map

```bash
python3 scripts/map-core-v.py --markdown docs/bom.md
```

## Build (Phase 1 — boot image)

```bash
export KAS_CONTAINER_IMAGE=rdk-kas-builder:latest   # or your kas image
kas-container build kas/core-rdk-qemuarm.yml
```

## Run under QEMU

After a successful build:

```bash
./scripts/start-qemu.sh              # serial console (default)
./scripts/start-qemu.sh --gtk        # X11 GTK window (auto-detects DISPLAY, e.g. :1002)
./scripts/start-qemu.sh --vnc        # headless EGL + VNC on localhost:5900
```

Guest SSH is forwarded to `localhost:2222` (root, empty password with debug-tweaks).

Or manually:

```bash
export KAS_CONTAINER_IMAGE=rdk-kas-builder:latest
kas-container shell kas/core-rdk-qemuarm.yml -c 'runqemu qemuarm nographic slirp'
```

## Phase 1 scope

- Distro `rdk-core`, image `core-rdk-image`, empty `packagegroup-core-rdk`
- No `meta-rdk` / `meta-rdk-video` / Raspberry Pi vendor layers
- Middleware recipes land incrementally; keep `packagegroup-core-rdk` and
  `scripts/map-core-v.py` in sync
