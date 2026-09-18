SUMMARY = "RDK Core middleware package set (strict Core-V BOM)"
DESCRIPTION = "Packages corresponding to middleware entries in \
core-v-components.json. Recipes are added incrementally; empty RDEPENDS \
is valid for Phase 1 boot-only images."

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

ALLOW_EMPTY:${PN} = "1"

# Populated as meta-core-rdk recipes are authored. Keep in sync with
# scripts/map-core-v.py output (status=ported).
RDEPENDS:${PN} = " \
    rdk-logger \
    libsyswrapper \
    libunpriv \
    iarmbus \
    rbus \
"
