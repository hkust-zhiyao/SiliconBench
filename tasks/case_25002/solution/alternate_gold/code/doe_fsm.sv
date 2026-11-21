// SPDX-License-Identifier: Apache-2.0
//
// Alternate reference implementation for Caliptra DOE sparse FSM & sticky lock sequencer.
// Uses (* keep_hierarchy = "true" *) caliptra_prim_sparse_fsm_flop + explicit parallel state comparators
// and one-hot latched flow mode registers.
//
`include "caliptra_macros.svh"
`include "caliptra_prim_assert.sv"

module doe_fsm
    import doe_defines_pkg::*;
    import kv_defines_pkg::*;
    #(
    parameter SRC_WIDTH = 128
   ,parameter DEST_WIDTH = 128
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

    input logic [FE_NUM_BLOCKS-1:0][SRC_WIDTH-1:0] obf_field_entropy,
    input logic [UDS_NUM_BLOCKS-1:0][SRC_WIDTH-1:0] obf_uds_seed,
    input logic [HEK_NUM_BLOCKS-1:0][SRC_WIDTH-1:0] obf_hek_seed,

    input doe_cmd_reg_t doe_cmd_reg,
    input logic         ocp_lock_en,

    output kv_write_t kv_write,
    input  kv_wr_resp_t kv_wr_resp,

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

(* keep = "true" *) kv_doe_fsm_state_e kv_doe_fsm_ps;
kv_doe_fsm_state_e kv_doe_fsm_ns;

// Hierarchy-preserved sparse FSM flop primitive
(* keep_hierarchy = "true" *)
caliptra_prim_sparse_fsm_flop #(
    .StateEnumT(kv_doe_fsm_state_e),
    .Width(DoeStateWidth),
    .ResetValue(DoeStateWidth'(DOE_IDLE)),
    .EnableAlertTriggerSVA(0)
) u_doe_state_regs (
    .clk_i (clk),
    .rst_ni(rst_b),
    .state_i(kv_doe_fsm_ns),
    .state_o(kv_doe_fsm_ps)
);

// Explicit parallel 10-bit comparators against all 8 valid sparse encodings
logic [DoeStateWidth-1:0] ps_vec;
assign ps_vec = DoeStateWidth'(kv_doe_fsm_ps);

