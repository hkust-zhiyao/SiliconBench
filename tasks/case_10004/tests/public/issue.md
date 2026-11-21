# OpenPiton NoC-to-AXI4 Memory Bridge Framing, In-Flight Slot Protection, Response Arbitration, and PPA/STA Closure

In the OpenPiton chipset NoC-to-AXI4 memory bridge (`code/rtl/noc_axi4_bridge.v`), multi-flit NoC2 request deserialization (`code/rtl/noc_axi4_bridge_deser.v`), in-flight transaction buffering and response arbitration (`code/rtl/noc_axi4_bridge_buffer.v`), and NoC3 response serialization (`code/rtl/noc_axi4_bridge_ser.v`) fail verification and physical area/timing closure:

1. **NoC2 Request Deserialization (`code/rtl/noc_axi4_bridge_deser.v`)**:
   - Accept the 3 header flits (`pkt_w1`, `pkt_w2`, `pkt_w3`) followed by `N = pkt_w1[MSG_LENGTH] - 2` data payload beats (`N in [0, 8]`) only on qualified handshakes (`flit_in_val && flit_in_rdy`, where `flit_in_rdy` is gated by `phy_init_done` and deasserted while `out_val` is high).
   - Clear the 512-bit payload buffer at the start of each packet and place beat `k` (`0 <= k < N`) at `data_out[64*k +: 64]` so that 1-beat uncacheable stores (`MSG_LENGTH == 3`) appear on `data_out[63:0]` with `data_out[511:64] == 0`, 8-beat cacheable stores (`MSG_LENGTH == 10`) appear in order on `data_out[63:0]` through `data_out[511:448]`, and 0-beat load requests (`MSG_LENGTH == 2`) present `data_out == 512'd0`. Hold `header_out`, `data_out`, and `out_val` stable until `out_rdy` is asserted.

2. **In-Flight Slot Protection and Work-Conserving Response Arbitration (`code/rtl/noc_axi4_bridge_buffer.v`)**:
   - Protect in-flight header SRAM entries: a buffer slot `i` (`0 .. NOC_AXI4_BRIDGE_IN_FLIGHT_LIMIT-1`) must not accept a new packet from `deser` (`deser_rdy` must remain low when `fifo_in == i`) while either its request is still waiting to issue or its AXI response has not yet been accepted into the serializer path.
   - Replace the free-running response toggle with work-conserving round-robin arbitration between `read_resp_val` and `write_resp_val`: when only one response channel is valid and the serializer interface can accept a beat, grant it immediately without waiting an extra cycle; when both `read_resp_val` and `write_resp_val` are asserted simultaneously, alternate grants between read and write responses. Ensure the header read from `noc_axi4_bridge_sram_req` (`ser_header`) and the corresponding `ser_data` / `ser_val` remain aligned across single-stage registration and downstream `ser_rdy` backpressure.

3. **NoC3 Response Serialization (`code/rtl/noc_axi4_bridge_ser.v`)**:
   - Latch `header_in` and `data_in` only on a valid input handshake (`in_val && in_rdy`).
   - Encode `MSG_LENGTH` in the outgoing NoC3 response header as `0` for `MSG_TYPE_STORE_MEM_ACK`, `MSG_TYPE_NC_STORE_MEM_ACK`, and zero-byte uncacheable loads (`MSG_TYPE_NC_LOAD_REQ` with `MSG_DATA_SIZE == MSG_DATA_SIZE_0B`); `1` for uncacheable loads with `MSG_DATA_SIZE` in `1B .. 8B` (`MSG_DATA_SIZE_1B` through `MSG_DATA_SIZE_8B`), emitting 1 payload flit (`data_in[63:0]`); and `PAYLOAD_LEN` (`8`) for cacheable loads (`MSG_TYPE_LOAD_MEM`) and uncacheable loads with `MSG_DATA_SIZE > MSG_DATA_SIZE_8B`, emitting 8 payload flits (`data_in[63:0]` through `data_in[511:448]`).
   - Hold every header and payload flit stable across `flit_out_rdy == 0` stalls (including on the final payload beat) and advance only on `flit_out_val && flit_out_rdy`.

4. **Nangate45 Mapped Area and 1.08 ns OpenROAD STA Closure (`BUILD.md`)**:
   - Under the Nangate45 synthesis and OpenROAD placement-estimated STA flows in `BUILD.md` (`1.08 ns` clock period on `clk`, `0.15 ns` I/O delays, `5.0 fF` output load), achieve:
     - `noc_axi4_bridge_deser` mapped area **`<= 4,955.0 um^2`**, `noc_axi4_bridge_ser` mapped area **`<= 4,810.0 um^2`**, and `noc_axi4_bridge_buffer` mapped area **`<= 21,350.0 um^2`**;
     - Worst setup slack and worst hold slack **`>= 0.0 ns`** on both `noc_axi4_bridge_deser` and `noc_axi4_bridge_ser`.

Edit only `code/rtl/noc_axi4_bridge_deser.v`, `code/rtl/noc_axi4_bridge_ser.v`, and `code/rtl/noc_axi4_bridge_buffer.v`.
