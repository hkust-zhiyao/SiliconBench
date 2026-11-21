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
module biriscv_npc
#(
     parameter SUPPORT_BRANCH_PREDICTION = 1
    ,parameter NUM_BTB_ENTRIES  = 32
    ,parameter NUM_BTB_ENTRIES_W = 5
    ,parameter NUM_BHT_ENTRIES  = 512
    ,parameter NUM_BHT_ENTRIES_W = 9
    ,parameter RAS_ENABLE       = 1
    ,parameter GSHARE_ENABLE    = 0
    ,parameter BHT_ENABLE       = 1
    ,parameter NUM_RAS_ENTRIES  = 8
    ,parameter NUM_RAS_ENTRIES_W = 3
)
(
     input           clk_i
    ,input           rst_i
    ,input           invalidate_i
    ,input           branch_request_i
    ,input           branch_is_taken_i
    ,input           branch_is_not_taken_i
    ,input  [ 31:0]  branch_source_i
    ,input           branch_is_call_i
    ,input           branch_is_ret_i
    ,input           branch_is_jmp_i
    ,input  [ 31:0]  branch_pc_i
    ,input  [ 31:0]  pc_f_i
    ,input           pc_accept_i

    ,output [ 31:0]  next_pc_f_o
    ,output [  1:0]  next_taken_f_o
);

localparam RAS_INVALID = 32'h00000001;

generate
if (SUPPORT_BRANCH_PREDICTION)
begin: BRANCH_PREDICTION

//-----------------------------------------------------------------
// Architectural (committed/resolved) Return Address Stack
//-----------------------------------------------------------------
reg [31:0]                  ras_stack_real_q[NUM_RAS_ENTRIES-1:0];
reg [NUM_RAS_ENTRIES_W-1:0] ras_index_real_q;
reg [NUM_RAS_ENTRIES_W-1:0] ras_index_real_r;

wire real_call_push_w = RAS_ENABLE & branch_is_taken_i & branch_is_call_i;
wire real_ret_pop_w   = RAS_ENABLE & branch_is_taken_i & branch_is_ret_i;

