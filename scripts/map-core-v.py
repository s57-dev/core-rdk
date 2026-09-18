#!/usr/bin/env python3
"""Map core-v-components.json to proposed Core recipe status.

Reads ../core-v-components.json (sibling of core-rdk/) by default and prints
a BOM table. Exit code 1 if any middleware entry is missing a proposed PN
mapping (except explicitly ignored components).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Components deliberately out of scope for Core (user decision).
IGNORED_NAMES = {
    "entservices-inputoutput",
    "InputOutput",
}

# JSON display-name / repo → proposed BitBake PN (Phase 0 mapping).
# Refine as recipes are authored.
PROPOSED_PN = {
    "AppGateway": "entservices-appgateway",
    "AvOutput": "entservices-avoutput",
    "Bluetooth Manager": "bluetooth-mgr",
    "bluetooth-core": "bluetooth-core",
    "BreakPad": None,  # OSS
    "Casting": "entservices-casting",
    "cimplog": "cimplog",
    "Common Utilities": "commonutilities",
    "Connectivity": "entservices-connectivity",
    "Control Manager (video)": "ctrlm",
    "DBUS": None,  # OSS
    "Device Settings": "devicesettings",
    "DeviceAndDisplay": "entservices-deviceanddisplay",
    "Dobby": "dobby",
    "Dobby Thunder Plugin": "dobby-thunderplugin",
    "Entservices APIs": "entservices-apis",
    "FirmwareDownload": "entservices-firmwaredownload",
    "FirmwareUpdate": "entservices-firmwareupdate",
    "Gstreamer Rialto Plugin": "rialto-gstreamer",
    "HDMI CEC Header": "hdmicecheader",
    "HDMICec": "hdmicec",
    "iarmbus": "iarmbus",
    "Infrastructure Services": "entservices-infra",
    "InputOutput": None,  # ignored
    "libSysCallWrapper": "libsyswrapper",
    "libunpriv": "libunpriv",
    "MediaAndDrm": "entservices-mediaanddrm",
    "memcr": "memcr",
    "new RDK AppManagers components": "entservices-appmanagers",
    "OpenSSL": None,  # OSS
    "PackageManager": "packagemanager",
    "Peripherals": "entservices-peripherals",
    "Protobuf": None,  # OSS
    "RBUS": "rbus",
    "RDK Logger": "rdk-logger",  # in Core despite JSON oss tag
    "RDK V Firmware Upgrader": "rdkfwupdater",
    "RDK Window Manager": "rdk-window-manager",
    "rdkcertconfig": "rdk-cert-config",
    "Remote Feature control": "rfc",
    "Rialto": "rialto",
    "Rialto OCDM": "rialto-ocdm",
    "Rialto Server": "rialto",  # same recipe family
    "RunTime": "entservices-runtime",
    "SoftwareUpdate": "entservices-maintenancemanager",
    "sysint": "sysint",
    "System Time Manager": "systimemgr",
    "Systemd": None,  # OSS
    "telemetry": "telemetry",
    "ThunderJS": "thunderjs",
    "trower-base64": None,  # OSS
    "Wayland": None,  # OSS
    "wdmp-c (WebPA Data model parser)": "wdmp-c",
    "Westeros": "westeros",
    "WPE Client Libraries": "libwpe",
    "WPE WebKit": "wpewebkit",
    "WPEFramework": "wpeframework",
    "WPEFramework UI": "wpeframework-ui",
    "BlueZ": None,  # OSS
}


def load_components(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return data["components"]


def classify(comp: dict) -> str:
    name = comp["name"]
    if name in IGNORED_NAMES or name == "InputOutput":
        return "ignored"
    layer = comp.get("layer", "")
    pn = PROPOSED_PN.get(name, "UNMAPPED")
    if pn is None:
        return "oss-dep"
    if name == "Westeros":
        return "core"  # included in Core
    if name == "RDK Logger":
        return "core"
    if layer == "oss":
        return "oss-dep"
    if layer == "vendor":
        return "core"
    if layer == "middleware":
        return "core"
    return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--json",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "core-v-components.json",
        help="Path to core-v-components.json",
    )
    parser.add_argument(
        "--markdown",
        type=Path,
        default=None,
        help="Optional path to write docs/bom.md",
    )
    args = parser.parse_args()

    if not args.json.is_file():
        print(f"error: BOM file not found: {args.json}", file=sys.stderr)
        return 2

    rows = []
    unmapped = []
    for comp in load_components(args.json):
        name = comp["name"]
        status = classify(comp)
        pn = PROPOSED_PN.get(name, "UNMAPPED")
        if pn == "UNMAPPED" and status not in ("ignored", "oss-dep"):
            unmapped.append(name)
        urls = ", ".join(comp.get("url") or [])
        rows.append(
            {
                "name": name,
                "json_layer": comp.get("layer", ""),
                "category": comp.get("category", ""),
                "pn": pn if pn is not None else "—",
                "status": status,
                "url": urls,
            }
        )

    # Console table
    print(f"{'name':40} {'json_layer':10} {'status':10} {'pn':32}")
    print("-" * 100)
    for r in rows:
        print(f"{r['name'][:40]:40} {r['json_layer'][:10]:10} {r['status'][:10]:10} {str(r['pn'])[:32]:32}")

    core = sum(1 for r in rows if r["status"] == "core")
    oss = sum(1 for r in rows if r["status"] == "oss-dep")
    ignored = sum(1 for r in rows if r["status"] == "ignored")
    print()
    print(f"summary: core={core} oss-dep={oss} ignored={ignored} total={len(rows)}")

    if args.markdown:
        lines = [
            "# Core-V BOM mapping",
            "",
            f"Source: `{args.json}`",
            "",
            "| Component | JSON layer | Status | Proposed PN | URL |",
            "|-----------|------------|--------|-------------|-----|",
        ]
        for r in rows:
            lines.append(
                f"| {r['name']} | {r['json_layer']} | {r['status']} | `{r['pn']}` | {r['url']} |"
            )
        lines.append("")
        lines.append("## Policy")
        lines.append("")
        lines.append("- **core** — recipe lives in `meta-core-rdk`")
        lines.append("- **oss-dep** — consumed from poky / OE / OSS layers (no Core recipe)")
        lines.append("- **ignored** — out of scope (`InputOutput` / entservices-inputoutput)")
        lines.append("- RDK Logger and Westeros are **core** by project decision")
        lines.append("")
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"wrote {args.markdown}")

    if unmapped:
        print("unmapped middleware components:", ", ".join(unmapped), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
