#!/usr/bin/env bash
# One-command installer for SiliconBench pinned open-source EDA toolchain on Ubuntu 22.04+ x86_64.
# Installs into <repo_root>/environments/tools (or $SILICONBENCH_TOOLS) without requiring root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${SILICONBENCH_TOOLS:-${REPO_ROOT}/environments/tools}"
mkdir -p "${PREFIX}/bin" "${PREFIX}/src" "${PREFIX}/downloads"

echo "[1/5] Downloading OSS CAD Suite (2026-10-30) into ${PREFIX}/oss-cad-suite ..."
if [ ! -x "${PREFIX}/oss-cad-suite/bin/yosys" ]; then
    curl -fsSL "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-10-30/oss-cad-suite-linux-x64-20261030.tgz" \
        -o "${PREFIX}/downloads/oss-cad-suite.tgz"
    tar -xzf "${PREFIX}/downloads/oss-cad-suite.tgz" -C "${PREFIX}"
    rm -f "${PREFIX}/downloads/oss-cad-suite.tgz"
fi

echo "[2/5] Building Verilator v5.038 into ${PREFIX}/verilator-v5.038 ..."
if [ ! -x "${PREFIX}/verilator-v5.038/bin/verilator" ]; then
    rm -rf "${PREFIX}/src/verilator"
    git clone --depth 1 --branch v5.038 https://github.com/verilator/verilator.git "${PREFIX}/src/verilator"
    (
        cd "${PREFIX}/src/verilator"
        autoconf
        ./configure --prefix="${PREFIX}/verilator-v5.038"
        make -j"$(nproc)" verilator_exe
        make installbin installdata installredirect
    )
    rm -rf "${PREFIX}/src/verilator"
fi

echo "[3/5] Building Icarus Verilog v13.0 into ${PREFIX}/iverilog-v13 ..."
if [ ! -x "${PREFIX}/iverilog-v13/bin/iverilog" ]; then
    rm -rf "${PREFIX}/src/iverilog"
    git clone --depth 1 --branch v13_0 https://github.com/steveicarus/iverilog.git "${PREFIX}/src/iverilog"
    (
        cd "${PREFIX}/src/iverilog"
        sh autoconf.sh
        ./configure --prefix="${PREFIX}/iverilog-v13"
        make -j"$(nproc)"
        make install
    )
    rm -rf "${PREFIX}/src/iverilog"
fi

echo "[4/5] Installing OpenROAD & OpenSTA (26Q2-1164-g08f67ee5ec) into ${PREFIX}/openroad-runtime ..."
if [ ! -x "${PREFIX}/openroad-runtime/usr/bin/openroad" ] || [ ! -x "${PREFIX}/openroad-runtime/usr/bin/sta" ]; then
    DEB_PATH="${PREFIX}/downloads/openroad_26Q2-1164-g08f67ee5ec_amd64-ubuntu-22.04.deb"
    curl -fsSL "https://vaultlink.precisioninno.com/api/releases/26Q2-1164-g08f67ee5ec/openroad_26Q2-1164-g08f67ee5ec_amd64-ubuntu-22.04.deb/download" \
        -o "${DEB_PATH}"
    mkdir -p "${PREFIX}/openroad-runtime"
    dpkg-deb -x "${DEB_PATH}" "${PREFIX}/openroad-runtime"
    rm -f "${DEB_PATH}"
fi

cat > "${PREFIX}/bin/openroad" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
runtime_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../openroad-runtime" && pwd)"
export LD_LIBRARY_PATH="$runtime_dir/usr/lib/x86_64-linux-gnu:$runtime_dir/opt/or-tools/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$runtime_dir/usr/bin/openroad" "$@"
EOF
chmod +x "${PREFIX}/bin/openroad"

cat > "${PREFIX}/bin/sta" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
runtime_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../openroad-runtime" && pwd)"
export LD_LIBRARY_PATH="$runtime_dir/usr/lib/x86_64-linux-gnu:$runtime_dir/opt/or-tools/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$runtime_dir/usr/bin/sta" "$@"
EOF
chmod +x "${PREFIX}/bin/sta"

echo "[5/5] Verifying toolchain linkage via setup_tools.py ..."
python3 "${REPO_ROOT}/scripts/setup_tools.py" --from-dir "${PREFIX}"
echo "Done! All tools configured in ${PREFIX}."
