# CVA6 RV32 Zcmp/Zcmt ID-Stage Macro & Table-Jump Expansion, Pipeline Flush/Backpressure Control, and Synthesis/Timing Closure

## Background

In the 32-bit CVA6 embedded configuration (`RV32IMAC` with `Zcb`, `Zcmp`, and `Zcmt` code-size reduction extensions enabled, `NrIssuePorts = 1`), the Instruction Decode (`id_stage`) subsystem integrates:

- `code/compressed_decoder.sv`: first-pass 16-bit RVC/Zcb decompression and detection of `Zcmp` (`is_macro_instr_o`) and `Zcmt` (`is_zcmt_instr_o`) instructions.
- `code/macro_decoder.sv`: multi-cycle micro-operation sequencer that expands `Zcmp` instructions (`cm.push`, `cm.pop`, `cm.popret`, `cm.popretz`, `cm.mvsa01`, `cm.mva01s`) into a sequence of 32-bit RISC-V store, load, arithmetic (`addi`/`lui`), and return (`jalr x0, x1, 0`) micro-operations.
- `code/zcmt_decoder.sv`: two-state table-jump controller (`IDLE`, `TABLE_JUMP`) that translates `cm.jt` (`index < 32`) and `cm.jalt` (`index >= 32`) into a jump-vector-table (`JVT`) data-cache read request (`{jvt_i.base, 6'b000000} + (index << 2)`) and, upon receiving `req_port_i.data_rvalid`, synthesizes a PC-relative `jal` instruction (`rd = x0` for `cm.jt`, `rd = x1` for `cm.jalt`) with `jump_address_o = ({req_port_i.data_rdata[31:1], 1'b0} - pc_i)`.
- `code/decoder.sv` and `code/id_stage.sv`: full 32-bit instruction decoding, `fetch_entry_ready_o` upstream handshaking, and the `ID <-> Issue` pipeline register (`issue_q[0]`).

During verification and Nangate45 synthesis/STA sign-off of the `id_decode_top` wrapper (`flow/id_decode_top.sv`), several functional, structural, and timing closure issues were identified across `code/macro_decoder.sv`, `code/zcmt_decoder.sv`, and `code/id_stage.sv`.

## Problem Description & Architectural Requirements

1. **Valid-Qualified & Flush-Safe Zcmp/Zcmt Activation and Pipeline Handshaking (`code/id_stage.sv`, `code/macro_decoder.sv`, `code/zcmt_decoder.sv`)**:
   - `compressed_decoder_i` decodes `fetch_entry_i[0].instruction` combinationally regardless of `fetch_entry_valid_i[0]` or `flush_i`. Neither `macro_decoder_i` nor `zcmt_decoder_i` may initiate a sequence or assert a D-Cache table read request (`dcache_req_ports_o.data_req`) when `fetch_entry_valid_i[0]` is deasserted or when `flush_i` is asserted.
   - Whenever `flush_i` is asserted, `id_stage` must not acknowledge/pop the upstream fetch entry (`fetch_entry_ready_o` must remain `'0`), must invalidate `issue_q[0].valid`, and any in-flight `macro_decoder` expansion or `zcmt_decoder` `TABLE_JUMP` lookup must abort cleanly and return to `IDLE` (with `zcmt_decoder` asserting `req_port_o.kill_req = 1'b1` when aborted in `TABLE_JUMP`) so that post-flush instructions decode without residual state corruption.

2. **Micro-Operation Sequencing Under Empty/Full ID-Issue Pipeline Register & Backpressure (`code/macro_decoder.sv`, `code/id_stage.sv`)**:
   - In `id_stage`, a decoded micro-operation at the output of `decoder_i` is latched into the `issue_q[0]` pipeline register whenever `(!issue_q[0].valid || issue_instr_ack_i[0]) && fetch_entry_valid_i[0] && !flush_i`.
   - `macro_decoder` must drive each micro-operation (`instr_o`, `is_last_macro_instr_o`, `is_double_rd_macro_instr_o`, `fetch_stall_o`) combinationally from its current state regardless of whether `issue_ack_i` is currently asserted, and advance its state machine one step per micro-operation accepted into `issue_q[0]`, releasing `fetch_stall_o` (`fetch_entry_ready_o[0] = 1'b1`) only when the final micro-operation of the `Zcmp` sequence is accepted into `issue_q[0]`.
   - Similarly, while `zcmt_decoder` is waiting in `TABLE_JUMP` for `req_port_i.data_rvalid`, it must hold `fetch_stall_o = 1'b1` so `id_stage` neither pops `fetch_entry_i[0]` nor marks `issue_q[0].valid` until the table entry arrives.

3. **Latch-Free / Combinational-Loop-Free Synthesis & Area/Timing Closure (`code/macro_decoder.sv`, `code/zcmt_decoder.sv`, `code/id_stage.sv`)**:
   - All combinational blocks in `macro_decoder`, `zcmt_decoder`, and `id_stage` must be completely specified with no inferred latches and zero combinational logic loops (`scc -expect 0` in Yosys after `proc; opt_clean`).
   - On the critical decode path through `id_decode_top`, avoid routing non-macro / non-table-jump instructions serially through the `macro_decoder` mux tree or re-evaluating chained 12-bit stack-adjustment adders across every state cycle.
   - Under the Nangate45 synthesis and OpenROAD STA sign-off flow (`flow/id_decode_top.sv` at a `1.95 ns` clock period on `clk_i` with `0.15 ns` input/output external delays and `abc -D 1000`):
     - Worst setup slack (`max`): `>= 0.00 ns`
     - Worst hold slack (`min`): `>= 0.00 ns`
     - Total cell area of `id_decode_top`: `<= 2560.0 um^2`

## Deliverable

Update only the editable RTL files:
- `code/macro_decoder.sv`
- `code/zcmt_decoder.sv`
- `code/id_stage.sv`

Do not modify module port signatures or package definitions.