always @ *
begin
    ras_index_real_r = ras_index_real_q;
    if (real_call_push_w)
        ras_index_real_r = ras_index_real_q + {{(NUM_RAS_ENTRIES_W-1){1'b0}}, 1'b1};
    else if (real_ret_pop_w)
        ras_index_real_r = ras_index_real_q - {{(NUM_RAS_ENTRIES_W-1){1'b0}}, 1'b1};
end

integer ir;
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    for (ir = 0; ir < NUM_RAS_ENTRIES; ir = ir + 1)
        ras_stack_real_q[ir] <= RAS_INVALID;
    ras_index_real_q <= {NUM_RAS_ENTRIES_W{1'b0}};
end
else
begin
    if (real_call_push_w)
        ras_stack_real_q[ras_index_real_r] <= branch_source_i + 32'd4;
    ras_index_real_q <= ras_index_real_r;
end

//-----------------------------------------------------------------
// Speculative Return Address Stack
//-----------------------------------------------------------------
reg [31:0]                  ras_stack_q[NUM_RAS_ENTRIES-1:0];
reg [NUM_RAS_ENTRIES_W-1:0] ras_index_q;

wire [31:0] ras_pc_pred_w = ras_stack_q[ras_index_q];
wire        ras_top_ok_w  = RAS_ENABLE & ~ras_pc_pred_w[0];

//-----------------------------------------------------------------
// Global history register (actual & speculative)
//-----------------------------------------------------------------
reg [NUM_BHT_ENTRIES_W-1:0] global_history_real_q;
wire                        branch_resolved_w = branch_is_taken_i | branch_is_not_taken_i;
wire [NUM_BHT_ENTRIES_W-1:0] global_history_real_next_w = branch_resolved_w ?
    {global_history_real_q[NUM_BHT_ENTRIES_W-2:0], branch_is_taken_i} :
    global_history_real_q;

always @ (posedge clk_i or posedge rst_i)
if (rst_i)
    global_history_real_q <= {NUM_BHT_ENTRIES_W{1'b0}};
else if (branch_resolved_w)
    global_history_real_q <= global_history_real_next_w;

reg [NUM_BHT_ENTRIES_W-1:0] global_history_q;

//-----------------------------------------------------------------
// Branch History Table (2-bit saturating counters)
//-----------------------------------------------------------------
reg [1:0] bht_sat_q[NUM_BHT_ENTRIES-1:0];

wire [NUM_BHT_ENTRIES_W-1:0] gshare_wr_entry_w = global_history_real_q ^ branch_source_i[2+NUM_BHT_ENTRIES_W-1:2];
wire [NUM_BHT_ENTRIES_W-1:0] bht_wr_entry_w    = GSHARE_ENABLE ? gshare_wr_entry_w : branch_source_i[2+NUM_BHT_ENTRIES_W-1:2];

integer i4;
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    for (i4 = 0; i4 < NUM_BHT_ENTRIES; i4 = i4 + 1)
        bht_sat_q[i4] <= 2'd3;
end
else if (branch_is_taken_i && bht_sat_q[bht_wr_entry_w] < 2'd3)
    bht_sat_q[bht_wr_entry_w] <= bht_sat_q[bht_wr_entry_w] + 2'd1;
else if (branch_is_not_taken_i && bht_sat_q[bht_wr_entry_w] > 2'd0)
    bht_sat_q[bht_wr_entry_w] <= bht_sat_q[bht_wr_entry_w] - 2'd1;

//-----------------------------------------------------------------
// Branch Target Buffer (with explicit per-entry valid bit)
//-----------------------------------------------------------------
reg [NUM_BTB_ENTRIES-1:0] btb_entry_valid_q;
reg [31:0]                btb_pc_q[NUM_BTB_ENTRIES-1:0];
reg [31:0]                btb_target_q[NUM_BTB_ENTRIES-1:0];
reg                       btb_is_call_q[NUM_BTB_ENTRIES-1:0];
reg                       btb_is_ret_q[NUM_BTB_ENTRIES-1:0];
reg                       btb_is_jmp_q[NUM_BTB_ENTRIES-1:0];

wire [31:0] slot0_pc_w = {pc_f_i[31:3], 3'b000};
wire [31:0] slot1_pc_w = {pc_f_i[31:3], 3'b100};

reg        s0_hit_r;
reg        s0_call_r;
reg        s0_ret_r;
reg        s0_jmp_r;
reg [31:0] s0_target_r;
reg [NUM_BTB_ENTRIES_W-1:0] s0_idx_r;

reg        s1_hit_r;
reg        s1_call_r;
reg        s1_ret_r;
reg        s1_jmp_r;
reg [31:0] s1_target_r;
reg [NUM_BTB_ENTRIES_W-1:0] s1_idx_r;

integer i0;
always @ *
begin
    s0_hit_r    = 1'b0;
    s0_call_r   = 1'b0;
    s0_ret_r    = 1'b0;
    s0_jmp_r    = 1'b0;
    s0_target_r = slot0_pc_w + 32'd8;
    s0_idx_r    = {NUM_BTB_ENTRIES_W{1'b0}};

    s1_hit_r    = 1'b0;
    s1_call_r   = 1'b0;
    s1_ret_r    = 1'b0;
    s1_jmp_r    = 1'b0;
    s1_target_r = slot0_pc_w + 32'd8;
    s1_idx_r    = {NUM_BTB_ENTRIES_W{1'b0}};

    for (i0 = 0; i0 < NUM_BTB_ENTRIES; i0 = i0 + 1)
    begin
        if (~pc_f_i[2] && btb_entry_valid_q[i0] && (btb_pc_q[i0] == slot0_pc_w))
        begin
            s0_hit_r    = 1'b1;
            s0_call_r   = btb_is_call_q[i0];
            s0_ret_r    = btb_is_ret_q[i0];
            s0_jmp_r    = btb_is_jmp_q[i0];
            s0_target_r = btb_target_q[i0];
            s0_idx_r    = i0[NUM_BTB_ENTRIES_W-1:0];
        end
        if (btb_entry_valid_q[i0] && (btb_pc_q[i0] == slot1_pc_w))
        begin
            s1_hit_r    = 1'b1;
            s1_call_r   = btb_is_call_q[i0];
            s1_ret_r    = btb_is_ret_q[i0];
            s1_jmp_r    = btb_is_jmp_q[i0];
            s1_target_r = btb_target_q[i0];
            s1_idx_r    = i0[NUM_BTB_ENTRIES_W-1:0];
        end
    end
end

// Slot 0 BHT & prediction evaluation (only active when pc_f_i[2] == 0)
wire [NUM_BHT_ENTRIES_W-1:0] s0_bht_idx_w = GSHARE_ENABLE ?
    (global_history_q ^ {pc_f_i[3+NUM_BHT_ENTRIES_W-2:3], 1'b0}) :
    {pc_f_i[3+NUM_BHT_ENTRIES_W-2:3], 1'b0};
wire s0_bht_taken_w  = BHT_ENABLE && (bht_sat_q[s0_bht_idx_w] >= 2'd2);
wire s0_cond_br_w    = ~(s0_call_r | s0_ret_r | s0_jmp_r);
wire s0_ret_taken_w  = s0_ret_r & (RAS_ENABLE ? ras_top_ok_w : 1'b1);
wire s0_pred_taken_w = s0_hit_r & (s0_call_r | s0_jmp_r | s0_ret_taken_w | (s0_cond_br_w & s0_bht_taken_w));
wire [31:0] s0_pred_pc_w = (s0_ret_r & RAS_ENABLE) ? ras_pc_pred_w : s0_target_r;

// If Slot 0 hit in BTB as not-taken, GHR shifts 0 before evaluating Slot 1
wire [NUM_BHT_ENTRIES_W-1:0] ghr_after_s0_w = s0_hit_r ?
    {global_history_q[NUM_BHT_ENTRIES_W-2:0], s0_pred_taken_w} :
    global_history_q;

// Slot 1 BHT & prediction evaluation (active when pc_f_i[2] == 1 OR Slot 0 is not predicted taken)
wire s1_eval_w = pc_f_i[2] | ~s0_pred_taken_w;
wire [NUM_BHT_ENTRIES_W-1:0] s1_bht_idx_w = GSHARE_ENABLE ?
    (ghr_after_s0_w ^ {pc_f_i[3+NUM_BHT_ENTRIES_W-2:3], 1'b1}) :
    {pc_f_i[3+NUM_BHT_ENTRIES_W-2:3], 1'b1};
wire s1_bht_taken_w  = BHT_ENABLE && (bht_sat_q[s1_bht_idx_w] >= 2'd2);
wire s1_cond_br_w    = ~(s1_call_r | s1_ret_r | s1_jmp_r);
wire s1_ret_taken_w  = s1_ret_r & (RAS_ENABLE ? ras_top_ok_w : 1'b1);
wire s1_pred_taken_w = s1_eval_w & s1_hit_r & (s1_call_r | s1_jmp_r | s1_ret_taken_w | (s1_cond_br_w & s1_bht_taken_w));
wire [31:0] s1_pred_pc_w = (s1_ret_r & RAS_ENABLE) ? ras_pc_pred_w : s1_target_r;

wire [NUM_BHT_ENTRIES_W-1:0] ghr_after_parcel_w = (s1_eval_w & s1_hit_r) ?
    {ghr_after_s0_w[NUM_BHT_ENTRIES_W-2:0], s1_pred_taken_w} :
    ghr_after_s0_w;

// Speculative RAS push / pop on accepted fetch parcel
wire spec_call_w = RAS_ENABLE & ((s0_pred_taken_w & s0_call_r) | (s1_pred_taken_w & s1_call_r));
wire spec_ret_w  = RAS_ENABLE & ((s0_pred_taken_w & s0_ret_r & ras_top_ok_w) | (s1_pred_taken_w & s1_ret_r & ras_top_ok_w));
wire [31:0] spec_call_ret_pc_w = (s0_pred_taken_w & s0_call_r) ? (slot0_pc_w + 32'd4) : (slot1_pc_w + 32'd4);
wire [NUM_RAS_ENTRIES_W-1:0] spec_push_idx_w = ras_index_q + {{(NUM_RAS_ENTRIES_W-1){1'b0}}, 1'b1};

integer i3;
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    for (i3 = 0; i3 < NUM_RAS_ENTRIES; i3 = i3 + 1)
        ras_stack_q[i3] <= RAS_INVALID;
    ras_index_q <= {NUM_RAS_ENTRIES_W{1'b0}};
end
else if (branch_request_i)
begin
    for (i3 = 0; i3 < NUM_RAS_ENTRIES; i3 = i3 + 1)
    begin
        if (real_call_push_w && (i3[NUM_RAS_ENTRIES_W-1:0] == ras_index_real_r))
            ras_stack_q[i3] <= branch_source_i + 32'd4;
        else
            ras_stack_q[i3] <= ras_stack_real_q[i3];
    end
    ras_index_q <= ras_index_real_r;
end
else if (pc_accept_i && spec_call_w)
begin
    ras_stack_q[spec_push_idx_w] <= spec_call_ret_pc_w;
    ras_index_q                  <= spec_push_idx_w;
end
else if (pc_accept_i && spec_ret_w)
begin
    ras_index_q                  <= ras_index_q - {{(NUM_RAS_ENTRIES_W-1){1'b0}}, 1'b1};
end

// Speculative GHR update
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
    global_history_q <= {NUM_BHT_ENTRIES_W{1'b0}};
else if (branch_request_i)
    global_history_q <= global_history_real_next_w;
else if (pc_accept_i && (s0_hit_r || (s1_eval_w && s1_hit_r)))
    global_history_q <= ghr_after_parcel_w;

// BTB update / allocation on resolved branches
reg [NUM_BTB_ENTRIES_W-1:0]  btb_wr_entry_r;
wire [NUM_BTB_ENTRIES_W-1:0] btb_wr_alloc_w;
reg                          btb_hit_r;
reg                          btb_miss_r;

wire btb_learn_w = branch_is_taken_i | (branch_request_i & branch_is_not_taken_i);

integer i1;
always @ *
begin
    btb_wr_entry_r = {NUM_BTB_ENTRIES_W{1'b0}};
    btb_hit_r      = 1'b0;
    btb_miss_r     = 1'b0;

    if (btb_learn_w)
    begin
        for (i1 = 0; i1 < NUM_BTB_ENTRIES; i1 = i1 + 1)
        begin
            if (btb_entry_valid_q[i1] && (btb_pc_q[i1] == branch_source_i))
            begin
                btb_hit_r      = 1'b1;
                btb_wr_entry_r = i1[NUM_BTB_ENTRIES_W-1:0];
            end
        end
        btb_miss_r = branch_is_taken_i & ~btb_hit_r;
    end
end

integer i2;
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    btb_entry_valid_q <= {NUM_BTB_ENTRIES{1'b0}};
    for (i2 = 0; i2 < NUM_BTB_ENTRIES; i2 = i2 + 1)
    begin
        btb_pc_q[i2]      <= 32'b0;
        btb_target_q[i2]  <= 32'b0;
        btb_is_call_q[i2] <= 1'b0;
        btb_is_ret_q[i2]  <= 1'b0;
        btb_is_jmp_q[i2]  <= 1'b0;
    end
end
else if (invalidate_i)
begin
    btb_entry_valid_q <= {NUM_BTB_ENTRIES{1'b0}};
end
else if (btb_hit_r)
begin
    btb_pc_q[btb_wr_entry_r]      <= branch_source_i;
    if (branch_is_taken_i)
        btb_target_q[btb_wr_entry_r] <= branch_pc_i;
    btb_is_call_q[btb_wr_entry_r] <= branch_is_call_i;
    btb_is_ret_q[btb_wr_entry_r]  <= branch_is_ret_i;
    btb_is_jmp_q[btb_wr_entry_r]  <= branch_is_jmp_i;
end
else if (btb_miss_r)
begin
    btb_entry_valid_q[btb_wr_alloc_w] <= 1'b1;
    btb_pc_q[btb_wr_alloc_w]          <= branch_source_i;
    btb_target_q[btb_wr_alloc_w]      <= branch_pc_i;
    btb_is_call_q[btb_wr_alloc_w]     <= branch_is_call_i;
    btb_is_ret_q[btb_wr_alloc_w]      <= branch_is_ret_i;
    btb_is_jmp_q[btb_wr_alloc_w]      <= branch_is_jmp_i;
end

wire lfsr_hit_w = s0_pred_taken_w | s1_pred_taken_w;
wire [NUM_BTB_ENTRIES_W-1:0] lfsr_idx_w = s0_pred_taken_w ? s0_idx_r : s1_idx_r;

biriscv_npc_lfsr
#(
     .DEPTH(NUM_BTB_ENTRIES)
    ,.ADDR_W(NUM_BTB_ENTRIES_W)
)
u_lru
(
     .clk_i(clk_i)
    ,.rst_i(rst_i)
    ,.hit_i(lfsr_hit_w)
    ,.hit_entry_i(lfsr_idx_w)
    ,.alloc_i(btb_miss_r)
    ,.alloc_entry_o(btb_wr_alloc_w)
);

assign next_pc_f_o    = s0_pred_taken_w ? s0_pred_pc_w :
                        (s1_pred_taken_w ? s1_pred_pc_w : (slot0_pc_w + 32'd8));
assign next_taken_f_o = s0_pred_taken_w ? 2'b01 :
                        (s1_pred_taken_w ? 2'b10 : 2'b00);

end
else
begin: NO_BRANCH_PREDICTION

assign next_pc_f_o    = {pc_f_i[31:3], 3'b0} + 32'd8;
assign next_taken_f_o = 2'b00;

end
endgenerate

endmodule


module biriscv_npc_lfsr
#(
     parameter DEPTH            = 32
    ,parameter ADDR_W           = 5
    ,parameter INITIAL_VALUE    = 16'h0001
    ,parameter TAP_VALUE        = 16'hB400
)
(
     input                clk_i
    ,input                rst_i
    ,input                hit_i
    ,input  [ADDR_W-1:0]  hit_entry_i
    ,input                alloc_i

    ,output [ADDR_W-1:0]  alloc_entry_o
);

reg [15:0] lfsr_q;

always @ (posedge clk_i or posedge rst_i)
if (rst_i)
    lfsr_q <= INITIAL_VALUE;
else if (alloc_i)
begin
    if (lfsr_q[0])
        lfsr_q <= {1'b0, lfsr_q[15:1]} ^ TAP_VALUE;
    else
        lfsr_q <= {1'b0, lfsr_q[15:1]};
end

assign alloc_entry_o = lfsr_q[ADDR_W-1:0];

endmodule
