//-----------------------------------------------------------------
//                         biRISC-V CPU
//                            V0.8.1
//                     Ultra-Embedded.com
//                     Copyright 2019-2020
//
//                   admin@ultra-embedded.com
//
//                     License: Apache 2.0
//-----------------------------------------------------------------
module biriscv_fetch
#(
     parameter SUPPORT_MMU      = 1
)
(
     input           clk_i
    ,input           rst_i
    ,input           fetch_accept_i
    ,input           icache_accept_i
    ,input           icache_valid_i
    ,input           icache_error_i
    ,input  [ 63:0]  icache_inst_i
    ,input           icache_page_fault_i
    ,input           fetch_invalidate_i
    ,input           branch_request_i
    ,input  [ 31:0]  branch_pc_i
    ,input  [  1:0]  branch_priv_i
    ,input  [ 31:0]  next_pc_f_i
    ,input  [  1:0]  next_taken_f_i

    ,output          fetch_valid_o
    ,output [ 63:0]  fetch_instr_o
    ,output [  1:0]  fetch_pred_branch_o
    ,output          fetch_fault_fetch_o
    ,output          fetch_fault_page_o
    ,output [ 31:0]  fetch_pc_o
    ,output          icache_rd_o
    ,output          icache_flush_o
    ,output          icache_invalidate_o
    ,output [ 31:0]  icache_pc_o
    ,output [  1:0]  icache_priv_o
    ,output [ 31:0]  pc_f_o
    ,output          pc_accept_o
);

`include "biriscv_defs.v"

reg         active_q;
reg         redir_pend_q;
reg [31:0]  redir_pc_q;
reg [1:0]   redir_priv_q;

reg         icache_fetch_q;
reg         drop_resp_q;
reg         icache_invalidate_q;

reg [31:0]  pc_f_q;
reg [1:0]   priv_f_q;
reg [31:0]  pc_d_q;
reg [1:0]   pred_d_q;

reg [99:0]  skid_buffer_q;
reg         skid_valid_q;

wire        icache_busy_w = icache_fetch_q && !icache_valid_i;
wire        flush_req_w   = fetch_invalidate_i | icache_invalidate_q;

// Active after initial branch_request_i
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
    active_q <= 1'b0;
else if (branch_request_i)
    active_q <= 1'b1;

// Buffered redirect target (always latches branch_request_i so NPC state updates before lookup)
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    redir_pend_q <= 1'b0;
    redir_pc_q   <= 32'b0;
    redir_priv_q <= `PRIV_MACHINE;
end
else if (branch_request_i)
begin
    redir_pend_q <= 1'b1;
    redir_pc_q   <= branch_pc_i;
    redir_priv_q <= SUPPORT_MMU ? branch_priv_i : `PRIV_MACHINE;
end
else if (icache_rd_o && icache_accept_i)
begin
    redir_pend_q <= 1'b0;
end

// Track in-flight ICache read and stale wrong-path response draining
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
    icache_fetch_q <= 1'b0;
else if (icache_rd_o && icache_accept_i)
    icache_fetch_q <= 1'b1;
else if (icache_valid_i)
    icache_fetch_q <= 1'b0;

always @ (posedge clk_i or posedge rst_i)
if (rst_i)
    drop_resp_q <= 1'b0;
else if (branch_request_i)
    drop_resp_q <= icache_busy_w;
else if (icache_valid_i)
    drop_resp_q <= 1'b0;

// Retain fetch_invalidate_i until icache_flush_o handshakes with icache_accept_i
assign icache_flush_o      = flush_req_w & ~icache_busy_w;
assign icache_invalidate_o = 1'b0;

always @ (posedge clk_i or posedge rst_i)
if (rst_i)
    icache_invalidate_q <= 1'b0;
else if (icache_flush_o && icache_accept_i)
    icache_invalidate_q <= 1'b0;
else if (fetch_invalidate_i)
    icache_invalidate_q <= 1'b1;

wire [31:0] cur_pc_f_w   = redir_pend_q ? redir_pc_q : pc_f_q;
wire [1:0]  cur_priv_f_w = SUPPORT_MMU ? (redir_pend_q ? redir_priv_q : priv_f_q) : `PRIV_MACHINE;

wire can_issue_rd_w = active_q & ~branch_request_i & ~icache_busy_w & ~drop_resp_q &
                      ~flush_req_w & (~skid_valid_q | fetch_accept_i) & fetch_accept_i;

assign icache_rd_o   = can_issue_rd_w;
assign icache_pc_o   = {cur_pc_f_w[31:3], 3'b000};
assign icache_priv_o = cur_priv_f_w;

assign pc_f_o        = cur_pc_f_w;
assign pc_accept_o   = icache_rd_o & icache_accept_i;

always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    pc_f_q   <= 32'b0;
    priv_f_q <= `PRIV_MACHINE;
    pc_d_q   <= 32'b0;
    pred_d_q <= 2'b0;
end
else if (icache_rd_o && icache_accept_i)
begin
    pc_f_q   <= next_pc_f_i;
    priv_f_q <= cur_priv_f_w;
    pc_d_q   <= cur_pc_f_w;
    pred_d_q <= next_taken_f_i;
end
else if (icache_valid_i && !drop_resp_q)
begin
    pred_d_q <= 2'b0;
end

wire raw_icache_valid_w = icache_valid_i & ~drop_resp_q & ~branch_request_i;

// Skid buffer: holds returning parcel across multi-cycle fetch_accept_i == 0 stalls, cleared on redirect
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    skid_buffer_q <= 100'b0;
    skid_valid_q  <= 1'b0;
end
else if (branch_request_i)
begin
    skid_buffer_q <= 100'b0;
    skid_valid_q  <= 1'b0;
end
else if (skid_valid_q)
begin
    if (fetch_accept_i)
    begin
        skid_valid_q  <= 1'b0;
        skid_buffer_q <= 100'b0;
    end
end
else if (raw_icache_valid_w && !fetch_accept_i)
begin
    skid_valid_q  <= 1'b1;
    skid_buffer_q <= {icache_page_fault_i, icache_error_i, pred_d_q, {pc_d_q[31:3], 3'b000}, icache_inst_i};
end

assign fetch_valid_o       = (raw_icache_valid_w | skid_valid_q) & ~branch_request_i;
assign fetch_pc_o          = skid_valid_q ? skid_buffer_q[95:64] : {pc_d_q[31:3], 3'b000};
assign fetch_instr_o       = skid_valid_q ? skid_buffer_q[63:0]  : icache_inst_i;
assign fetch_pred_branch_o = skid_valid_q ? skid_buffer_q[97:96] : pred_d_q;
assign fetch_fault_fetch_o = skid_valid_q ? skid_buffer_q[98]    : icache_error_i;
assign fetch_fault_page_o  = skid_valid_q ? skid_buffer_q[99]    : icache_page_fault_i;

endmodule
