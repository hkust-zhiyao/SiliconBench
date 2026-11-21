# case_21023: Parametric Hardware ARP/INARP Offload Wide-Bus Framing, Cache Read-During-Write Coherence, RFC 826 Selective Learning, and TX Arbitration

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `corundum/corundum` (`repo_39`)
> - **Engineering Problem Type**: `New ISA & Subsystem Feature Implementation` (`PT2_New_Feature_ISA_Impl`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/arp.v`, `code/arp_cache.v`, `code/arp_eth_rx.v`, `code/arp_eth_tx.v`

---

## Problem Specification

# Parametric Hardware ARP/INARP Offload Wide-Bus Framing, Cache Coherence, RFC 826 Selective Learning, and TX Arbitration

## Problem Description
In our SmartNIC IPv4 ARP/INARP offload subsystem (`arp_eth_rx`, `arp_eth_tx`, `arp_cache`, and `arp`), wide-bus synthesis (`DATA_WIDTH >= 256`), IEEE 802.3 L2-padded/malformed frame injection, concurrent lookup/reply traffic, and backpressure stress testing exposed defects across all four modules:

1. **`arp_eth_rx` & `arp_eth_tx` Wide-Bus (`DATA_WIDTH = 8..512`), Padding, `tkeep`/`tuser` & `busy` Framing**:
   - Support parametric `DATA_WIDTH` across both multi-beat (`DATA_WIDTH = 64`) and single-beat (`DATA_WIDTH = 256`, `CYCLE_COUNT == 1`) interfaces without zero-width pointer elaboration or wrap-around bugs.
   - In `arp_eth_rx`, require all 28 ARP header octets (`0..27`) to arrive in the first `CYCLE_COUNT` beats with every ARP header byte lane enabled (`s_eth_payload_axis_tkeep == {KEEP_WIDTH{1'b1}}` on beats `< CYCLE_COUNT - 1` and `s_eth_payload_axis_tkeep[(27 % BYTE_LANES):0]` all `1`s on beat `CYCLE_COUNT - 1` when `KEEP_ENABLE != 0`); ignore and drain trailing L2 pad octets beyond byte 27 (unused upper lanes on beat `CYCLE_COUNT - 1` and extra pad beats up to `s_eth_payload_axis_tlast`) without overwriting parsed header fields, and keep `busy` asserted from accepting `s_eth_hdr_valid && s_eth_hdr_ready` until accepting `s_eth_payload_axis_tlast`.
   - At `s_eth_payload_axis_tlast` in `arp_eth_rx`:
     - If fewer than 28 contiguous kept ARP header octets arrived (premature `tlast` or any `tkeep == 0` lane in offsets `0..27`), pulse `error_header_early_termination` for 1 cycle and suppress `m_frame_valid` and `error_invalid_header`.
     - Else if `m_arp_hlen != 8'd6` or `m_arp_plen != 8'd4`, pulse `error_invalid_header` for 1 cycle and suppress `m_frame_valid`.
     - Else if `s_eth_payload_axis_tuser` asserted on **any** beat of the Ethernet payload (header or trailing pad beats), suppress `m_frame_valid` without pulsing error outputs; otherwise assert `m_frame_valid`.
2. **`arp_cache` Backpressure Stability, Read-During-Write Forwarding & `clear_cache` Synchronization**:
   - Hold `query_response_valid`, `query_response_error`, and `query_response_mac` constant while `query_response_valid && !query_response_ready`, never allowing a queued query to overwrite `query_response_*` (even when `query_request_valid` deasserts).
   - Provide coherent write-to-query forwarding: a `query_request` accepted on the same cycle as (or after) an accepted `write_request` targeting the same hash bucket must observe the newly written `(write_request_ip, write_request_mac)` state (hit with the new MAC if `query_request_ip == write_request_ip`, or miss if overwritten by a colliding IP) rather than stale RAM contents.
   - Immediately deassert `query_request_ready` and `write_request_ready` when `clear_cache` asserts and throughout the `2**CACHE_ADDR_WIDTH`-entry clear sweep so no new write or query is accepted during a clear (any already-accepted stage-1 write prior to `clear_cache` is invalidated by the clear, while any already-accepted stage-1 query still completes its `query_response`).
3. **`arp` Destination Routing, RFC 826 / RFC 5227 Selective Learning, TX Arbitration & Lookup Control**:
   - **Destination classification (`arp_request`)**: Return `48'hFFFF_FFFF_FFFF` (`error = 0`) immediately for limited broadcast (`32'hFFFF_FFFF`) or subnet-directed broadcast (`subnet_mask != 32'hFFFF_FFFF`, `((arp_request_ip ^ local_ip) & subnet_mask) == 32'd0`, and `(arp_request_ip | subnet_mask) == 32'hFFFF_FFFF`); return RFC 1112 multicast `{24'h01_00_5E, 1'b0, arp_request_ip[22:0]}` (`error = 0`) immediately for `arp_request_ip[31:28] == 4'hE`; resolve `arp_request_ip` directly when on-subnet (`((arp_request_ip ^ local_ip) & subnet_mask) == 32'd0`); when off-subnet, return `error = 1` immediately if `gateway_ip == 32'd0`, else resolve `gateway_ip`.
   - **Incoming validation, reply & RFC 826 selective learning**: Process only valid Ethernet/IPv4 ARP/INARP frames (`eth_type == 16'h0806`, `htype == 16'h0001`, `ptype == 16'h0800`, `oper` in `{16'h0001, 16'h0002, 16'h0008, 16'h0009}`). Transmit an ARP Reply (`oper = 16'h0002`) on `oper == 16'h0001 && tpa == local_ip` and an INARP Reply (`oper = 16'h0009`) on `oper == 16'h0008 && tha == local_mac` whenever `sha` is a valid unicast MAC (`sha != 48'd0 && !sha[40]`), including RFC 5227 ARP Probes (`spa == 32'd0`). Learn `(spa, sha)` into `arp_cache` **only** when `spa` is unicast IPv4 (`spa != 32'd0`, `spa != 32'hFFFF_FFFF`, `spa[31:28] != 4'hE`) and `sha` is unicast MAC (`sha != 48'd0 && !sha[40]`): insert/update unconditionally when the frame targets this host (`tpa == local_ip` for `oper` `1`/`2`, or `tha == local_mac` for `oper` `8`/`9`) or `spa` matches the active pending lookup target IP; for non-targeted frames (e.g., Gratuitous ARP or third-party broadcasts), update `arp_cache` **only if** `spa` is already cached so unrelated ARP traffic cannot evict colliding hash buckets.
   - **TX arbitration, retries & handshakes**: Arbitrate outgoing ARP/INARP Replies vs broadcast ARP Requests without dropping either frame or mutating `arp_eth_tx` `s_frame_*` while `s_frame_valid && !s_frame_ready`, and accept incoming non-reply frames even when `arp_eth_tx` is stalled. Support `REQUEST_RETRY_COUNT >= 1` total broadcast request transmissions per uncached lookup (`1` initial request plus `REQUEST_RETRY_COUNT - 1` retries at `REQUEST_RETRY_INTERVAL`, then `REQUEST_TIMEOUT` after the final request, including `REQUEST_RETRY_COUNT == 1` waiting `REQUEST_TIMEOUT` with zero retries), give a resolved cache hit/wakeup priority over `arp_request_timer == 0` on the same cycle, honor `arp_cache` ready signals across `rst`/`clear_cache`, and hold `arp_response_mac`/`arp_response_error` stable while `arp_response_valid && !arp_response_ready`.
4. **Synthesis & Gate-Level Reset Cleanliness**: Synthesize latch-free and combinational-loop-free across `DATA_WIDTH = 64` and `256`, with `0` `X`/`Z` on valid/ready/busy/error outputs and active qualifiers after `rst` when declaration initializers and `initial` blocks are stripped.

## Boundary Contract
Preserve all existing module names, parameters, and port signatures across `code/arp.v`, `code/arp_cache.v`, `code/arp_eth_rx.v`, and `code/arp_eth_tx.v` (`code/lfsr.v` and `code/LICENSE` are read-only).

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Reference

## Workspace Files
- **Editable RTL**:
  - `code/arp.v` (`arp`)
  - `code/arp_cache.v` (`arp_cache`)
  - `code/arp_eth_rx.v` (`arp_eth_rx`)
  - `code/arp_eth_tx.v` (`arp_eth_tx`)
- **Read-Only Collateral**:
  - `code/lfsr.v` (`lfsr`)
  - `code/LICENSE`

## Toolchain Commands
1. **Icarus Verilog (`iverilog` v13)**:
   ```bash
   iverilog -g2012 \
     -o sim.vvp code/arp.v code/arp_cache.v code/arp_eth_rx.v code/arp_eth_tx.v code/lfsr.v <your_tb.sv>
   vvp sim.vvp
   ```
2. **Verilator (`verilator` v5.038)**:
   ```bash
   env -u VERILATOR_ROOT verilator \
     --binary --timing -Wno-fatal -j 1 --top-module <your_tb> \
     code/arp.v code/arp_cache.v code/arp_eth_rx.v code/arp_eth_tx.v code/lfsr.v <your_tb.sv>
   ```
3. **Yosys Latch / Loop / Gate-Level Netlist Check**:
   ```bash
   yosys -p "
     read_verilog -defer code/arp.v code/arp_cache.v code/arp_eth_rx.v code/arp_eth_tx.v code/lfsr.v;
     hierarchy -check -top arp -chparam DATA_WIDTH 256 -chparam CACHE_ADDR_WIDTH 3;
     proc; opt_expr; opt_clean; setattr -unset init w:*; flatten; opt_expr; opt_clean;
     select -assert-none t:\$dlatch* t:\$_DLATCH*;
     synth -top arp;
     check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH*;
     write_verilog -noattr netlist.v"
   ```

## Implementation Notes
- Editable RTL must remain pure synthesizable Verilog-2001/SystemVerilog: do **not** add new simulation-control or file-I/O system tasks (such as `$finish`, `$stop`, `$fatal`, `$readmem*`, or `$system`, including inside `initial` parameter-check blocks — preserve or omit existing parameter checks rather than adding new `$finish`/`$stop` calls), `force`/`release` statements, or simulator/synthesis conditional compilation macros (`ifdef SYNTHESIS`, `ifdef VERILATOR`, `ifdef __ICARUS__`).

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/arp.v`
- `code/arp_cache.v`
- `code/arp_eth_rx.v`
- `code/arp_eth_tx.v`

All other files in the workspace are read-only reference context and must remain unmodified.
