// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Alternate Gold implementation: Age-ordered compacting CAM slot pool per hart
// (immediate slot reclamation on mid-queue commit_kill) + custom 2-beat ping-pong
// output register bank and shift-array hart tracker.

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

  localparam int unsigned HartW     = XifNumHarts > 1 ? $clog2(XifNumHarts) : 1;
  localparam int unsigned CntW      = $clog2(InstFifoDepth + 1);
  localparam int unsigned TrackCap  = InstFifoDepth * XifNumHarts + 8;
  localparam int unsigned TrackPtrW = $clog2(TrackCap);
  localparam int unsigned TrackCntW = $clog2(TrackCap + 1);

  localparam logic [11:0] ENC_MCNFIG = {McnfigFunct2, McnfigFunct3, McnfigOpCode};
  localparam logic [11:0] ENC_MARITH = {MarithFunct2, MarithFunct3, MarithOpCode};
  localparam logic [11:0] ENC_MOPCNT = {MopcntFunct2, MopcntFunct3, MopcntOpCode};

  typedef struct packed {
    logic                  valid;
    logic [31:0]           instr;
    logic [XifIdWidth-1:0] id;
    logic [2:0][31:0]      rs;
    logic [2:0]            rs_mask;
    logic                  committed;
  } shift_entry_t;

  // Compacting shift-queue per hart: index 0 is always oldest!
  shift_entry_t [XifNumHarts-1:0][InstFifoDepth-1:0] q_cur, q_nxt;
  logic [XifNumHarts-1:0][CntW-1:0]                  q_occ_cur, q_occ_nxt;

  redmule_config_t [XifNumHarts-1:0]     hart_cfg_q, hart_cfg_d;
  logic [XifNumHarts-1:0][OpIdWidth-1:0] issue_tag_q;
  logic [XifNumHarts-1:0][OpIdWidth-1:0] done_tag_q;

  // Custom 2-slot ping-pong result buffer
  x_result_t [1:0] out_buf_q;
  logic            out_wptr_q, out_rptr_q;
  logic [1:0]      out_occ_q;
  logic            out_buf_full, out_buf_empty;

  // Custom ring tracker for in-flight MARITH hart IDs
  logic [TrackCap-1:0][HartW-1:0] trk_mem_q;
  logic [TrackPtrW-1:0]           trk_wptr_q, trk_rptr_q;
  logic [TrackCntW-1:0]           trk_occ_q;
  logic                           trk_full, trk_empty;

  // Decode issue request
  logic [11:0] req_enc;
  logic        req_hart_in_range;
  logic        req_is_legal;

  assign req_enc           = {x_issue_req_i.instr[26:25], x_issue_req_i.instr[14:12], x_issue_req_i.instr[6:0]};
  assign req_hart_in_range = (32'(x_issue_req_i.hartid) < XifNumHarts);
  assign req_is_legal      = req_hart_in_range &&
                             ((req_enc == ENC_MCNFIG) || (req_enc == ENC_MARITH) || (req_enc == ENC_MOPCNT));

  always_comb begin
    x_issue_resp_o = '0;
    if (req_is_legal) begin
      x_issue_resp_o.accept = 1'b1;
      unique case (req_enc)
        ENC_MCNFIG: begin
          x_issue_resp_o.writeback     = 1'b0;
          x_issue_resp_o.register_read = 3'b111;
        end
        ENC_MARITH: begin
          x_issue_resp_o.writeback     = (x_issue_req_i.instr[11:7] != 5'd0);
          x_issue_resp_o.register_read = 3'b111;
        end
        ENC_MOPCNT: begin
          x_issue_resp_o.writeback     = (x_issue_req_i.instr[11:7] != 5'd0);
          x_issue_resp_o.register_read = 3'b000;
        end
        default: ;
      endcase
    end
  end

  logic [XifNumHarts-1:0] hart_full, hart_needs_reg;
  for (genvar h = 0; h < XifNumHarts; h++) begin : gen_rdy_flags
    assign hart_full[h] = (q_occ_cur[h] == CntW'(InstFifoDepth));
    always_comb begin
      hart_needs_reg[h] = 1'b0;
      for (int unsigned k = 0; k < InstFifoDepth; k++) begin
        if (q_cur[h][k].valid && (q_cur[h][k].rs_mask != 3'b111)) begin
          hart_needs_reg[h] = 1'b1;
        end
      end
    end
  end

  always_comb begin
    x_issue_ready_o    = 1'b0;
    x_register_ready_o = 1'b0;
    for (int unsigned h = 0; h < XifNumHarts; h++) begin
      if (32'(x_issue_req_i.hartid) == h) begin
        x_issue_ready_o = ~hart_full[h];
      end
      if (32'(x_register_i.hartid) == h) begin
        x_register_ready_o = hart_needs_reg[h] || ~hart_full[h];
      end
    end
  end

  assign out_buf_full  = (out_occ_q == 2'd2);
  assign out_buf_empty = (out_occ_q == 2'd0);
  assign trk_full      = (trk_occ_q == TrackCntW'(TrackCap));
  assign trk_empty     = (trk_occ_q == '0);

  // Evaluate oldest entry (index 0) per hart
  logic [XifNumHarts-1:0]            head_can_retire;
  logic [XifNumHarts-1:0]            head_is_marith;
  redmule_config_t [XifNumHarts-1:0] head_cfg_cand;
  x_result_t [XifNumHarts-1:0]       head_res_cand;

  for (genvar h = 0; h < XifNumHarts; h++) begin : gen_head_cand
    logic [11:0] e0_enc;
    logic        e0_killed_now;
    assign e0_enc        = {q_cur[h][0].instr[26:25], q_cur[h][0].instr[14:12], q_cur[h][0].instr[6:0]};
    assign e0_killed_now = x_commit_valid_i && x_commit_i.commit_kill &&
                           (32'(x_commit_i.hartid) == h) && q_cur[h][0].valid && (q_cur[h][0].id == x_commit_i.id);
    assign head_is_marith[h] = (e0_enc == ENC_MARITH);

    always_comb begin
      head_cfg_cand[h]            = hart_cfg_q[h];
      head_cfg_cand[h].loopback_w = 1'b0;
      if (e0_enc == ENC_MCNFIG) begin
        head_cfg_cand[h].m_size          = q_cur[h][0].rs[0][15:0];
        head_cfg_cand[h].k_size          = q_cur[h][0].rs[0][31:16];
        head_cfg_cand[h].n_size          = q_cur[h][0].rs[1][15:0];
        head_cfg_cand[h].receive_x       = q_cur[h][0].rs[1][16];
        head_cfg_cand[h].send_x          = q_cur[h][0].rs[1][17];
        head_cfg_cand[h].receive_w       = q_cur[h][0].rs[1][18];
        head_cfg_cand[h].send_w          = q_cur[h][0].rs[1][19];
        head_cfg_cand[h].gemm_ops        = gemm_op_e'(q_cur[h][0].rs[1][22:20]);
        head_cfg_cand[h].gemm_input_fmt  = gemm_fmt_e'(q_cur[h][0].rs[1][24:23]);
        head_cfg_cand[h].gemm_output_fmt = gemm_fmt_e'(q_cur[h][0].rs[1][26:25]);
        head_cfg_cand[h].y_offs          = q_cur[h][0].rs[2][31:0];
        head_cfg_cand[h].w_cols_offset   = 16'd0;
      end else if (e0_enc == ENC_MARITH) begin
        head_cfg_cand[h].x_addr          = q_cur[h][0].rs[0];
        head_cfg_cand[h].w_addr          = q_cur[h][0].rs[1];
        head_cfg_cand[h].z_addr          = q_cur[h][0].rs[2];
      end
    end

    always_comb begin
      head_res_cand[h]        = '0;
      head_res_cand[h].hartid = HartW'(h);
      head_res_cand[h].id     = q_cur[h][0].id;
      head_res_cand[h].rd     = q_cur[h][0].instr[11:7];
      unique case (e0_enc)
        ENC_MCNFIG: begin
          head_res_cand[h].we   = 1'b0;
          head_res_cand[h].data = 32'd0;
        end
        ENC_MARITH: begin
          head_res_cand[h].we   = (q_cur[h][0].instr[11:7] != 5'd0);
          head_res_cand[h].data = 32'(issue_tag_q[h]);
        end
        ENC_MOPCNT: begin
          head_res_cand[h].we   = (q_cur[h][0].instr[11:7] != 5'd0);
          head_res_cand[h].data = 32'(done_tag_q[h]);
        end
        default: ;
      endcase
    end

    assign head_can_retire[h] = q_cur[h][0].valid && q_cur[h][0].committed && !e0_killed_now &&
                                (q_cur[h][0].rs_mask == 3'b111) && !out_buf_full &&
                                ((e0_enc == ENC_MARITH) ? (config_ready_i && !trk_full) : 1'b1);
  end

  logic [HartW-1:0] rr_ptr_q;
  logic [HartW-1:0] sel_hart;
  logic             sel_valid;
  logic             do_marith;

  always_comb begin
    sel_hart  = rr_ptr_q;
    sel_valid = 1'b0;
    for (int unsigned step = 0; step < XifNumHarts; step++) begin
      int unsigned idx;
      idx = (32'(rr_ptr_q) + step < XifNumHarts) ? (32'(rr_ptr_q) + step) : (32'(rr_ptr_q) + step - XifNumHarts);
      if (!sel_valid && head_can_retire[idx]) begin
        sel_hart  = HartW'(idx);
        sel_valid = 1'b1;
      end
    end
  end

  assign do_marith        = sel_valid && head_is_marith[sel_hart];
  assign config_valid_o   = do_marith;
  assign config_o         = head_cfg_cand[sel_hart];
  assign x_result_valid_o = ~out_buf_empty;
  assign x_result_o       = out_buf_q[out_rptr_q];

  // Ping-pong output buffer + in-flight tracker + round-robin pointer
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_buf_q  <= '0;
      out_wptr_q <= 1'b0;
      out_rptr_q <= 1'b0;
      out_occ_q  <= '0;
      trk_mem_q  <= '0;
      trk_wptr_q <= '0;
      trk_rptr_q <= '0;
      trk_occ_q  <= '0;
      rr_ptr_q   <= '0;
    end else if (clear_i) begin
      out_buf_q  <= '0;
      out_wptr_q <= 1'b0;
      out_rptr_q <= 1'b0;
      out_occ_q  <= '0;
      trk_mem_q  <= '0;
      trk_wptr_q <= '0;
      trk_rptr_q <= '0;
      trk_occ_q  <= '0;
      rr_ptr_q   <= '0;
    end else begin
      logic out_push, out_pop;
      logic trk_push, trk_pop;
      out_push = sel_valid;
      out_pop  = x_result_valid_o && x_result_ready_i;

      if (out_push) begin
        out_buf_q[out_wptr_q] <= head_res_cand[sel_hart];
        out_wptr_q            <= ~out_wptr_q;
        rr_ptr_q              <= (32'(sel_hart) + 1 >= XifNumHarts) ? '0 : (sel_hart + 1'b1);
      end
      if (out_pop) begin
        out_rptr_q <= ~out_rptr_q;
      end
      unique case ({out_push, out_pop})
        2'b10:   out_occ_q <= out_occ_q + 2'd1;
        2'b01:   out_occ_q <= out_occ_q - 2'd1;
        default: out_occ_q <= out_occ_q;
      endcase

      trk_push = do_marith;
      trk_pop  = op_done_i && !trk_empty;
      if (trk_push) begin
        trk_mem_q[trk_wptr_q] <= sel_hart;
        trk_wptr_q            <= (32'(trk_wptr_q) + 1 >= TrackCap) ? '0 : (trk_wptr_q + 1'b1);
      end
      if (trk_pop) begin
        trk_rptr_q <= (32'(trk_rptr_q) + 1 >= TrackCap) ? '0 : (trk_rptr_q + 1'b1);
      end
      unique case ({trk_push, trk_pop})
        2'b10:   trk_occ_q <= trk_occ_q + 1'b1;
        2'b01:   trk_occ_q <= trk_occ_q - 1'b1;
        default: trk_occ_q <= trk_occ_q;
      endcase
    end
  end

  // Compacting queue update per hart
  for (genvar h = 0; h < XifNumHarts; h++) begin : gen_compacting_queue
    always_comb begin
      shift_entry_t [InstFifoDepth-1:0] tmp;
      logic [InstFifoDepth-1:0]         drop;
      logic [CntW-1:0]                  wr_pos;
      logic                             push_new, reg_fire, com_fire, matched_reg;
      logic [2:0]                       rmask;

      tmp         = q_cur[h];
      drop        = '0;
      hart_cfg_d[h] = hart_cfg_q[h];

      push_new = x_issue_valid_i && x_issue_ready_o && req_is_legal && (32'(x_issue_req_i.hartid) == h);
      reg_fire = x_register_valid_i && x_register_ready_o && (32'(x_register_i.hartid) == h);
      com_fire = x_commit_valid_i && (32'(x_commit_i.hartid) == h);
      rmask    = (XifIssueRegisterSplit == 0) ?
                 ((x_register_i.rs_valid == 3'b000) ? 3'b111 : x_register_i.rs_valid) :
                 x_register_i.rs_valid;

      matched_reg = 1'b0;
      if (reg_fire) begin
        for (int unsigned k = 0; k < InstFifoDepth; k++) begin
          if (!matched_reg && tmp[k].valid && (tmp[k].rs_mask != 3'b111)) begin
            if ((XifIssueRegisterSplit == 0) || (tmp[k].id == x_register_i.id)) begin
              for (int unsigned b = 0; b < 3; b++) begin
                if (rmask[b]) begin
                  tmp[k].rs[b]      = x_register_i.rs[b];
                  tmp[k].rs_mask[b] = 1'b1;
                end
              end
              matched_reg = 1'b1;
            end
          end
        end
      end

      if (com_fire) begin
        for (int unsigned k = 0; k < InstFifoDepth; k++) begin
          if (tmp[k].valid && !tmp[k].committed && (tmp[k].id == x_commit_i.id)) begin
            if (x_commit_i.commit_kill) begin
              drop[k] = 1'b1;
            end else begin
              tmp[k].committed = 1'b1;
            end
          end
        end
      end

      if (sel_valid && (32'(sel_hart) == h)) begin
        drop[0]       = 1'b1;
        hart_cfg_d[h] = head_cfg_cand[h];
      end

      // Compact surviving entries toward index 0
      q_nxt[h] = '0;
      wr_pos   = '0;
      for (int unsigned k = 0; k < InstFifoDepth; k++) begin
        if (tmp[k].valid && !drop[k]) begin
          q_nxt[h][wr_pos] = tmp[k];
          wr_pos           = wr_pos + 1'b1;
        end
      end

      // Append newly issued entry unless killed in the exact same cycle
      if (push_new) begin
        logic killed_same_cyc;
        killed_same_cyc = com_fire && x_commit_i.commit_kill && (x_commit_i.id == x_issue_req_i.id);
        if (!killed_same_cyc) begin
          shift_entry_t ne;
          ne           = '0;
          ne.valid     = 1'b1;
          ne.instr     = x_issue_req_i.instr;
          ne.id        = x_issue_req_i.id;
          ne.rs_mask   = (req_enc == ENC_MOPCNT) ? 3'b111 : 3'b000;
          ne.committed = com_fire && !x_commit_i.commit_kill && (x_commit_i.id == x_issue_req_i.id);
          if ((req_enc != ENC_MOPCNT) && reg_fire && !matched_reg &&
              ((XifIssueRegisterSplit == 0) || (x_register_i.id == x_issue_req_i.id))) begin
            for (int unsigned b = 0; b < 3; b++) begin
              if (rmask[b]) begin
                ne.rs[b]      = x_register_i.rs[b];
                ne.rs_mask[b] = 1'b1;
              end
            end
          end
          q_nxt[h][wr_pos] = ne;
          wr_pos           = wr_pos + 1'b1;
        end
      end

      q_occ_nxt[h] = wr_pos;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        q_cur[h]       <= '0;
        q_occ_cur[h]   <= '0;
        hart_cfg_q[h]  <= '0;
        issue_tag_q[h] <= '0;
        done_tag_q[h]  <= '1;
      end else if (clear_i) begin
        q_cur[h]       <= '0;
        q_occ_cur[h]   <= '0;
        hart_cfg_q[h]  <= '0;
        issue_tag_q[h] <= '0;
        done_tag_q[h]  <= '1;
      end else begin
        q_cur[h]      <= q_nxt[h];
        q_occ_cur[h]  <= q_occ_nxt[h];
        hart_cfg_q[h] <= hart_cfg_d[h];
        if (do_marith && (32'(sel_hart) == h)) begin
          issue_tag_q[h] <= issue_tag_q[h] + 1'b1;
        end
        if (op_done_i && !trk_empty && (32'(trk_mem_q[trk_rptr_q]) == h)) begin
          done_tag_q[h] <= done_tag_q[h] + 1'b1;
        end
      end
    end
  end

endmodule : redmule_inst_decoder
