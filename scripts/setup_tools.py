#!/usr/bin/env python3
"""Configure or auto-discover local EDA tools for SiliconBench (Harbor Edition).

When running outside the prebuilt `siliconbench-eda:1.0` Docker container, this script
populates `<repo_root>/environments/tools/` with symlinks to EDA binaries installed on
your system `$PATH` (or from `--from-dir /path/to/tools`), matching the unified directory
structure used by all 94 task graders.

Usage:
    # Auto-discover tools from system PATH / standard prefixes:
    python3 scripts/setup_tools.py

    # Link from an existing prebuilt tools directory:
    python3 scripts/setup_tools.py --from-dir /path/to/eda-tools
"""
import argparse
import os
import pathlib
import shutil
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
DEST_TOOLS = REPO_ROOT / "environments/tools"
DEST_NANGATE = REPO_ROOT / "environments/pdk/Nangate45"


def find_binary(name: str, extra_dirs: list[pathlib.Path]) -> pathlib.Path | None:
    for d in extra_dirs:
        cand = d / name
        if cand.is_file() and os.access(cand, os.X_OK):
            return cand.resolve()
    w = shutil.which(name)
    if w:
        return pathlib.Path(w).resolve()
    for std in (
        pathlib.Path("/opt/siliconbench/tools"),
        pathlib.Path("/opt/oss-cad-suite"),
        pathlib.Path.home() / ".local/siliconbench-tools",
    ):
        for sub in ("bin", "oss-cad-suite/bin", "verilator-v5.038/bin", "iverilog-v13/bin", "openroad-runtime/usr/bin"):
            cand = std / sub / name
            if cand.is_file() and os.access(cand, os.X_OK):
                return cand.resolve()
    return None


def link_force(src: pathlib.Path, dst: pathlib.Path):
    try:
        if dst.exists() and dst.resolve() == src.resolve():
            return
    except OSError:
        pass
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.is_symlink() or dst.exists():
        if dst.is_dir() and not dst.is_symlink():
            shutil.rmtree(dst)
        else:
            dst.unlink()
    dst.symlink_to(src)


