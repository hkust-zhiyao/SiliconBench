// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
`include "caliptra_macros.svh"
`include "caliptra_prim_assert.sv"

module doe_fsm
    import doe_defines_pkg::*;
    import kv_defines_pkg::*;
    #(
    parameter SRC_WIDTH = 128
   ,parameter DEST_WIDTH = 128
    // derived params don't change
   ,localparam DEST_OFFSET_W   = $clog2(DEST_WIDTH/32)
   ,localparam DEST_NUM_DWORDS = (DEST_WIDTH/32)
   ,localparam TOTAL_OBF_FE_BITS = `CLP_OBF_FE_DWORDS * 32
   ,localparam TOTAL_OBF_UDS_BITS = `CLP_OBF_UDS_DWORDS * 32
   ,localparam TOTAL_OBF_HEK_BITS = OCP_LOCK_HEK_NUM_DWORDS * 32
   ,localparam FE_NUM_BLOCKS   = TOTAL_OBF_FE_BITS/SRC_WIDTH
   ,localparam UDS_NUM_BLOCKS  = TOTAL_OBF_UDS_BITS/SRC_WIDTH
   ,localparam HEK_NUM_BLOCKS  = TOTAL_OBF_HEK_BITS/SRC_WIDTH
)
(
    input logic clk,
    input logic rst_b,
    input logic hard_rst_b,

    // Obfuscated UDS, FE, and HEK
    input logic [FE_NUM_BLOCKS-1:0][SRC_WIDTH-1:0] obf_field_entropy,
    input logic [UDS_NUM_BLOCKS-1:0][SRC_WIDTH-1:0] obf_uds_seed,
    input logic [HEK_NUM_BLOCKS-1:0][SRC_WIDTH-1:0] obf_hek_seed,

    // client control register
    input doe_cmd_reg_t doe_cmd_reg,
    input logic         ocp_lock_en,

    // interface with kv
    output kv_write_t kv_write,
    input  kv_wr_resp_t kv_wr_resp,

    // interface with client
    output logic src_write_en,
    output logic [SRC_WIDTH-1:0] src_write_data,

    output logic doe_init,
    output logic doe_next,

    input logic init_done,
    input logic dest_data_avail,
    input logic [DEST_NUM_DWORDS-1:0][31:0] dest_data,

    output logic flow_done,
    output logic flow_error,
    output logic fsm_error,
    output logic flow_in_progress,
    output logic lock_uds_flow,
    output logic lock_fe_flow,
    output logic lock_hek_flow,
    input  logic zeroize
);

