// Copyright 2018 ETH Zurich and University of Bologna.
// Licensed under the Solderpad Hardware License, Version 0.51.

module axi_shim #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned AxiNumWords = 4,
    parameter type axi_req_t = logic,
    parameter type axi_rsp_t = logic,
    parameter int unsigned AxiBlenWidth = AxiNumWords > 1 ? $clog2(AxiNumWords) : 1
) (
    input  logic                                                  clk_i,
    input  logic                                                  rst_ni,
    input  logic                                                  rd_req_i,
    output logic                                                  rd_gnt_o,
    input  logic [CVA6Cfg.AxiAddrWidth-1:0]                       rd_addr_i,
    input  logic [AxiBlenWidth-1:0]                               rd_blen_i,
    input  logic [2:0]                                            rd_size_i,
    input  logic [CVA6Cfg.AxiIdWidth-1:0]                         rd_id_i,
    input  logic                                                  rd_lock_i,
    input  logic                                                  rd_rdy_i,
    output logic                                                  rd_last_o,
    output logic                                                  rd_valid_o,
    output logic [CVA6Cfg.AxiDataWidth-1:0]                       rd_data_o,
    output logic [CVA6Cfg.AxiUserWidth-1:0]                       rd_user_o,
    output logic [CVA6Cfg.AxiIdWidth-1:0]                         rd_id_o,
    output logic                                                  rd_exokay_o,
    input  logic                                                  wr_req_i,
    output logic                                                  wr_gnt_o,
    input  logic [CVA6Cfg.AxiAddrWidth-1:0]                       wr_addr_i,
    input  logic [AxiNumWords-1:0][CVA6Cfg.AxiDataWidth-1:0]      wr_data_i,
    input  logic [AxiNumWords-1:0][CVA6Cfg.AxiUserWidth-1:0]      wr_user_i,
    input  logic [AxiNumWords-1:0][(CVA6Cfg.AxiDataWidth/8)-1:0]  wr_be_i,
    input  logic [AxiBlenWidth-1:0]                               wr_blen_i,
    input  logic [2:0]                                            wr_size_i,
    input  logic [CVA6Cfg.AxiIdWidth-1:0]                         wr_id_i,
    input  logic                                                  wr_lock_i,
    input  logic [5:0]                                            wr_atop_i,
    input  logic                                                  wr_rdy_i,
    output logic                                                  wr_valid_o,
    output logic [CVA6Cfg.AxiIdWidth-1:0]                         wr_id_o,
    output logic                                                  wr_exokay_o,
    output axi_req_t                                              axi_req_o,
    input  axi_rsp_t                                              axi_resp_i
);

  typedef enum logic [1:0] {
    IDLE,
    WRITE,
    WRITE_WAIT,
    AW_WAIT
  } wr_state_e;

  typedef enum logic {
    READ,
    READ_HOLD
  } rd_state_e;

  wr_state_e wr_State_d, wr_State_q;
  rd_state_e rd_State_d, rd_State_q;

  logic [AxiBlenWidth-1:0] wr_cnt_d, wr_cnt_q;
  logic [AxiBlenWidth-1:0] wr_ptr;
  logic [$bits(axi_req_o.aw)-1:0] wr_aw_d, wr_aw_q;
  logic [$bits(axi_req_o.w)-1:0]  wr_w_d, wr_w_q;
  logic [$bits(axi_req_o.ar)-1:0] rd_ar_d, rd_ar_q;

  assign wr_cnt_d = (wr_State_q == IDLE) ? wr_blen_i :
                    (axi_req_o.w_valid && axi_resp_i.w_ready) ? (wr_cnt_q - 1'b1) : wr_cnt_q;
  assign wr_ptr   = wr_blen_i - wr_cnt_q;

  assign axi_req_o.b_ready = wr_rdy_i;
  assign wr_valid_o        = axi_resp_i.b_valid;
  assign wr_id_o           = axi_resp_i.b.id;
  assign wr_exokay_o       = (axi_resp_i.b.resp == axi_pkg::RESP_EXOKAY);

  assign axi_req_o.r_ready = rd_rdy_i;
  assign rd_valid_o        = axi_resp_i.r_valid;
  assign rd_last_o         = axi_resp_i.r.last;
  assign rd_data_o         = axi_resp_i.r.data;
  assign rd_user_o         = axi_resp_i.r.user;
  assign rd_id_o           = axi_resp_i.r.id;
  assign rd_exokay_o       = (axi_resp_i.r.resp == axi_pkg::RESP_EXOKAY);

  always_comb begin : p_write_fsm
    wr_State_d         = wr_State_q;
    wr_aw_d            = wr_aw_q;
    wr_w_d             = wr_w_q;
    wr_gnt_o           = 1'b0;
    axi_req_o.aw_valid = 1'b0;
    axi_req_o.w_valid  = 1'b0;

    axi_req_o.aw       = '0;
    axi_req_o.aw.id    = wr_id_i;
    axi_req_o.aw.addr  = wr_addr_i;
    axi_req_o.aw.len   = 8'(wr_blen_i);
    axi_req_o.aw.size  = wr_size_i;
    axi_req_o.aw.burst = axi_pkg::BURST_INCR;
    axi_req_o.aw.lock  = wr_lock_i;
    axi_req_o.aw.atop  = wr_atop_i;

    axi_req_o.w        = '0;
    axi_req_o.w.data   = wr_data_i[0];
    axi_req_o.w.user   = wr_user_i[0];
    axi_req_o.w.strb   = wr_be_i[0];
    axi_req_o.w.last   = (wr_cnt_d == '0);

    unique case (wr_State_q)
      IDLE: begin
        wr_aw_d            = axi_req_o.aw;
        wr_w_d             = axi_req_o.w;
        axi_req_o.aw_valid = wr_req_i;
        axi_req_o.w_valid  = wr_req_i;
        if (wr_req_i) begin
          unique case ({axi_resp_i.aw_ready, axi_resp_i.w_ready})
            2'b01: begin
              if (wr_blen_i == '0) begin
                wr_State_d = AW_WAIT;
              end else begin
                wr_State_d = WRITE;
              end
            end
            2'b10: begin
              wr_State_d = WRITE_WAIT;
            end
            2'b11: begin
              if (wr_blen_i == '0) begin
                wr_gnt_o = 1'b1;
              end else begin
                wr_State_d = WRITE_WAIT;
              end
            end
            default: ;
          endcase
        end
      end

      WRITE: begin
        axi_req_o.aw       = wr_aw_q;
        axi_req_o.aw_valid = 1'b1;
        axi_req_o.w.data   = wr_data_i[wr_ptr];
        axi_req_o.w.user   = wr_user_i[wr_ptr];
        axi_req_o.w.strb   = wr_be_i[wr_ptr];
        axi_req_o.w.last   = (wr_cnt_q == '0);
        axi_req_o.w_valid  = 1'b1;
        unique case ({axi_resp_i.aw_ready, axi_resp_i.w_ready})
          2'b01: begin
            if (wr_cnt_q == '0) begin
              wr_State_d = AW_WAIT;
            end
          end
          2'b10: begin
            wr_State_d = WRITE_WAIT;
          end
          2'b11: begin
            if (wr_cnt_q == '0) begin
              wr_gnt_o   = 1'b1;
              wr_State_d = IDLE;
            end else begin
              wr_State_d = WRITE_WAIT;
            end
          end
          default: ;
        endcase
      end

      WRITE_WAIT: begin
        axi_req_o.aw       = wr_aw_q;
        axi_req_o.w.data   = wr_data_i[wr_ptr];
        axi_req_o.w.user   = wr_user_i[wr_ptr];
        axi_req_o.w.strb   = wr_be_i[wr_ptr];
        axi_req_o.w.last   = (wr_cnt_q == '0);
        axi_req_o.w_valid  = 1'b1;
        if (axi_resp_i.w_ready) begin
          if (wr_cnt_q == '0) begin
            wr_gnt_o   = 1'b1;
            wr_State_d = IDLE;
          end
        end
      end

      AW_WAIT: begin
        axi_req_o.aw       = wr_aw_q;
        axi_req_o.aw_valid = 1'b1;
        if (axi_resp_i.aw_ready) begin
          wr_gnt_o   = 1'b1;
          wr_State_d = IDLE;
        end
      end

      default: wr_State_d = IDLE;
    endcase
  end

  always_comb begin : p_read_fsm
    rd_State_d        = rd_State_q;
    rd_ar_d           = rd_ar_q;
    rd_gnt_o          = 1'b0;
    axi_req_o.ar      = '0;
    axi_req_o.ar.id   = rd_id_i;
    axi_req_o.ar.addr = rd_addr_i;
    axi_req_o.ar.len  = 8'(rd_blen_i);
    axi_req_o.ar.size = rd_size_i;
    axi_req_o.ar.burst= axi_pkg::BURST_INCR;
    axi_req_o.ar.lock = rd_lock_i;

    unique case (rd_State_q)
      READ: begin
        rd_ar_d            = axi_req_o.ar;
        axi_req_o.ar_valid = rd_req_i;
        if (rd_req_i) begin
          if (axi_resp_i.ar_ready) begin
            rd_gnt_o = 1'b1;
          end else begin
            rd_State_d = READ_HOLD;
          end
        end
      end
      READ_HOLD: begin
        axi_req_o.ar       = rd_ar_q;
        axi_req_o.ar_valid = 1'b1;
        if (axi_resp_i.ar_ready) begin
          rd_gnt_o   = 1'b1;
          rd_State_d = READ;
        end
      end
      default: rd_State_d = READ;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      wr_State_q <= IDLE;
      rd_State_q <= READ;
      wr_cnt_q   <= '0;
      wr_aw_q    <= '0;
      wr_w_q     <= '0;
      rd_ar_q    <= '0;
    end else begin
      wr_State_q <= wr_State_d;
      rd_State_q <= rd_State_d;
      wr_cnt_q   <= wr_cnt_d;
      wr_aw_q <= wr_aw_d;
      wr_w_q  <= wr_w_d;
      rd_ar_q <= rd_ar_d;
    end
  end
endmodule
