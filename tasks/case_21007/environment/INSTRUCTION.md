# case_21007: AXI4 Crossbar QoS-Aware Arbitration, Starvation-Bounded Ageing, and High-QoS Reserve Admission

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `alexforencich/verilog-axi` (`repo_40`)
> - **Engineering Problem Type**: `New ISA & Subsystem Feature Implementation` (`PT2_New_Feature_ISA_Impl`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `code/axi_crossbar.v`, `code/axi_crossbar_addr.v`, `code/axi_crossbar_rd.v`, `code/axi_crossbar_wr.v`, `code/arbiter.v`

---

## Problem Specification

# Add QoS-aware arbitration, starvation-bounded ageing, and high-QoS reserve admission to the AXI4 crossbar

`axi_crossbar` currently accepts 4-bit `s_axi_awqos` and `s_axi_arqos` signals on its slave ports (`0 .. S_COUNT-1`), but ignores them during master-port contention and slave-port admission, leaves the top-level `M_*_REG_TYPE` slice parameters disconnected from `axi_crossbar_wr` / `axi_crossbar_rd`, and allows decode-error (`DECERR`) completions to underflow slave in-flight tracking or bypass earlier in-flight transactions sharing the same AXI ID.

Implement AMBA AXI4 QoS-aware scheduling, bounded ageing promotion, and high-QoS reserve admission across `code/axi_crossbar.v`, `code/axi_crossbar_addr.v`, `code/axi_crossbar_rd.v`, `code/axi_crossbar_wr.v`, and `code/arbiter.v`:

1. **Effective QoS Arbitration & Per-Level Round-Robin Fairness**: On each master output interface (`0 .. M_COUNT-1`) for both read (`AR`) and write (`AW`/`W`) channels, grant access to the contending slave port with the highest effective 4-bit QoS (`4'h0` lowest, `4'hF` highest). Break ties among contenders sharing the same effective QoS level using fair round-robin per effective QoS level so that grants won at higher effective QoS levels do not reset or bias the round-robin turn order of lower-QoS levels. Always forward the originating slave port's unmodified `s_axi_awqos` / `s_axi_arqos` value onto `m_axi_awqos` / `m_axi_arqos`, maintain strict `AW`/`W` grant order alignment across multi-beat bursts and downstream stalls, forward all `M_*_REG_TYPE` parameters from `axi_crossbar` to its read/write channel instances, and preserve AXI4 valid/payload stability whenever a valid channel is stalled.
2. **Starvation-Bounded Ageing Promotion (`AGEING_LIMIT`)**: When `AGEING_LIMIT == 0`, disable ageing promotion (strict effective QoS priority). When `AGEING_LIMIT > 0`, track starvation independently per master output interface on both read and write channels: if a slave port has a decoded request pending for a master output interface and remains ungranted while `AGEING_LIMIT` arbitration grants on that same master output interface are awarded to other ports, promote that contender's effective arbitration QoS on that master output interface to `4'hF` until its pending request is granted and acknowledged (retaining accumulated wait count across multi-beat `W` bursts or `M_ISSUE` stalls, and clearing it once granted or when no request is pending).
3. **High-QoS Reserve Admission (`HIGH_QOS_MIN`, `QOS_RESERVE`) & Decode-Error Ordering**: On each slave input interface (`0 .. S_COUNT-1`), reserve `QOS_RESERVE` in-flight slots below `S_ACCEPT` (`0 <= QOS_RESERVE < S_ACCEPT`) for high-QoS requests (`qos >= HIGH_QOS_MIN`). Admit normal-QoS requests (`qos < HIGH_QOS_MIN`) only when the port's effective in-flight count (accounting for any same-cycle transaction completion) is strictly less than `S_ACCEPT - QOS_RESERVE`, while admitting high-QoS requests (`qos >= HIGH_QOS_MIN`) whenever the effective in-flight count is strictly less than `S_ACCEPT`. Ensure unmapped, disconnected (`M_CONNECT_*`), or security-rejected (`M_SECURE`) transactions returning `DECERR` (`2'b11`) properly increment/decrement slave in-flight counters without underflow and obey `S_THREADS` same-ID ordering with respect to in-flight mapped transactions.

---

## Build, Simulation, and EDA Verification Instructions

The AXI4 crossbar RTL in `code/` comes from `alexforencich/verilog-axi` commit `516bd5dadc3365b7f9e225d2af8fe0b8d804fe53` (`code/COPYING`, MIT License), with `AGEING_LIMIT`, `HIGH_QOS_MIN`, and `QOS_RESERVE` parameter stubs exposed on `axi_crossbar`, `axi_crossbar_wr`, `axi_crossbar_rd`, and `axi_crossbar_addr`.

Editable files:
- `code/axi_crossbar.v`
- `code/axi_crossbar_addr.v`
- `code/axi_crossbar_rd.v`
- `code/axi_crossbar_wr.v`
- `code/arbiter.v`

Read-only support files (must remain unmodified):
- `code/axi_register_rd.v`
- `code/axi_register_wr.v`
- `code/priority_encoder.v`
- `code/COPYING`

For quick local elaboration, simulation, and latch-free synthesis checks from the workspace root:
```bash
# Icarus Verilog compilation check
iverilog -g2012 -o /tmp/xbar_chk.vvp code/*.v

# Verilator lint/elaboration check
verilator --lint-only -Wno-fatal --top-module axi_crossbar code/*.v

# Yosys elaboration and latch-free check
yosys -p "read_verilog code/*.v; chparam -set S_COUNT 4 -set M_COUNT 2 -set AGEING_LIMIT 4 -set HIGH_QOS_MIN 8 -set QOS_RESERVE 2 axi_crossbar; hierarchy -check -top axi_crossbar; proc; opt; check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH* t:DLL_* t:DLH_*"
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/axi_crossbar.v`
- `code/axi_crossbar_addr.v`
- `code/axi_crossbar_rd.v`
- `code/axi_crossbar_wr.v`
- `code/arbiter.v`

All other files in the workspace are read-only reference context and must remain unmodified.