`define CLP_MAX_OF(a,b) ((a > b) ? a : b)

localparam UDS_BLOCK_OFFSET_W = $clog2(UDS_NUM_BLOCKS);
localparam FE_BLOCK_OFFSET_W  = $clog2(FE_NUM_BLOCKS);
localparam HEK_BLOCK_OFFSET_W = $clog2(HEK_NUM_BLOCKS);
localparam BLOCK_OFFSET_W     = `CLP_MAX_OF(HEK_BLOCK_OFFSET_W, `CLP_MAX_OF(FE_BLOCK_OFFSET_W, UDS_BLOCK_OFFSET_W));
localparam DEST_WR_OFFSET_W   = $clog2(512/32);

// Sparse 10-bit state encoding (minimum Hamming distance = 5 >= 3)
localparam int DoeStateWidth = 10;
typedef enum logic [DoeStateWidth-1:0] {
    DOE_IDLE  = 10'b1010101010,
    DOE_INIT  = 10'b1111011110,
    DOE_BLOCK = 10'b0100011011,
    DOE_NEXT  = 10'b1010010101,
    DOE_WAIT  = 10'b0110101101,
    DOE_WRITE = 10'b0001100111,
    DOE_DONE  = 10'b1001111001,
    DOE_ERROR = 10'b0111110000
} kv_doe_fsm_state_e;

// Synthesis-preserved sparse state flops (prevents FSM extraction/recoding and redundant-bit pruning)
(* keep = "true", fsm_encoding = "none" *) logic [DoeStateWidth-1:0] kv_doe_fsm_ps_raw;
(* keep = "true" *) kv_doe_fsm_state_e kv_doe_fsm_ps;
kv_doe_fsm_state_e kv_doe_fsm_ns;

assign kv_doe_fsm_ps = kv_doe_fsm_state_e'(kv_doe_fsm_ps_raw);

always_ff @(posedge clk or negedge rst_b) begin
    if (~rst_b) begin
        kv_doe_fsm_ps_raw <= DoeStateWidth'(DOE_IDLE);
    end else begin
        kv_doe_fsm_ps_raw <= DoeStateWidth'(kv_doe_fsm_ns);
    end
end

// Pre-dispatch command & destination-slot policy checks in DOE_IDLE
logic std_slot_ok;
logic hek_slot_ok;
logic uds_auth;
logic fe_auth;
logic hek_auth;
logic cmd_is_nop_or_clear;
logic cmd_rejected_in_idle;

assign std_slot_ok         = (doe_cmd_reg.dest_sel <= KV_ENTRY_ADDR_W'(KV_STANDARD_SLOT_HI));
assign hek_slot_ok         = ocp_lock_en && (doe_cmd_reg.dest_sel == KV_ENTRY_ADDR_W'(OCP_LOCK_HEK_SEED_KV_SLOT));
assign uds_auth            = (doe_cmd_reg.cmd == DOE_UDS) && !lock_uds_flow && std_slot_ok;
assign fe_auth             = (doe_cmd_reg.cmd == DOE_FE)  && !lock_fe_flow  && std_slot_ok;
assign hek_auth            = (doe_cmd_reg.cmd == DOE_HEK) && !lock_hek_flow && hek_slot_ok;
assign cmd_is_nop_or_clear = (doe_cmd_reg.cmd == DOE_NOP) || (doe_cmd_reg.cmd == DOE_CLEAR);

logic arc_DOE_IDLE_DOE_INIT;
logic arc_DOE_WAIT_DOE_BLOCK;
logic arc_DOE_WAIT_DOE_WRITE;
logic arc_DOE_WRITE_DOE_BLOCK;
logic arc_DOE_WRITE_DOE_DONE;

assign arc_DOE_IDLE_DOE_INIT  = uds_auth || fe_auth || hek_auth;
assign cmd_rejected_in_idle   = !zeroize && !cmd_is_nop_or_clear && !arc_DOE_IDLE_DOE_INIT;

// Latched command and error tracking across active unwrap beats
doe_cmd_e cmd_latched_q;
logic     flow_err_latched_q;

logic running_uds, running_fe, running_hek;
assign running_uds = (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_IDLE)) ? uds_auth : (cmd_latched_q == DOE_UDS);
assign running_fe  = (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_IDLE)) ? fe_auth  : (cmd_latched_q == DOE_FE);
assign running_hek = (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_IDLE)) ? hek_auth : (cmd_latched_q == DOE_HEK);

// Access filtering rule metrics
kv_write_filter_metrics_t kv_write_metrics;
logic                     kv_write_allow;

logic [KV_ENTRY_ADDR_W-1:0]  dest_addr, dest_addr_nxt;
logic                        dest_addr_en;
logic [DEST_WR_OFFSET_W-1:0] dest_write_offset, dest_write_offset_nxt;
logic                        dest_write_offset_en;
logic                        dest_write_en;
logic                        dest_write_done;

logic [BLOCK_OFFSET_W-1:0]   block_offset, block_offset_nxt;
logic                        block_offset_en;
logic                        block_done;

assign block_done = running_uds ? (block_offset == BLOCK_OFFSET_W'(UDS_NUM_BLOCKS-1)) :
                    running_hek ? (block_offset == BLOCK_OFFSET_W'(HEK_NUM_BLOCKS-1)) :
                                  (block_offset == BLOCK_OFFSET_W'(FE_NUM_BLOCKS -1));

assign dest_write_done = (dest_write_offset[DEST_OFFSET_W-1:0] == DEST_OFFSET_W'(DEST_NUM_DWORDS-1));

assign arc_DOE_WAIT_DOE_WRITE  = init_done && dest_data_avail;
assign arc_DOE_WAIT_DOE_BLOCK  = init_done && !dest_data_avail;
assign arc_DOE_WRITE_DOE_BLOCK = dest_write_done && !block_done;
assign arc_DOE_WRITE_DOE_DONE  = flow_error || (dest_write_done && block_done);

logic in_operational_active_state;
assign in_operational_active_state = (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_INIT))  ||
                                     (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_BLOCK)) ||
                                     (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_NEXT))  ||
                                     (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_WAIT))  ||
                                     (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_WRITE)) ||
                                     (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_DONE));

assign flow_in_progress = in_operational_active_state ||
                          ((kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_IDLE)) && !zeroize && arc_DOE_IDLE_DOE_INIT);

// Full-width sparse state decode (non-unique case so default catches all 1016 undefined 10-bit states)
always_comb begin : kv_doe_fsm
    kv_doe_fsm_ns         = DOE_ERROR;
    src_write_en          = 1'b0;
    block_offset_nxt      = block_offset;
    block_offset_en       = 1'b0;
    doe_init              = 1'b0;
    doe_next              = 1'b0;
    dest_write_en         = 1'b0;
    dest_write_offset_en  = 1'b0;
    dest_write_offset_nxt = dest_write_offset;
    flow_done             = 1'b0;
    flow_error            = 1'b0;
    fsm_error             = 1'b0;

    case (kv_doe_fsm_ps_raw)
        DoeStateWidth'(DOE_IDLE): begin
            if (zeroize) begin
                kv_doe_fsm_ns = DOE_IDLE;
            end else if (arc_DOE_IDLE_DOE_INIT) begin
                kv_doe_fsm_ns = DOE_INIT;
            end else begin
                kv_doe_fsm_ns = DOE_IDLE;
                if (cmd_rejected_in_idle) begin
                    flow_done  = 1'b1;
                    flow_error = 1'b1;
                end
            end
        end
        DoeStateWidth'(DOE_INIT): begin
            if (zeroize) begin
                kv_doe_fsm_ns = DOE_IDLE;
            end else begin
                kv_doe_fsm_ns = DOE_WAIT;
                doe_init      = 1'b1;
            end
        end
        DoeStateWidth'(DOE_BLOCK): begin
            if (zeroize) begin
                kv_doe_fsm_ns = DOE_IDLE;
            end else begin
                kv_doe_fsm_ns = DOE_NEXT;
                src_write_en  = 1'b1;
            end
        end
        DoeStateWidth'(DOE_NEXT): begin
            if (zeroize) begin
                kv_doe_fsm_ns = DOE_IDLE;
            end else begin
                kv_doe_fsm_ns = DOE_WAIT;
                doe_next      = 1'b1;
            end
        end
        DoeStateWidth'(DOE_WAIT): begin
            if (zeroize) begin
                kv_doe_fsm_ns = DOE_IDLE;
            end else if (arc_DOE_WAIT_DOE_WRITE) begin
                kv_doe_fsm_ns = DOE_WRITE;
            end else if (arc_DOE_WAIT_DOE_BLOCK) begin
                kv_doe_fsm_ns = DOE_BLOCK;
            end else begin
                kv_doe_fsm_ns = DOE_WAIT;
            end
        end
        DoeStateWidth'(DOE_WRITE): begin
            if (zeroize) begin
                kv_doe_fsm_ns = DOE_IDLE;
            end else begin
                dest_write_en         = kv_write_allow;
                dest_write_offset_en  = kv_write_allow;
                dest_write_offset_nxt = dest_write_offset + 'd1;
                flow_error            = !kv_write_allow || kv_wr_resp.error;

                if (arc_DOE_WRITE_DOE_DONE) begin
                    kv_doe_fsm_ns = DOE_DONE;
                end else if (arc_DOE_WRITE_DOE_BLOCK) begin
                    kv_doe_fsm_ns    = DOE_BLOCK;
                    block_offset_en  = 1'b1;
                    block_offset_nxt = block_offset + 'd1;
                end else begin
                    kv_doe_fsm_ns = DOE_WRITE;
                end
            end
        end
        DoeStateWidth'(DOE_DONE): begin
            kv_doe_fsm_ns         = DOE_IDLE;
            block_offset_en       = 1'b1;
            block_offset_nxt      = '0;
            dest_write_offset_en  = 1'b1;
            dest_write_offset_nxt = '0;
            if (!zeroize) begin
                flow_done = 1'b1;
            end
        end
        DoeStateWidth'(DOE_ERROR): begin
            // Terminal sticky fault state until reset; independent of zeroize to avoid loops
            kv_doe_fsm_ns = DOE_ERROR;
            fsm_error     = 1'b1;
        end
        default: begin
            // Undefined / glitched state encoding: immediate suppression & terminal transition
            kv_doe_fsm_ns = DOE_ERROR;
            fsm_error     = 1'b1;
        end
    endcase
end

assign dest_addr_en  = (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_IDLE)) && !zeroize && arc_DOE_IDLE_DOE_INIT;
assign dest_addr_nxt = doe_cmd_reg.dest_sel;

// Check KV filtering rules using the ocp_lock_en strap unconditionally
always_comb begin
    kv_write_metrics.ocp_lock_in_progress = ocp_lock_en;
    kv_write_metrics.kv_data0_present     = 1'b0;
    kv_write_metrics.kv_data0_entry       = '0;
    kv_write_metrics.kv_data1_present     = 1'b0;
    kv_write_metrics.kv_data1_entry       = '0;
    kv_write_metrics.kv_write_src         = KV_NUM_WRITE'(1 << KV_WRITE_IDX_DOE);
    kv_write_metrics.kv_write_entry       = dest_addr;
    kv_write_metrics.aes_decrypt_ecb_op   = 1'b0;
end

kv_write_rule_check kv_write_rules
(
    .clk  (clk  ),
    .rst_b(rst_b),

    .write_metrics(kv_write_metrics),
    .write_allow  (kv_write_allow  )
);

// Drive outputs to KeyVault (suppressed immediately on zeroize or fsm_error)
always_comb begin
    kv_write.write_en         = dest_write_en;
    kv_write.write_offset     = dest_write_offset;
    kv_write.write_dest_valid = (dest_write_en && dest_write_done && block_done) ?
                                (running_hek ? KV_NUM_READ'(OCP_LOCK_HEK_SEED_DEST_VALID) : 9'd3) : '0;
    kv_write.write_entry      = dest_addr;
    kv_write.write_data       = dest_write_en ? dest_data[(DEST_NUM_DWORDS-1) - dest_write_offset[DEST_OFFSET_W-1:0]] : '0;
end

// Pick obfuscated seed block based on latched flow command
always_comb begin
    if (fsm_error || zeroize) begin
        src_write_data = '0;
    end else if (running_uds) begin
        src_write_data = obf_uds_seed[block_offset[UDS_BLOCK_OFFSET_W-1:0]];
    end else if (running_fe) begin
        src_write_data = obf_field_entropy[block_offset[FE_BLOCK_OFFSET_W-1:0]];
    end else if (running_hek) begin
        src_write_data = obf_hek_seed[block_offset[HEK_BLOCK_OFFSET_W-1:0]];
    end else begin
        src_write_data = '0;
    end
end

// Sequential state for offsets, latched command, destination slot, and error tracking
always_ff @(posedge clk or negedge rst_b) begin
    if (~rst_b) begin
        dest_write_offset  <= '0;
        block_offset       <= '0;
        dest_addr          <= '0;
        cmd_latched_q      <= DOE_NOP;
        flow_err_latched_q <= 1'b0;
    end else if (zeroize || fsm_error) begin
        dest_write_offset  <= '0;
        block_offset       <= '0;
        dest_addr          <= '0;
        cmd_latched_q      <= DOE_NOP;
        flow_err_latched_q <= 1'b0;
    end else begin
        if (dest_addr_en) begin
            dest_addr          <= dest_addr_nxt;
            cmd_latched_q      <= doe_cmd_reg.cmd;
            dest_write_offset  <= '0;
            block_offset       <= '0;
            flow_err_latched_q <= 1'b0;
        end else begin
            if (dest_write_offset_en) begin
                dest_write_offset <= dest_write_offset_nxt;
            end
            if (block_offset_en) begin
                block_offset <= block_offset_nxt;
            end
            if ((kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_WRITE)) && flow_error) begin
                flow_err_latched_q <= 1'b1;
            end else if (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_DONE)) begin
                cmd_latched_q      <= DOE_NOP;
                flow_err_latched_q <= 1'b0;
            end
        end
    end
end

// Monotonic sticky flow locks: reset ONLY on cold power-good reset (~hard_rst_b),
// set ONLY upon error-free completion in DOE_DONE.
logic valid_flow_complete;
assign valid_flow_complete = (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_DONE)) &&
                             !zeroize && !fsm_error && !flow_err_latched_q;

always_ff @(posedge clk or negedge hard_rst_b) begin
    if (~hard_rst_b) begin
        lock_uds_flow <= 1'b0;
        lock_fe_flow  <= 1'b0;
        lock_hek_flow <= 1'b0;
    end else begin
        if (valid_flow_complete && (cmd_latched_q == DOE_UDS)) begin
            lock_uds_flow <= 1'b1;
        end
        if (valid_flow_complete && (cmd_latched_q == DOE_FE)) begin
            lock_fe_flow <= 1'b1;
        end
        if (valid_flow_complete && (cmd_latched_q == DOE_HEK)) begin
            lock_hek_flow <= 1'b1;
        end
    end
end

endmodule
