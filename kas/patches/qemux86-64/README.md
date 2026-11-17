# qemux86-64 patches

x86-only source fixes live here — **not** in `meta-core-rdk`.

Wire them from `kas/core-rdk-qemux86-64.yml`, typically:

```yaml
FILESEXTRAPATHS:prepend:pn-<recipe> = "${TOPDIR}/../kas/patches/qemux86-64:"
SRC_URI:append:pn-<recipe> = " file://0001-....patch"
```

| Patch | Recipe | Why |
|-------|--------|-----|
| `0001-dsDisplay-callback-use-intptr_t-for-LP64.patch` | `devicesettings-hal-headers` | `dsDisplayEventCallback_t` used `int` handle; LP64 needs `intptr_t` |
| `0002-entservices-devicesettings-display-callback-intptr_t.patch` | `entservices-devicesettings` | Wrapper still took `int` after HALIF typedef fix |

Also via `kas/core-rdk-qemux86-64.yml` `local_conf` (not patches): re-enable
gst-plugins-base GL (wayland/egl/gles2/gbm), WPE `USE_GSTREAMER_GL`/`USE_GBM`,
`gstreamer1.0-libav` + VP9 (`commercial` license), and `QB_MEM=4096`.
