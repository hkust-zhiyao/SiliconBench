// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module redmule_inst_decoder
  import redmule_pkg::*;
#(
  parameter logic [6:0]   McnfigOpCode          = 7'b0001011,
  parameter logic [6:0]   MarithOpCode          = 7'b0001011,
  parameter logic [6:0]   MopcntOpCode          = 7'b0001011,
  parameter logic [2:0]   McnfigFunct3          = 3'b000,
  parameter logic [2:0]   MarithFunct3          = 3'b001,
  parameter logic [2:0]   MopcntFunct3          = 3'b010,
  parameter logic [1:0]   McnfigFunct2          = 2'b00,
  parameter logic [1:0]   MarithFunct2          = 2'b00,
  parameter logic [1:0]   MopcntFunct2          = 2'b00,
  parameter  int unsigned InstFifoDepth         = 4,
  parameter  int unsigned OpIdWidth             = 4,
  parameter  int unsigned XifIdWidth            = 4,
  parameter  int unsigned XifNumHarts           = 1,
  parameter  int unsigned XifIssueRegisterSplit = 0,
  parameter type          x_issue_req_t         = logic,
  parameter type          x_issue_resp_t        = logic,
  parameter type          x_register_t          = logic,
  parameter type          x_commit_t            = logic,
  parameter type          x_result_t            = logic
)(
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            clear_i,
  input  logic            config_ready_i,
  input  logic            op_done_i,
  output logic            config_valid_o,
  output redmule_config_t config_o,
  input  x_issue_req_t    x_issue_req_i,
  output x_issue_resp_t   x_issue_resp_o,
  input  logic            x_issue_valid_i,
  output logic            x_issue_ready_o,
  input  x_register_t     x_register_i,
  input  logic            x_register_valid_i,
  output logic            x_register_ready_o,
  input  x_commit_t       x_commit_i,
  input  logic            x_commit_valid_i,
  output x_result_t       x_result_o,
  output logic            x_result_valid_o,
  input  logic            x_result_ready_i
);

  localparam int unsigned HartIdWidth   = XifNumHarts > 1 ? $clog2(XifNumHarts) : 1;
  localparam int unsigned SlotIdxWidth  = InstFifoDepth > 1 ? $clog2(InstFifoDepth) : 1;
  localparam int unsigned SlotCntWidth  = $clog2(InstFifoDepth + 1);
  localparam int unsigned InflightDepth = InstFifoDepth * XifNumHarts + 8;

  localparam logic [11:0] MCNFIG = {McnfigFunct2, McnfigFunct3, McnfigOpCode};
  localparam logic [11:0] MARITH = {MarithFunct2, MarithFunct3, MarithOpCode};
  localparam logic [11:0] MOPCNT = {MopcntFunct2, MopcntFunct3, MopcntOpCode};

  // Issue legality decode
  logic [11:0] issue_key;
  logic        issue_hart_ok;
  logic        legal_inst;

  assign issue_key     = {x_issue_req_i.instr[26:25], x_issue_req_i.instr[14:12], x_issue_req_i.instr[6:0]};
  assign issue_hart_ok = (32'(x_issue_req_i.hartid) < XifNumHarts);

  always_comb begin : legal_inst_decode
    legal_inst = 1'b0;
    if (issue_hart_ok) begin
      unique case (issue_key)
        MCNFIG, MARITH, MOPCNT: legal_inst = 1'b1;
        default:                legal_inst = 1'b0;
      endcase
    end
  end

  always_comb begin : issue_resp_decode
    x_issue_resp_o = '0;
    x_issue_resp_o.accept = legal_inst;
    if (issue_hart_ok) begin
      unique case (issue_key)
        MCNFIG: begin
          x_issue_resp_o.writeback     = 1'b0;
          x_issue_resp_o.register_read = 3'b111;
        end
        MARITH: begin
          x_issue_resp_o.writeback     = (x_issue_req_i.instr[11:7] != 5'd0);
          x_issue_resp_o.register_read = 3'b111;
        end
        MOPCNT: begin
          x_issue_resp_o.writeback     = (x_issue_req_i.instr[11:7] != 5'd0);
          x_issue_resp_o.register_read = 3'b000;
        end
        default: begin
          x_issue_resp_o.writeback     = 1'b0;
          x_issue_resp_o.register_read = 3'b000;
        end
      endcase
    end
  end

  // Per-hart circular scoreboard state
  logic [XifNumHarts-1:0][InstFifoDepth-1:0]               slot_valid_q,     slot_valid_d;
  logic [XifNumHarts-1:0][InstFifoDepth-1:0][31:0]         slot_instr_q,     slot_instr_d;
  logic [XifNumHarts-1:0][InstFifoDepth-1:0][XifIdWidth-1:0] slot_id_q,      slot_id_d;
  logic [XifNumHarts-1:0][InstFifoDepth-1:0][2:0][31:0]    slot_rs_q,        slot_rs_d;
  logic [XifNumHarts-1:0][InstFifoDepth-1:0][2:0]          slot_rs_valid_q,  slot_rs_valid_d;
  logic [XifNumHarts-1:0][InstFifoDepth-1:0]               slot_committed_q, slot_committed_d;
  logic [XifNumHarts-1:0][InstFifoDepth-1:0]               slot_killed_q,    slot_killed_d;

  logic [XifNumHarts-1:0][SlotIdxWidth-1:0]                head_ptr_q, head_ptr_d;
  logic [XifNumHarts-1:0][SlotIdxWidth-1:0]                tail_ptr_q, tail_ptr_d;
  logic [XifNumHarts-1:0][SlotCntWidth-1:0]                slot_cnt_q, slot_cnt_d;

  logic [XifNumHarts-1:0] slot_full;
  logic [XifNumHarts-1:0] has_pending_reg_slot;

  // Per-hart architectural configs & op counters
  redmule_config_t [XifNumHarts-1:0]      config_q, config_next;
  logic [XifNumHarts-1:0][OpIdWidth-1:0]  op_id_counter_in_q;
  logic [XifNumHarts-1:0][OpIdWidth-1:0]  op_id_counter_out_q;

  // Head-of-hart candidate decode & readiness
  logic [XifNumHarts-1:0]       hart_head_ready;
  logic [XifNumHarts-1:0]       hart_head_is_marith;
  logic [XifNumHarts-1:0]       hart_head_is_mcnfig;
  redmule_config_t [XifNumHarts-1:0] hart_head_cfg;
  x_result_t [XifNumHarts-1:0]  hart_head_res;

  // Output result FIFO (decouples x_result_ready_i from config_valid_o)
  logic      res_fifo_full, res_fifo_empty;
  logic      res_fifo_push, res_fifo_pop;
  x_result_t res_fifo_din,  res_fifo_dout;

  // In-flight hart ID completion FIFO
  logic                   hartid_fifo_full, hartid_fifo_empty;
  logic [HartIdWidth-1:0] completing_hartid;

  // Round-robin state
  logic [HartIdWidth-1:0] rr_counter_q, rr_counter_d;
  logic [HartIdWidth-1:0] winner;
  logic                   any_winner_valid;
  logic                   retire_fire;
  logic                   marith_fire;

  // Ready generation on issue and register channels
  always_comb begin : issue_ready_gen
    x_issue_ready_o = 1'b0;
    for (int unsigned h = 0; h < XifNumHarts; h++) begin
      if (32'(x_issue_req_i.hartid) == h) begin
        x_issue_ready_o = ~slot_full[h];
      end
    end
  end

  always_comb begin : register_ready_gen
    x_register_ready_o = 1'b0;
    for (int unsigned h = 0; h < XifNumHarts; h++) begin
      if (32'(x_register_i.hartid) == h) begin
        x_register_ready_o = has_pending_reg_slot[h] || ~slot_full[h];
      end
    end
  end

  // Per-hart head instruction evaluation
  for (genvar h = 0; h < XifNumHarts; h++) begin : gen_hart_head_eval
    logic [SlotIdxWidth-1:0] h_idx;
    logic [31:0]             h_instr;
    logic [11:0]             h_key;
    logic                    h_valid, h_comm, h_kill, h_ops_ok;

    assign slot_full[h] = (slot_cnt_q[h] == SlotCntWidth'(InstFifoDepth));
    assign h_idx        = head_ptr_q[h];
    assign h_valid      = (slot_cnt_q[h] != '0) && slot_valid_q[h][h_idx];
    assign h_instr      = slot_instr_q[h][h_idx];
    assign h_key        = {h_instr[26:25], h_instr[14:12], h_instr[6:0]};
    assign h_comm       = slot_committed_q[h][h_idx];
    assign h_kill       = slot_killed_q[h][h_idx];
    assign h_ops_ok     = (slot_rs_valid_q[h][h_idx] == 3'b111);

    assign hart_head_is_marith[h] = (h_key == MARITH);
    assign hart_head_is_mcnfig[h] = (h_key == MCNFIG);

    always_comb begin
      has_pending_reg_slot[h] = 1'b0;
      for (int unsigned s = 0; s < InstFifoDepth; s++) begin
        if (slot_valid_q[h][s] && !slot_killed_q[h][s] && (slot_rs_valid_q[h][s] != 3'b111)) begin
          has_pending_reg_slot[h] = 1'b1;
        end
      end
    end

    always_comb begin
      hart_head_cfg[h]            = config_q[h];
      hart_head_cfg[h].loopback_w = 1'b0;
      unique case (h_key)
        MCNFIG: begin
          hart_head_cfg[h].m_size          = slot_rs_q[h][h_idx][0][15:0];
          hart_head_cfg[h].k_size          = slot_rs_q[h][h_idx][0][31:16];
          hart_head_cfg[h].n_size          = slot_rs_q[h][h_idx][1][15:0];
          hart_head_cfg[h].receive_x       = slot_rs_q[h][h_idx][1][16];
          hart_head_cfg[h].send_x          = slot_rs_q[h][h_idx][1][17];
          hart_head_cfg[h].receive_w       = slot_rs_q[h][h_idx][1][18];
          hart_head_cfg[h].send_w          = slot_rs_q[h][h_idx][1][19];
          hart_head_cfg[h].gemm_ops        = gemm_op_e'(slot_rs_q[h][h_idx][1][22:20]);
          hart_head_cfg[h].gemm_input_fmt  = gemm_fmt_e'(slot_rs_q[h][h_idx][1][24:23]);
          hart_head_cfg[h].gemm_output_fmt = gemm_fmt_e'(slot_rs_q[h][h_idx][1][26:25]);
          hart_head_cfg[h].y_offs          = slot_rs_q[h][h_idx][2][31:0];
          hart_head_cfg[h].w_cols_offset   = 16'd0;
        end
        MARITH: begin
          hart_head_cfg[h].x_addr          = slot_rs_q[h][h_idx][0][31:0];
          hart_head_cfg[h].w_addr          = slot_rs_q[h][h_idx][1][31:0];
          hart_head_cfg[h].z_addr          = slot_rs_q[h][h_idx][2][31:0];
        end
        default: begin
          hart_head_cfg[h] = config_q[h];
        end
      endcase
    end

    always_comb begin
      hart_head_res[h]        = '0;
      hart_head_res[h].hartid = HartIdWidth'(h);
      hart_head_res[h].id     = slot_id_q[h][h_idx];
      hart_head_res[h].rd     = h_instr[11:7];
      unique case (h_key)
        MCNFIG: begin
          hart_head_res[h].we   = 1'b0;
          hart_head_res[h].data = 32'd0;
        end
        MARITH: begin
          hart_head_res[h].we   = (h_instr[11:7] != 5'd0);
          hart_head_res[h].data = 32'(op_id_counter_in_q[h]);
        end
        MOPCNT: begin
          hart_head_res[h].we   = (h_instr[11:7] != 5'd0);
          hart_head_res[h].data = 32'(op_id_counter_out_q[h]);
        end
        default: begin
          hart_head_res[h].we   = 1'b0;
          hart_head_res[h].data = 32'd0;
        end
      endcase
    end

    assign hart_head_ready[h] = h_valid && h_comm && !h_kill && h_ops_ok && !res_fifo_full &&
                                ((h_key == MARITH) ? (config_ready_i && !hartid_fifo_full) : 1'b1);
  end

  // Starvation-free round-robin winner selection across ready harts
  always_comb begin : rr_arbiter
    winner           = rr_counter_q;
    any_winner_valid = 1'b0;
    for (int unsigned off = 0; off < XifNumHarts; off++) begin
      int unsigned cand;
      cand = (32'(rr_counter_q) + off < XifNumHarts) ?
             (32'(rr_counter_q) + off) :
             (32'(rr_counter_q) + off - XifNumHarts);
      if (!any_winner_valid && hart_head_ready[cand]) begin
        winner           = HartIdWidth'(cand);
        any_winner_valid = 1'b1;
      end
    end
  end

  assign retire_fire    = any_winner_valid;
  assign marith_fire    = retire_fire && hart_head_is_marith[winner];
  assign config_valid_o = marith_fire;
  assign config_o       = hart_head_cfg[winner];

  assign rr_counter_d = (32'(winner) + 1 >= XifNumHarts) ? '0 : (winner + 1'b1);

  always_ff @(posedge clk_i or negedge rst_ni) begin : rr_counter_reg
    if (!rst_ni) begin
      rr_counter_q <= '0;
    end else if (clear_i) begin
      rr_counter_q <= '0;
    end else if (retire_fire) begin
      rr_counter_q <= rr_counter_d;
    end
  end

  // Registered x_result output FIFO (depth 2, zero combinational x_result_ready_i -> config_valid_o path)
  assign res_fifo_push = retire_fire;
  assign res_fifo_din  = hart_head_res[winner];
  assign res_fifo_pop  = x_result_valid_o && x_result_ready_i;

  redmule_config_fifo #(
    .FALL_THROUGH ( 0          ),
    .DEPTH        ( 2          ),
    .dtype        ( x_result_t )
  ) i_result_fifo (
    .clk_i      ( clk_i          ),
    .rst_ni     ( rst_ni         ),
    .flush_i    ( clear_i        ),
    .testmode_i ( 1'b0           ),
    .full_o     ( res_fifo_full  ),
    .empty_o    ( res_fifo_empty ),
    .usage_o    (                ),
    .data_i     ( res_fifo_din   ),
    .push_i     ( res_fifo_push  ),
    .data_o     ( res_fifo_dout  ),
    .pop_i      ( res_fifo_pop   )
  );

  assign x_result_valid_o = ~res_fifo_empty;
  assign x_result_o       = res_fifo_dout;

  // In-flight hart completion tracker FIFO
  redmule_config_fifo #(
    .FALL_THROUGH ( 0             ),
    .DEPTH        ( InflightDepth ),
    .DATA_WIDTH   ( HartIdWidth   )
  ) i_current_hartid_fifo (
    .clk_i      ( clk_i                             ),
    .rst_ni     ( rst_ni                            ),
    .flush_i    ( clear_i                           ),
    .testmode_i ( 1'b0                              ),
    .full_o     ( hartid_fifo_full                  ),
    .empty_o    ( hartid_fifo_empty                 ),
    .usage_o    (                                   ),
    .data_i     ( winner                            ),
    .push_i     ( marith_fire                       ),
    .data_o     ( completing_hartid                 ),
    .pop_i      ( op_done_i && !hartid_fifo_empty   )
  );

  // Per-hart scoreboard update, config registers, and op ID counters
  for (genvar h = 0; h < XifNumHarts; h++) begin : gen_hart_state
    always_comb begin
      logic issue_push_h;
      logic reg_beat_h;
      logic commit_beat_h;
      logic pop_head_h;
      logic [2:0] eff_rs_valid;
      logic reg_matched_existing;

      slot_valid_d[h]     = slot_valid_q[h];
      slot_instr_d[h]     = slot_instr_q[h];
      slot_id_d[h]        = slot_id_q[h];
      slot_rs_d[h]        = slot_rs_q[h];
      slot_rs_valid_d[h]  = slot_rs_valid_q[h];
      slot_committed_d[h] = slot_committed_q[h];
      slot_killed_d[h]    = slot_killed_q[h];
      head_ptr_d[h]       = head_ptr_q[h];
      tail_ptr_d[h]       = tail_ptr_q[h];
      slot_cnt_d[h]       = slot_cnt_q[h];
      config_next[h]      = config_q[h];

      issue_push_h  = x_issue_valid_i && x_issue_ready_o && legal_inst && (32'(x_issue_req_i.hartid) == h);
      reg_beat_h    = x_register_valid_i && x_register_ready_o && (32'(x_register_i.hartid) == h);
      commit_beat_h = x_commit_valid_i && (32'(x_commit_i.hartid) == h);

      eff_rs_valid = (XifIssueRegisterSplit == 0) ?
                     ((x_register_i.rs_valid == 3'b000) ? 3'b111 : x_register_i.rs_valid) :
                     x_register_i.rs_valid;

      // 1. Update existing valid slots on x_register
      reg_matched_existing = 1'b0;
      if (reg_beat_h) begin
        for (int unsigned off = 0; off < InstFifoDepth; off++) begin
          int unsigned idx;
          idx = (32'(head_ptr_q[h]) + off < InstFifoDepth) ?
                (32'(head_ptr_q[h]) + off) :
                (32'(head_ptr_q[h]) + off - InstFifoDepth);
          if (!reg_matched_existing && slot_valid_q[h][idx] && !slot_killed_q[h][idx] &&
              (slot_rs_valid_q[h][idx] != 3'b111)) begin
            if ((XifIssueRegisterSplit == 0) || (slot_id_q[h][idx] == x_register_i.id)) begin
              for (int unsigned r = 0; r < 3; r++) begin
                if (eff_rs_valid[r]) begin
                  slot_rs_d[h][idx][r]       = x_register_i.rs[r];
                  slot_rs_valid_d[h][idx][r] = 1'b1;
                end
              end
              reg_matched_existing = 1'b1;
            end
          end
        end
      end

      // 2. Update existing valid slots on x_commit
      if (commit_beat_h) begin
        for (int unsigned off = 0; off < InstFifoDepth; off++) begin
          int unsigned idx;
          idx = (32'(head_ptr_q[h]) + off < InstFifoDepth) ?
                (32'(head_ptr_q[h]) + off) :
                (32'(head_ptr_q[h]) + off - InstFifoDepth);
          if (slot_valid_q[h][idx] && !slot_committed_q[h][idx] && !slot_killed_q[h][idx] &&
              (slot_id_q[h][idx] == x_commit_i.id)) begin
            if (x_commit_i.commit_kill) begin
              slot_killed_d[h][idx] = 1'b1;
            end else begin
              slot_committed_d[h][idx] = 1'b1;
            end
          end
        end
      end

      // 3. Pop head slot if retiring OR if head slot is killed
      pop_head_h = 1'b0;
      if ((retire_fire && (32'(winner) == h)) ||
          ((slot_cnt_q[h] != '0) && slot_valid_q[h][head_ptr_q[h]] && slot_killed_d[h][head_ptr_q[h]])) begin
        pop_head_h = 1'b1;
        if (retire_fire && (32'(winner) == h)) begin
          config_next[h] = hart_head_cfg[h];
        end
        slot_valid_d[h][head_ptr_q[h]]     = 1'b0;
        slot_committed_d[h][head_ptr_q[h]] = 1'b0;
        slot_killed_d[h][head_ptr_q[h]]    = 1'b0;
        slot_rs_valid_d[h][head_ptr_q[h]]  = 3'b000;
        head_ptr_d[h] = (32'(head_ptr_q[h]) + 1 >= InstFifoDepth) ? '0 : (head_ptr_q[h] + 1'b1);
      end

      // 4. Push newly accepted instruction at tail_ptr_q
      if (issue_push_h) begin
        logic is_mopcnt_push;
        is_mopcnt_push = (issue_key == MOPCNT);

        slot_valid_d[h][tail_ptr_q[h]]     = 1'b1;
        slot_instr_d[h][tail_ptr_q[h]]     = x_issue_req_i.instr;
        slot_id_d[h][tail_ptr_q[h]]        = x_issue_req_i.id;
        slot_rs_d[h][tail_ptr_q[h]]        = '0;
        slot_rs_valid_d[h][tail_ptr_q[h]]  = is_mopcnt_push ? 3'b111 : 3'b000;
        slot_committed_d[h][tail_ptr_q[h]] = 1'b0;
        slot_killed_d[h][tail_ptr_q[h]]    = 1'b0;

        if (!is_mopcnt_push && reg_beat_h && !reg_matched_existing &&
            ((XifIssueRegisterSplit == 0) || (x_register_i.id == x_issue_req_i.id))) begin
          for (int unsigned r = 0; r < 3; r++) begin
            if (eff_rs_valid[r]) begin
              slot_rs_d[h][tail_ptr_q[h]][r]       = x_register_i.rs[r];
              slot_rs_valid_d[h][tail_ptr_q[h]][r] = 1'b1;
            end
          end
        end

        if (commit_beat_h && (x_commit_i.id == x_issue_req_i.id)) begin
          if (x_commit_i.commit_kill) begin
            slot_killed_d[h][tail_ptr_q[h]] = 1'b1;
          end else begin
            slot_committed_d[h][tail_ptr_q[h]] = 1'b1;
          end
        end

        tail_ptr_d[h] = (32'(tail_ptr_q[h]) + 1 >= InstFifoDepth) ? '0 : (tail_ptr_q[h] + 1'b1);
      end

      unique case ({issue_push_h, pop_head_h})
        2'b10:   slot_cnt_d[h] = slot_cnt_q[h] + 1'b1;
        2'b01:   slot_cnt_d[h] = slot_cnt_q[h] - 1'b1;
        default: slot_cnt_d[h] = slot_cnt_q[h];
      endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        slot_valid_q[h]         <= '0;
        slot_instr_q[h]         <= '0;
        slot_id_q[h]            <= '0;
        slot_rs_q[h]            <= '0;
        slot_rs_valid_q[h]      <= '0;
        slot_committed_q[h]     <= '0;
        slot_killed_q[h]        <= '0;
        head_ptr_q[h]           <= '0;
        tail_ptr_q[h]           <= '0;
        slot_cnt_q[h]           <= '0;
        config_q[h]             <= '0;
        op_id_counter_in_q[h]   <= '0;
        op_id_counter_out_q[h]  <= '1;
      end else if (clear_i) begin
        slot_valid_q[h]         <= '0;
        slot_instr_q[h]         <= '0;
        slot_id_q[h]            <= '0;
        slot_rs_q[h]            <= '0;
        slot_rs_valid_q[h]      <= '0;
        slot_committed_q[h]     <= '0;
        slot_killed_q[h]        <= '0;
        head_ptr_q[h]           <= '0;
        tail_ptr_q[h]           <= '0;
        slot_cnt_q[h]           <= '0;
        config_q[h]             <= '0;
        op_id_counter_in_q[h]   <= '0;
        op_id_counter_out_q[h]  <= '1;
      end else begin
        slot_valid_q[h]         <= slot_valid_d[h];
        slot_instr_q[h]         <= slot_instr_d[h];
        slot_id_q[h]            <= slot_id_d[h];
        slot_rs_q[h]            <= slot_rs_d[h];
        slot_rs_valid_q[h]      <= slot_rs_valid_d[h];
        slot_committed_q[h]     <= slot_committed_d[h];
        slot_killed_q[h]        <= slot_killed_d[h];
        head_ptr_q[h]           <= head_ptr_d[h];
        tail_ptr_q[h]           <= tail_ptr_d[h];
        slot_cnt_q[h]           <= slot_cnt_d[h];
        config_q[h]             <= config_next[h];

        if (marith_fire && (32'(winner) == h)) begin
          op_id_counter_in_q[h] <= op_id_counter_in_q[h] + 1'b1;
        end
        if (op_done_i && !hartid_fifo_empty && (32'(completing_hartid) == h)) begin
          op_id_counter_out_q[h] <= op_id_counter_out_q[h] + 1'b1;
        end
      end
    end
  end

endmodule : redmule_inst_decoder
