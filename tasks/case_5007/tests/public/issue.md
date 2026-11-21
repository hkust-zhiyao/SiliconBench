# CVA6 Non-Blocking DCache SRAM Arbiter Exclusivity, Pipelined Store/Kill Handshake, Multi-Way Eviction/AMO Completion, and Area/Timing Closure

In the CVA6 non-blocking L1 data cache subsystem (`code/std_nbdcache.sv`, `code/cache_ctrl.sv`, `code/miss_handler.sv`, and `code/tag_cmp.sv`), concurrent port arbitration, pipelined load-to-store requests, killed cache misses, multi-way flushes/evictions, and 32-bit atomic operations fail under verification and synthesis/timing sign-off:

1. **SRAM arbiter grant exclusivity and idle behavior (`code/tag_cmp.sv`)**:
   - Across the `NR_PORTS` cache ports (`0` highest priority to `NR_PORTS-1` lowest priority), `tag_cmp` must grant at most one requesting port per cycle (`$onehot0(gnt_o)`) and select that port's tag on the following cycle. Idle higher-priority ports (`req_i[k] == '0`) must never receive `gnt_o[k] = 1'b1` when a lower-priority port requests, and when all ports are idle (`req_i == '0`) `gnt_o`, `req_o`, and `we_o` must remain deasserted with no hit reported on the next cycle.

2. **Pipelined store double-grant, flush-gated speculative reads, and ungranted killed miss cancellation (`code/cache_ctrl.sv`)**:
   - Read requests receive `req_port_o.data_gnt = 1'b1` upon SRAM read acceptance, whereas write requests (`req_port_i.data_we == 1'b1`) must only receive `req_port_o.data_gnt = 1'b1` when the write completes in the store stage or is accepted by the miss/bypass unit. Currently, when a write request is presented on `req_port_i` on the cycle a preceding load hits or receives its critical word, `cache_ctrl` asserts `req_port_o.data_gnt = 1'b1` prematurely and then grants the same write a second time when it completes.
   - While waiting for a refill critical word, speculative SRAM read requests for a new `req_port_i.data_req` must be suppressed when `flush_i` is asserted.
   - If `req_port_i.kill_req` is asserted while waiting for a refill/bypass grant and the miss unit has not yet granted or begun serving the port (`!active_serving_i && !miss_gnt_i && !bypass_gnt_i`), `cache_ctrl` must suppress `miss_req_o.valid` (`1'b0`), acknowledge the kill with `req_port_o.data_rvalid = 1'b1`, and return to idle on that cycle.

3. **2-way LFSR sizing, multi-way SRAM requests, flush/AMO priority, and same-cycle 32-bit AMO/bypass completion (`code/miss_handler.sv`)**:
   - The miss handler must elaborate cleanly for `DCACHE_SET_ASSOC = 2` as well as `4`, drive `req_o` across all ways (`'1`) during cache initialization and clean-line flush scans, and drive `req_o` for the evicted way (`evict_way_q`) when clearing status on writeback completion.
   - When `flush_i` and `amo_req_i.req` are both asserted while idle (`!busy_i`), `flush_i` takes precedence and must assert `flush_ack_o` upon completion rather than suppressing `flush_ack_o` as an AMO-internal flush.
   - When an atomic request or bypass arbiter request receives both grant and valid response on the same cycle, 32-bit AMOs (`amo_req_i.size == 2'b10`) must still extract the addressed 32-bit half (`amo_req_i.operand_a[2]`) and sign-extend it to 64 bits on `amo_resp_o.result`, and `axi_adapter_arbiter` must immediately forward the response to the requester and return to idle with zero outstanding count.

4. **Synthesis, area, and timing closure**:
   - Both `std_nbdcache` and `dcache_ctrl_top` (`flow/dcache_ctrl_top.sv`) must synthesize under Yosys + Slang with zero inferred latches.
   - When `dcache_ctrl_top` (`flow/dcache_ctrl_top.sv`) is synthesized against Nangate45 (`lib/NangateOpenCellLibrary_typical.lib`) and timed in OpenROAD/OpenSTA (`lef/NangateOpenCellLibrary.tech.lef`, `lef/NangateOpenCellLibrary.macro.mod.lef`) as documented in `BUILD.md`, mapped cell area must be **`<= 2,825.0 um^2`** and setup/hold slack must be **`>= 0.00 ns`** at a **`2.44 ns`** clock period (`0.20 ns` I/O delays, `5.0 fF` load). Edit only `code/cache_ctrl.sv`, `code/miss_handler.sv`, and `code/tag_cmp.sv`.