logic st_idle, st_init, st_block, st_next, st_wait, st_write, st_done, st_error, st_illegal;
assign st_idle    = (ps_vec == 10'b1010101010);
assign st_init    = (ps_vec == 10'b1111011110);
assign st_block   = (ps_vec == 10'b0100011011);
assign st_next    = (ps_vec == 10'b1010010101);
assign st_wait    = (ps_vec == 10'b0110101101);
assign st_write   = (ps_vec == 10'b0001100111);
assign st_done    = (ps_vec == 10'b1001111001);
assign st_error   = (ps_vec == 10'b0111110000);
assign st_illegal = ~(st_idle | st_init | st_block | st_next | st_wait | st_write | st_done | st_error);

// One-hot latched flow mode registers
logic active_uds_q, active_fe_q, active_hek_q;
logic wr_err_seen_q;
logic [KV_ENTRY_ADDR_W-1:0]  dest_addr;
logic [DEST_WR_OFFSET_W-1:0] dest_write_offset;
logic [BLOCK_OFFSET_W-1:0]   block_offset;

// Command & slot eligibility in DOE_IDLE
logic slot_in_std;
logic slot_is_hek;
logic can_start_uds, can_start_fe, can_start_hek, start_any_flow;
logic reject_idle_cmd;

assign slot_in_std     = (doe_cmd_reg.dest_sel <= 5'd15);
assign slot_is_hek     = ocp_lock_en && (doe_cmd_reg.dest_sel == KV_ENTRY_ADDR_W'(OCP_LOCK_HEK_SEED_KV_SLOT));
assign can_start_uds   = (doe_cmd_reg.cmd == DOE_UDS) && !lock_uds_flow && slot_in_std;
assign can_start_fe    = (doe_cmd_reg.cmd == DOE_FE)  && !lock_fe_flow  && slot_in_std;
assign can_start_hek   = (doe_cmd_reg.cmd == DOE_HEK) && !lock_hek_flow && slot_is_hek;
assign start_any_flow  = can_start_uds || can_start_fe || can_start_hek;
assign reject_idle_cmd = !zeroize && (doe_cmd_reg.cmd != DOE_NOP) && (doe_cmd_reg.cmd != DOE_CLEAR) && !start_any_flow;

logic eff_uds, eff_fe, eff_hek;
assign eff_uds = st_idle ? can_start_uds : active_uds_q;
assign eff_fe  = st_idle ? can_start_fe  : active_fe_q;
assign eff_hek = st_idle ? can_start_hek : active_hek_q;

logic block_done;
logic dest_write_done;
assign block_done = eff_uds ? (block_offset == BLOCK_OFFSET_W'(UDS_NUM_BLOCKS-1)) :
                    eff_hek ? (block_offset == BLOCK_OFFSET_W'(HEK_NUM_BLOCKS-1)) :
                              (block_offset == BLOCK_OFFSET_W'(FE_NUM_BLOCKS -1));
assign dest_write_done = (dest_write_offset[DEST_OFFSET_W-1:0] == DEST_OFFSET_W'(DEST_NUM_DWORDS-1));

kv_write_filter_metrics_t kv_write_metrics;
logic                     kv_write_allow;

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

kv_write_rule_check kv_write_rules (
    .clk          (clk),
    .rst_b        (rst_b),
    .write_metrics(kv_write_metrics),
    .write_allow  (kv_write_allow)
);

assign fsm_error        = st_error | st_illegal;
assign flow_in_progress = (st_init | st_block | st_next | st_wait | st_write | st_done) |
                          (st_idle & ~zeroize & start_any_flow);

logic dest_write_en;
logic step_dest_offset;
logic step_block_offset;

always_comb begin
    kv_doe_fsm_ns     = DOE_ERROR;
    doe_init          = 1'b0;
    doe_next          = 1'b0;
    src_write_en      = 1'b0;
    dest_write_en     = 1'b0;
    step_dest_offset  = 1'b0;
    step_block_offset = 1'b0;
    flow_done         = 1'b0;
    flow_error        = 1'b0;

    if (st_error || st_illegal) begin
        kv_doe_fsm_ns = DOE_ERROR;
    end else if (st_idle) begin
        if (zeroize) begin
            kv_doe_fsm_ns = DOE_IDLE;
        end else if (start_any_flow) begin
            kv_doe_fsm_ns = DOE_INIT;
        end else begin
            kv_doe_fsm_ns = DOE_IDLE;
            if (reject_idle_cmd) begin
                flow_done  = 1'b1;
                flow_error = 1'b1;
            end
        end
    end else if (st_init) begin
        if (zeroize) begin
            kv_doe_fsm_ns = DOE_IDLE;
        end else begin
            kv_doe_fsm_ns = DOE_WAIT;
            doe_init      = 1'b1;
        end
    end else if (st_block) begin
        if (zeroize) begin
            kv_doe_fsm_ns = DOE_IDLE;
        end else begin
            kv_doe_fsm_ns = DOE_NEXT;
            src_write_en  = 1'b1;
        end
    end else if (st_next) begin
        if (zeroize) begin
            kv_doe_fsm_ns = DOE_IDLE;
        end else begin
            kv_doe_fsm_ns = DOE_WAIT;
            doe_next      = 1'b1;
        end
    end else if (st_wait) begin
        if (zeroize) begin
            kv_doe_fsm_ns = DOE_IDLE;
        end else if (init_done && dest_data_avail) begin
            kv_doe_fsm_ns = DOE_WRITE;
        end else if (init_done && !dest_data_avail) begin
            kv_doe_fsm_ns = DOE_BLOCK;
        end else begin
            kv_doe_fsm_ns = DOE_WAIT;
        end
    end else if (st_write) begin
        if (zeroize) begin
            kv_doe_fsm_ns = DOE_IDLE;
        end else begin
            dest_write_en    = kv_write_allow;
            step_dest_offset = kv_write_allow;
            flow_error       = !kv_write_allow || kv_wr_resp.error;
            if (flow_error || (dest_write_done && block_done)) begin
                kv_doe_fsm_ns = DOE_DONE;
            end else if (dest_write_done && !block_done) begin
                kv_doe_fsm_ns     = DOE_BLOCK;
                step_block_offset = 1'b1;
            end else begin
                kv_doe_fsm_ns = DOE_WRITE;
            end
        end
    end else if (st_done) begin
        kv_doe_fsm_ns = DOE_IDLE;
        if (!zeroize) begin
            flow_done = 1'b1;
        end
    end
end

always_comb begin
    kv_write.write_en         = dest_write_en;
    kv_write.write_offset     = dest_write_offset;
    kv_write.write_dest_valid = (dest_write_en && dest_write_done && block_done) ?
                                (eff_hek ? KV_NUM_READ'(OCP_LOCK_HEK_SEED_DEST_VALID) : 9'd3) : '0;
    kv_write.write_entry      = dest_addr;
    kv_write.write_data       = dest_write_en ? dest_data[(DEST_NUM_DWORDS-1) - dest_write_offset[DEST_OFFSET_W-1:0]] : '0;

    if (fsm_error || zeroize) begin
        src_write_data = '0;
    end else if (eff_uds) begin
        src_write_data = obf_uds_seed[block_offset[UDS_BLOCK_OFFSET_W-1:0]];
    end else if (eff_fe) begin
        src_write_data = obf_field_entropy[block_offset[FE_BLOCK_OFFSET_W-1:0]];
    end else if (eff_hek) begin
        src_write_data = obf_hek_seed[block_offset[HEK_BLOCK_OFFSET_W-1:0]];
    end else begin
        src_write_data = '0;
    end
end

always_ff @(posedge clk or negedge rst_b) begin
    if (~rst_b) begin
        active_uds_q      <= 1'b0;
        active_fe_q       <= 1'b0;
        active_hek_q      <= 1'b0;
        wr_err_seen_q     <= 1'b0;
        dest_addr         <= '0;
        dest_write_offset <= '0;
        block_offset      <= '0;
    end else if (zeroize || fsm_error) begin
        active_uds_q      <= 1'b0;
        active_fe_q       <= 1'b0;
        active_hek_q      <= 1'b0;
        wr_err_seen_q     <= 1'b0;
        dest_addr         <= '0;
        dest_write_offset <= '0;
        block_offset      <= '0;
    end else if (st_idle && start_any_flow) begin
        active_uds_q      <= can_start_uds;
        active_fe_q       <= can_start_fe;
        active_hek_q      <= can_start_hek;
        wr_err_seen_q     <= 1'b0;
        dest_addr         <= doe_cmd_reg.dest_sel;
        dest_write_offset <= '0;
        block_offset      <= '0;
    end else if (st_done) begin
        active_uds_q      <= 1'b0;
        active_fe_q       <= 1'b0;
        active_hek_q      <= 1'b0;
        wr_err_seen_q     <= 1'b0;
        dest_write_offset <= '0;
        block_offset      <= '0;
    end else begin
        if (step_dest_offset) begin
            dest_write_offset <= dest_write_offset + 'd1;
        end
        if (step_block_offset) begin
            block_offset <= block_offset + 'd1;
        end
        if (st_write && flow_error) begin
            wr_err_seen_q <= 1'b1;
        end
    end
end

always_ff @(posedge clk or negedge hard_rst_b) begin
    if (~hard_rst_b) begin
        lock_uds_flow <= 1'b0;
        lock_fe_flow  <= 1'b0;
        lock_hek_flow <= 1'b0;
    end else if (st_done && !zeroize && !fsm_error && !wr_err_seen_q) begin
        if (active_uds_q) lock_uds_flow <= 1'b1;
        if (active_fe_q)  lock_fe_flow  <= 1'b1;
        if (active_hek_q) lock_hek_flow <= 1'b1;
    end
end

endmodule
