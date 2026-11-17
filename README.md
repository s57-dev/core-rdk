# RDK Core

Standalone next-generation **Core RDK** build: portable middleware on top of
OSS (poky / OpenEmbedded), authored in `meta-core-rdk`, driven by
[`docs/core-components/core-v-components.json`](docs/core-components/core-v-components.json).

## Decisions

| Item | Choice |
|------|--------|
| Layer | New empty `meta-core-rdk` (recipes re-authored, not copied from RDKE) |
| Distro | `rdk-core` |
| Machine | `qemuarm` (default) or `qemux86-64` |
| BOM | Strict Core-V JSON |
| Exceptions | RDK Logger + Westeros in Core; ignore `InputOutput`; OpenSSL/BlueZ = OSS |

## Layout

```
core-rdk/
├── meta-core-rdk/          # Yocto layer + distro
├── kas/
│   ├── core-rdk-qemuarm.yml
│   ├── core-rdk-qemux86-64.yml
│   ├── patches/qemux86-64/ # x86-only meta-core-rdk patches (via kas)
│   └── include/
│       ├── repos-oss.yml
│       └── repos-core.yml
├── scripts/
│   ├── map-core-v.py       # JSON → BOM status table
│   └── start-qemu.sh       # runqemu wrapper (GTK + virgl)
└── docs/
    ├── bom.md              # generated mapping
    └── core-components/    # Core-V BOM JSON (+ schema)
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

## Build

```bash
export KAS_CONTAINER_IMAGE=rdk-kas-builder:latest   # or your kas image
kas-container build kas/core-rdk-qemuarm.yml      # ARM
kas-container build kas/core-rdk-qemux86-64.yml   # x86-64
```

x86-only changes to `meta-core-rdk` must be kas patches under
`kas/patches/qemux86-64/` (wired from `kas/core-rdk-qemux86-64.yml`), not
committed into the layer.

## Run under QEMU

After a successful build:

```bash
./scripts/start-qemu.sh                         # qemuarm GTK + virgl
./scripts/start-qemu.sh --machine qemux86-64    # x86-64
```

Guest SSH is at `localhost:2222` (root, empty password with debug-tweaks).
