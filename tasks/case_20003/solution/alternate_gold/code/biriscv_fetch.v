//-----------------------------------------------------------------
//                         biRISC-V CPU
//                            V0.8.1
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

localparam [1:0] ST_IDLE     = 2'd0,
                 ST_REDIRECT = 2'd1,
                 ST_STREAM   = 2'd2;

reg [1:0]   f_state_q;
reg [31:0]  fetch_pc_reg_q;
reg [1:0]   fetch_priv_reg_q;

reg         inflight_q;
reg         kill_inflight_q;
reg         pend_flush_q;

reg [31:0]  issued_pc_q;
reg [1:0]   issued_pred_q;

reg         skid_occ_q;
reg [31:0]  skid_pc_q;
reg [63:0]  skid_inst_q;
reg [1:0]   skid_pred_q;
reg         skid_err_q;
reg         skid_pf_q;

wire inflight_wait_w = inflight_q & ~icache_valid_i;
wire need_flush_w    = fetch_invalidate_i | pend_flush_q;

assign icache_flush_o      = need_flush_w & ~inflight_wait_w;
assign icache_invalidate_o = 1'b0;

always @ (posedge clk_i or posedge rst_i)
if (rst_i)
    pend_flush_q <= 1'b0;
else if (icache_flush_o && icache_accept_i)
    pend_flush_q <= 1'b0;
else if (fetch_invalidate_i)
    pend_flush_q <= 1'b1;

wire req_ready_w = (f_state_q != ST_IDLE) & ~branch_request_i & ~inflight_wait_w &
                   ~kill_inflight_q & ~need_flush_w & fetch_accept_i;

assign icache_rd_o   = req_ready_w;
assign icache_pc_o   = {fetch_pc_reg_q[31:3], 3'b000};
assign icache_priv_o = SUPPORT_MMU ? fetch_priv_reg_q : `PRIV_MACHINE;
assign pc_f_o        = fetch_pc_reg_q;
assign pc_accept_o   = icache_rd_o & icache_accept_i;

always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    f_state_q        <= ST_IDLE;
    fetch_pc_reg_q   <= 32'b0;
    fetch_priv_reg_q <= `PRIV_MACHINE;
    inflight_q       <= 1'b0;
    kill_inflight_q  <= 1'b0;
    issued_pc_q      <= 32'b0;
    issued_pred_q    <= 2'b0;
end
else
begin
    if (pc_accept_o)
        inflight_q <= 1'b1;
    else if (icache_valid_i)
        inflight_q <= 1'b0;

    if (branch_request_i)
        kill_inflight_q <= inflight_wait_w;
    else if (icache_valid_i)
        kill_inflight_q <= 1'b0;

    if (branch_request_i)
    begin
        f_state_q        <= ST_REDIRECT;
        fetch_pc_reg_q   <= branch_pc_i;
        fetch_priv_reg_q <= SUPPORT_MMU ? branch_priv_i : `PRIV_MACHINE;
    end
    else if (pc_accept_o)
    begin
        f_state_q        <= ST_STREAM;
        fetch_pc_reg_q   <= next_pc_f_i;
        issued_pc_q      <= fetch_pc_reg_q;
        issued_pred_q    <= next_taken_f_i;
    end
    else if (icache_valid_i && !kill_inflight_q)
    begin
        issued_pred_q    <= 2'b0;
    end
end

wire good_resp_w = icache_valid_i & ~kill_inflight_q & ~branch_request_i;

always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    skid_occ_q  <= 1'b0;
    skid_pc_q   <= 32'b0;
    skid_inst_q <= 64'b0;
    skid_pred_q <= 2'b0;
    skid_err_q  <= 1'b0;
    skid_pf_q   <= 1'b0;
end
else if (branch_request_i)
begin
    skid_occ_q  <= 1'b0;
end
else if (skid_occ_q)
begin
    if (fetch_accept_i)
        skid_occ_q <= 1'b0;
end
else if (good_resp_w && !fetch_accept_i)
begin
    skid_occ_q  <= 1'b1;
    skid_pc_q   <= {issued_pc_q[31:3], 3'b000};
    skid_inst_q <= icache_inst_i;
    skid_pred_q <= issued_pred_q;
    skid_err_q  <= icache_error_i;
    skid_pf_q   <= icache_page_fault_i;
end

assign fetch_valid_o       = (skid_occ_q | good_resp_w) & ~branch_request_i;
assign fetch_pc_o          = skid_occ_q ? skid_pc_q   : {issued_pc_q[31:3], 3'b000};
assign fetch_instr_o       = skid_occ_q ? skid_inst_q : icache_inst_i;
assign fetch_pred_branch_o = skid_occ_q ? skid_pred_q : issued_pred_q;
assign fetch_fault_fetch_o = skid_occ_q ? skid_err_q  : icache_error_i;
assign fetch_fault_page_o  = skid_occ_q ? skid_pf_q   : icache_page_fault_i;

endmodule