def main():
    ap = argparse.ArgumentParser(description="Setup local EDA toolchain symlinks in environments/tools/")
    ap.add_argument("--from-dir", default=os.environ.get("SILICONBENCH_TOOLS_SOURCE", ""), help="Source EDA tools root directory")
    ap.add_argument("--quiet", action="store_true", help="Suppress status output")
    args = ap.parse_args()

    extra_dirs: list[pathlib.Path] = []
    src_root = pathlib.Path(args.from_dir).resolve() if args.from_dir else None
    if src_root and src_root.is_dir():
        for rel in (
            "bin",
            "verilator-v5.038/bin",
            "iverilog-v13/bin",
            "oss-cad-suite/bin",
            "openroad-runtime/usr/bin",
        ):
            if (src_root / rel).is_dir():
                extra_dirs.append(src_root / rel)

    # If src_root has complete subdirectories, symlink them directly
    # Keep DEST_TOOLS/bin as a real directory of per-binary symlinks so adding wrappers (e.g. bin/sta) never mutates src_root.
    if src_root and src_root.is_dir():
        DEST_TOOLS.mkdir(parents=True, exist_ok=True)
        for sub in ("verilator-v5.038", "iverilog-v13", "oss-cad-suite", "openroad-runtime"):
            if (src_root / sub).exists():
                link_force(src_root / sub, DEST_TOOLS / sub)
        if (src_root / "bin").is_dir():
            bin_dir = DEST_TOOLS / "bin"
            if bin_dir.is_symlink():
                bin_dir.unlink()
            bin_dir.mkdir(parents=True, exist_ok=True)
            for item in (src_root / "bin").iterdir():
                link_force(item, bin_dir / item.name)

    # If oss-cad-suite or iverilog-v13 were discovered from PATH, link their suite roots / lib dirs
    yosys_cand = find_binary("yosys", extra_dirs)
    if yosys_cand and (yosys_cand.parent.parent / "libexec").is_dir() and not (DEST_TOOLS / "oss-cad-suite").is_symlink():
        link_force(yosys_cand.parent.parent, DEST_TOOLS / "oss-cad-suite")

    iv_cand = find_binary("iverilog", extra_dirs)
    if iv_cand and (iv_cand.parent.parent / "lib/ivl").is_dir() and not (DEST_TOOLS / "iverilog-v13").is_symlink():
        link_force(iv_cand.parent.parent, DEST_TOOLS / "iverilog-v13")

    # Also ensure individual tool symlinks exist for system PATH discovery
    verilator_bin = find_binary("verilator", extra_dirs)
    if verilator_bin:
        if not (DEST_TOOLS / "verilator-v5.038/bin/verilator").exists():
            link_force(verilator_bin, DEST_TOOLS / "verilator-v5.038/bin/verilator")
        if not (DEST_TOOLS / "oss-cad-suite/bin/verilator").exists():
            link_force(verilator_bin, DEST_TOOLS / "oss-cad-suite/bin/verilator")
        # Link verilator_bin's sibling tools & share/verilator if not already linked
        for sib in verilator_bin.parent.glob("verilator*"):
            if not (DEST_TOOLS / "verilator-v5.038/bin" / sib.name).exists():
                link_force(sib, DEST_TOOLS / "verilator-v5.038/bin" / sib.name)
        share_cand = verilator_bin.parent.parent / "share/verilator"
        if share_cand.is_dir() and not (DEST_TOOLS / "verilator-v5.038/share/verilator").exists():
            link_force(share_cand, DEST_TOOLS / "verilator-v5.038/share/verilator")

    for iv_tool in ("iverilog", "vvp", "iverilog-vpi"):
        b = find_binary(iv_tool, extra_dirs)
        if b and not (DEST_TOOLS / f"iverilog-v13/bin/{iv_tool}").exists():
            link_force(b, DEST_TOOLS / f"iverilog-v13/bin/{iv_tool}")

    for oss_tool in ("yosys", "yosys-abc", "yosys-smtbmc", "yosys-config", "sby", "slang", "z3", "bitwuzla"):
        b = find_binary(oss_tool, extra_dirs)
        if b and not (DEST_TOOLS / f"oss-cad-suite/bin/{oss_tool}").exists():
            link_force(b, DEST_TOOLS / f"oss-cad-suite/bin/{oss_tool}")

    openroad_bin = find_binary("openroad", extra_dirs)
    if openroad_bin and not (DEST_TOOLS / "bin/openroad").exists():
        link_force(openroad_bin, DEST_TOOLS / "bin/openroad")

    sta_bin = find_binary("sta", extra_dirs)
    if sta_bin and not (DEST_TOOLS / "openroad-runtime/usr/bin/sta").exists():
        link_force(sta_bin, DEST_TOOLS / "openroad-runtime/usr/bin/sta")
    if not (DEST_TOOLS / "bin/sta").exists():
        rt_sta = DEST_TOOLS / "openroad-runtime/usr/bin/sta"
        if rt_sta.exists() and (DEST_TOOLS / "openroad-runtime/usr/lib/x86_64-linux-gnu").is_dir():
            (DEST_TOOLS / "bin").mkdir(parents=True, exist_ok=True)
            sta_wrapper = DEST_TOOLS / "bin/sta"
            sta_wrapper.write_text(
                '#!/usr/bin/env bash\n'
                'set -euo pipefail\n'
                'runtime_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../openroad-runtime" && pwd)"\n'
                'export LD_LIBRARY_PATH="$runtime_dir/usr/lib/x86_64-linux-gnu:$runtime_dir/opt/or-tools/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n'
                'exec "$runtime_dir/usr/bin/sta" "$@"\n',
                encoding="utf-8",
            )
            sta_wrapper.chmod(0o755)
        elif sta_bin:
            link_force(sta_bin, DEST_TOOLS / "bin/sta")

    if not args.quiet:
        checks = [
            ("Verilator", DEST_TOOLS / "verilator-v5.038/bin/verilator"),
            ("Icarus Verilog", DEST_TOOLS / "iverilog-v13/bin/iverilog"),
            ("Icarus VVP", DEST_TOOLS / "iverilog-v13/bin/vvp"),
            ("Yosys (+Slang)", DEST_TOOLS / "oss-cad-suite/bin/yosys"),
            ("SymbiYosys", DEST_TOOLS / "oss-cad-suite/bin/sby"),
            ("OpenROAD", DEST_TOOLS / "bin/openroad"),
            ("OpenSTA", DEST_TOOLS / "openroad-runtime/usr/bin/sta"),
            ("Nangate45 PDK", DEST_NANGATE / "lib/NangateOpenCellLibrary_typical.lib"),
        ]
        print(f"SiliconBench Toolchain Status ({DEST_TOOLS}):")
        for label, path in checks:
            status = "READY" if path.exists() else "MISSING (install or build Docker image)"
            print(f"  - {label:18s}: {status} ({path})")


if __name__ == "__main__":
    main()
