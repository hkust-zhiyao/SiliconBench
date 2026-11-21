# ==============================================================================
# SiliconBench Unified Full-Stack EDA Base Image (siliconbench-eda:1.0)
# Shared across all 94 Harbor tasks across 30 SystemVerilog repositories
# (Phase 1 Offline Solver & Phase 2 Isolated Harbor Verifier)
# ==============================================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# 1. Install standard build, runtime & Python 3 dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc g++ make cmake ninja-build \
    autoconf automake pkg-config help2man libfl2 libfl-dev \
    python3 python3-dev python3-pip python3-venv \
    tcl-dev tk-dev libtcl8.6 libreadline-dev libreadline8 libffi-dev zlib1g-dev \
    libboost-all-dev libeigen3-dev libspdlog-dev \
    libqt5widgets5 libqt5gui5 libqt5core5a libgomp1 \
    bison flex gperf git curl ca-certificates jq \
    && rm -rf /var/lib/apt/lists/*

# 2. Create unified tool & PDK hierarchy at /opt/siliconbench
RUN mkdir -p /opt/siliconbench/tools/bin /opt/siliconbench/pdk/Nangate45 /workspace /tests /logs/verifier

# 3. Copy bundled NanGate45 45nm Open Cell Library (build context: environments/)
COPY pdk/Nangate45/ /opt/siliconbench/pdk/Nangate45/

# 4. Install pinned EDA Tool Suite into /opt/siliconbench/tools:
#    - OSS CAD Suite 2026-10-30 (/opt/siliconbench/tools/oss-cad-suite: yosys, yosys-slang, sby, abc)
#    - Verilator v5.038           (/opt/siliconbench/tools/verilator-v5.038)
#    - Icarus Verilog v13.0       (/opt/siliconbench/tools/iverilog-v13)
#    - OpenROAD & OpenSTA v26Q2   (/opt/siliconbench/tools/openroad-runtime + /opt/siliconbench/tools/bin/{openroad,sta})
RUN curl -fsSL "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-10-30/oss-cad-suite-linux-x64-20261030.tgz" -o /tmp/oss-cad-suite.tgz && \
    tar -xzf /tmp/oss-cad-suite.tgz -C /opt/siliconbench/tools && \
    rm -f /tmp/oss-cad-suite.tgz

RUN git clone --depth 1 --branch v5.038 https://github.com/verilator/verilator.git /tmp/verilator-src && \
    cd /tmp/verilator-src && autoconf && ./configure --prefix=/opt/siliconbench/tools/verilator-v5.038 && \
    make -j"$(nproc)" verilator_exe && make installbin installdata installredirect && \
    rm -rf /tmp/verilator-src

RUN git clone --depth 1 --branch v13_0 https://github.com/steveicarus/iverilog.git /tmp/iverilog-src && \
    cd /tmp/iverilog-src && sh autoconf.sh && ./configure --prefix=/opt/siliconbench/tools/iverilog-v13 && \
    make -j"$(nproc)" && make install && \
    rm -rf /tmp/iverilog-src

RUN curl -fsSL "https://vaultlink.precisioninno.com/api/releases/26Q2-1164-g08f67ee5ec/openroad_26Q2-1164-g08f67ee5ec_amd64-ubuntu-22.04.deb/download" -o /tmp/openroad.deb && \
    mkdir -p /opt/siliconbench/tools/openroad-runtime && \
    dpkg-deb -x /tmp/openroad.deb /opt/siliconbench/tools/openroad-runtime && \
    rm -f /tmp/openroad.deb && \
    printf '#!/usr/bin/env bash\nset -euo pipefail\nrt="/opt/siliconbench/tools/openroad-runtime"\nexport LD_LIBRARY_PATH="$rt/usr/lib/x86_64-linux-gnu:$rt/opt/or-tools/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\nexec "$rt/usr/bin/openroad" "$@"\n' > /opt/siliconbench/tools/bin/openroad && \
    printf '#!/usr/bin/env bash\nset -euo pipefail\nrt="/opt/siliconbench/tools/openroad-runtime"\nexport LD_LIBRARY_PATH="$rt/usr/lib/x86_64-linux-gnu:$rt/opt/or-tools/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\nexec "$rt/usr/bin/sta" "$@"\n' > /opt/siliconbench/tools/bin/sta && \
    chmod +x /opt/siliconbench/tools/bin/openroad /opt/siliconbench/tools/bin/sta && \
    ln -sf /opt/siliconbench/tools/verilator-v5.038/bin/verilator /opt/siliconbench/tools/bin/verilator && \
    ln -sf /opt/siliconbench/tools/iverilog-v13/bin/iverilog /opt/siliconbench/tools/bin/iverilog && \
    ln -sf /opt/siliconbench/tools/iverilog-v13/bin/vvp /opt/siliconbench/tools/bin/vvp && \
    ln -sf /opt/siliconbench/tools/oss-cad-suite/bin/yosys /opt/siliconbench/tools/bin/yosys && \
    ln -sf /opt/siliconbench/tools/oss-cad-suite/bin/sby /opt/siliconbench/tools/bin/sby

ENV SILICONBENCH_TOOLS="/opt/siliconbench/tools"
ENV SILICONBENCH_NANGATE45="/opt/siliconbench/pdk/Nangate45"
ENV PATH="/opt/siliconbench/tools/verilator-v5.038/bin:/opt/siliconbench/tools/iverilog-v13/bin:/opt/siliconbench/tools/oss-cad-suite/bin:/opt/siliconbench/tools/bin:/usr/local/bin:/usr/bin:/bin"

# Deterministic single-thread EDA execution
ENV OMP_NUM_THREADS="1"
ENV OPENBLAS_NUM_THREADS="1"
ENV MKL_NUM_THREADS="1"
ENV MAKEFLAGS="-j1"
ENV CMAKE_BUILD_PARALLEL_LEVEL="1"
ENV PYTHONNOUSERSITE="1"

WORKDIR /workspace
