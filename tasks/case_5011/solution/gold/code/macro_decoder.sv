// Copyright 2018 ETH Zurich and University of Bologna.
// Licensed under the Solderpad Hardware License, Version 0.51.

module macro_decoder #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    input  logic [31:0] instr_i,
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        is_macro_instr_i,
    input  logic        illegal_instr_i,
    input  logic        is_compressed_i,
    input  logic        issue_ack_i,
    output logic [31:0] instr_o,
    output logic        illegal_instr_o,
    output logic        is_compressed_o,
    output logic        fetch_stall_o,
    output logic        is_last_macro_instr_o,
    output logic        is_double_rd_macro_instr_o
);

  typedef enum logic [2:0] {
    IDLE,
    INIT,
    PUSH_ADDI,
    POPRETZ_1,
    MOVE,
    PUSH_POP_INSTR_2
  } state_e;

  typedef enum logic [2:0] {
    PUSH,
    POP,
    POPRETZ,
    POPRET,
    MVA01S,
    MVSA01
  } macro_type_e;

  state_e      state_d, state_q;
  macro_type_e macro_instr_type, macro_type_d, macro_type_q;

  logic [ 3:0] reg_numbers, reg_numbers_m1, reg_numbers_q, reg_numbers_d;
  logic [ 4:0] xreg1, xreg2, xreg2_d, xreg2_q;
  logic [ 4:0] store_reg, store_reg_init_next, store_reg_q, store_reg_d;
  logic [ 1:0] popretz_inst_q, popretz_inst_d;
  logic [11:0] stack_adj, push_sp_imm, sp_imm_d, sp_imm_q;
  logic [11:0] pop_off_first, pop_off_second;
  logic [11:0] offset_q, offset_d;
  logic [31:0] instr_o_reg;

  assign instr_o = instr_o_reg;

  always_comb begin
    illegal_instr_o            = 1'b0;
    fetch_stall_o              = 1'b0;
    is_last_macro_instr_o      = 1'b0;
    is_double_rd_macro_instr_o = 1'b0;
    is_compressed_o            = is_macro_instr_i ? 1'b1 : is_compressed_i;
    macro_instr_type           = PUSH;
    reg_numbers                = '0;
    reg_numbers_m1             = '0;
    xreg1                      = '0;
    xreg2                      = '0;
    store_reg                  = '0;
    store_reg_init_next        = '0;
    stack_adj                  = '0;
    push_sp_imm                = '0;
    pop_off_first              = '0;
    sp_imm_d                   = sp_imm_q;
    pop_off_second             = '0;
    instr_o_reg                = instr_i;

    state_d                    = state_q;
    macro_type_d               = macro_type_q;
    xreg2_d                    = xreg2_q;
    offset_d                   = offset_q;
    reg_numbers_d              = reg_numbers_q;
    store_reg_d                = store_reg_q;
    popretz_inst_d             = popretz_inst_q;

    if (is_macro_instr_i) begin
      unique case (instr_i[12:10])
        3'b110: begin
          if (instr_i[7:4] < 4'b0100) illegal_instr_o = 1'b1;
          unique case (instr_i[9:8])
            2'b00: macro_instr_type = PUSH;
            2'b10: macro_instr_type = POP;
            default: illegal_instr_o = 1'b1;
          endcase
        end
        3'b111: begin
          if (instr_i[7:4] < 4'b0100) illegal_instr_o = 1'b1;
          unique case (instr_i[9:8])
            2'b00: macro_instr_type = POPRETZ;
            2'b10: macro_instr_type = POPRET;
            default: illegal_instr_o = 1'b1;
          endcase
        end
        3'b011: begin
          unique case (instr_i[6:5])
            2'b01: begin
              macro_instr_type = MVSA01;
              if (instr_i[9:7] == instr_i[4:2]) illegal_instr_o = 1'b1;
            end
            2'b11: macro_instr_type = MVA01S;
            default: illegal_instr_o = 1'b1;
          endcase
        end
        default: illegal_instr_o = 1'b1;
      endcase

      xreg1 = {|instr_i[9:8], ~|instr_i[9:8], instr_i[9:7]};
      xreg2 = {|instr_i[4:3], ~|instr_i[4:3], instr_i[4:2]};

      unique case (instr_i[7:4])
        4'b0100: begin reg_numbers = 4'd1;  reg_numbers_m1 = 4'd0;  store_reg = 5'd1;  store_reg_init_next = 5'd1;  end
        4'b0101: begin reg_numbers = 4'd2;  reg_numbers_m1 = 4'd1;  store_reg = 5'd8;  store_reg_init_next = 5'd1;  end
        4'b0110: begin reg_numbers = 4'd3;  reg_numbers_m1 = 4'd2;  store_reg = 5'd9;  store_reg_init_next = 5'd8;  end
        4'b0111: begin reg_numbers = 4'd4;  reg_numbers_m1 = 4'd3;  store_reg = 5'd18; store_reg_init_next = 5'd17; end
        4'b1000: begin reg_numbers = 4'd5;  reg_numbers_m1 = 4'd4;  store_reg = 5'd19; store_reg_init_next = 5'd18; end
        4'b1001: begin reg_numbers = 4'd6;  reg_numbers_m1 = 4'd5;  store_reg = 5'd20; store_reg_init_next = 5'd19; end
        4'b1010: begin reg_numbers = 4'd7;  reg_numbers_m1 = 4'd6;  store_reg = 5'd21; store_reg_init_next = 5'd20; end
        4'b1011: begin reg_numbers = 4'd8;  reg_numbers_m1 = 4'd7;  store_reg = 5'd22; store_reg_init_next = 5'd21; end
        4'b1100: begin reg_numbers = 4'd9;  reg_numbers_m1 = 4'd8;  store_reg = 5'd23; store_reg_init_next = 5'd22; end
        4'b1101: begin reg_numbers = 4'd10; reg_numbers_m1 = 4'd9;  store_reg = 5'd24; store_reg_init_next = 5'd23; end
        4'b1110: begin reg_numbers = 4'd11; reg_numbers_m1 = 4'd10; store_reg = 5'd25; store_reg_init_next = 5'd24; end
        4'b1111: begin reg_numbers = 4'd12; reg_numbers_m1 = 4'd11; store_reg = 5'd27; store_reg_init_next = 5'd26; end
        default: begin reg_numbers = 4'd0;  reg_numbers_m1 = 4'd0;  store_reg = 5'd0;  store_reg_init_next = 5'd0;  end
      endcase

      unique case (instr_i[7:4])
        4'b0100, 4'b0101, 4'b0110, 4'b0111: begin
          unique case (instr_i[3:2])
            2'b00: begin stack_adj = 12'd16;  push_sp_imm = 12'hFF0; pop_off_first = 12'd12;  pop_off_second = 12'd8;   end
            2'b01: begin stack_adj = 12'd32;  push_sp_imm = 12'hFE0; pop_off_first = 12'd28;  pop_off_second = 12'd24;  end
            2'b10: begin stack_adj = 12'd48;  push_sp_imm = 12'hFD0; pop_off_first = 12'd44;  pop_off_second = 12'd40;  end
            2'b11: begin stack_adj = 12'd64;  push_sp_imm = 12'hFC0; pop_off_first = 12'd60;  pop_off_second = 12'd56;  end
          endcase
        end
        4'b1000, 4'b1001, 4'b1010, 4'b1011: begin
          unique case (instr_i[3:2])
            2'b00: begin stack_adj = 12'd32;  push_sp_imm = 12'hFE0; pop_off_first = 12'd28;  pop_off_second = 12'd24;  end
            2'b01: begin stack_adj = 12'd48;  push_sp_imm = 12'hFD0; pop_off_first = 12'd44;  pop_off_second = 12'd40;  end
            2'b10: begin stack_adj = 12'd64;  push_sp_imm = 12'hFC0; pop_off_first = 12'd60;  pop_off_second = 12'd56;  end
            2'b11: begin stack_adj = 12'd80;  push_sp_imm = 12'hFB0; pop_off_first = 12'd76;  pop_off_second = 12'd72;  end
          endcase
        end
        4'b1100, 4'b1101, 4'b1110: begin
          unique case (instr_i[3:2])
            2'b00: begin stack_adj = 12'd48;  push_sp_imm = 12'hFD0; pop_off_first = 12'd44;  pop_off_second = 12'd40;  end
            2'b01: begin stack_adj = 12'd64;  push_sp_imm = 12'hFC0; pop_off_first = 12'd60;  pop_off_second = 12'd56;  end
            2'b10: begin stack_adj = 12'd80;  push_sp_imm = 12'hFB0; pop_off_first = 12'd76;  pop_off_second = 12'd72;  end
            2'b11: begin stack_adj = 12'd96;  push_sp_imm = 12'hFA0; pop_off_first = 12'd92;  pop_off_second = 12'd88;  end
          endcase
        end
        4'b1111: begin
          unique case (instr_i[3:2])
            2'b00: begin stack_adj = 12'd64;  push_sp_imm = 12'hFC0; pop_off_first = 12'd60;  pop_off_second = 12'd56;  end
            2'b01: begin stack_adj = 12'd80;  push_sp_imm = 12'hFB0; pop_off_first = 12'd76;  pop_off_second = 12'd72;  end
            2'b10: begin stack_adj = 12'd96;  push_sp_imm = 12'hFA0; pop_off_first = 12'd92;  pop_off_second = 12'd88;  end
            2'b11: begin stack_adj = 12'd112; push_sp_imm = 12'hF90; pop_off_first = 12'd108; pop_off_second = 12'd104; end
          endcase
        end
        default: ;
      endcase
    end else begin
      illegal_instr_o = illegal_instr_i;
      instr_o_reg     = instr_i;
    end

    unique case (state_q)
      IDLE: begin
        if (is_macro_instr_i && !illegal_instr_o) begin
          macro_type_d  = macro_instr_type;
          xreg2_d       = xreg2;
          reg_numbers_d = reg_numbers_m1;
          store_reg_d   = store_reg_init_next;
          fetch_stall_o = 1'b1;

          unique case (macro_instr_type)
            MVSA01: begin
              is_double_rd_macro_instr_o = 1'b1;
              instr_o_reg = {12'h0, 5'hA, 3'h0, xreg1, riscv::OpcodeOpImm};
              if (issue_ack_i) state_d = MOVE;
            end
            MVA01S: begin
              is_double_rd_macro_instr_o = 1'b1;
              instr_o_reg = {12'h0, xreg1, 3'h0, 5'hA, riscv::OpcodeOpImm};
              if (issue_ack_i) state_d = MOVE;
            end
            PUSH: begin
              sp_imm_d    = push_sp_imm;
              offset_d    = 12'hFF8;
              instr_o_reg = {7'b1111111, store_reg, 5'h2, 3'h2, 5'b11100, riscv::OpcodeStore};
              if (issue_ack_i) begin
                if (reg_numbers == 4'd1) state_d = PUSH_ADDI;
                else if (reg_numbers == 4'd12) state_d = PUSH_POP_INSTR_2;
                else state_d = INIT;
              end
            end
            POP, POPRET, POPRETZ: begin
              sp_imm_d       = stack_adj;
              offset_d       = pop_off_second;
              popretz_inst_d = (macro_instr_type == POPRETZ) ? 2'b11 :
                               (macro_instr_type == POPRET)  ? 2'b01 : 2'b00;
              instr_o_reg    = {pop_off_first, 5'h2, 3'h2, store_reg, riscv::OpcodeLoad};
              if (issue_ack_i) begin
                if (reg_numbers == 4'd1) begin
                  state_d = (macro_instr_type == POPRETZ) ? POPRETZ_1 : PUSH_ADDI;
                end else if (reg_numbers == 4'd12) begin
                  state_d = PUSH_POP_INSTR_2;
                end else begin
                  state_d = INIT;
                end
              end
            end
            default: ;
          endcase
        end
      end

      INIT: begin
        fetch_stall_o = is_macro_instr_i;
        if (is_macro_instr_i) begin
          logic [4:0] cur_reg;
          unique case (reg_numbers_q)
            4'd1:    cur_reg = 5'h1;
            4'd2:    cur_reg = 5'h8;
            4'd3:    cur_reg = 5'h9;
            default: cur_reg = store_reg_q;
          endcase
          if (macro_type_q == PUSH) begin
            instr_o_reg = {offset_q[11:5], cur_reg, 5'h2, 3'h2, offset_q[4:0], riscv::OpcodeStore};
          end else begin
            instr_o_reg = {offset_q[11:0], 5'h2, 3'h2, cur_reg, riscv::OpcodeLoad};
          end
          if (issue_ack_i) begin
            if (reg_numbers_q == 4'd1) begin
              state_d = (macro_type_q == POPRETZ) ? POPRETZ_1 : PUSH_ADDI;
            end else begin
              reg_numbers_d = reg_numbers_q - 4'd1;
              offset_d      = offset_q + 12'hFFC;
              if (reg_numbers_q >= 4'd4) store_reg_d = store_reg_q - 5'd1;
            end
          end
        end
      end

      MOVE: begin
        is_last_macro_instr_o      = 1'b1;
        is_double_rd_macro_instr_o = 1'b1;
        fetch_stall_o              = ~issue_ack_i;
        if (macro_type_q == MVSA01) begin
          instr_o_reg = {12'h0, 5'hB, 3'h0, xreg2_q, riscv::OpcodeOpImm};
        end else begin
          instr_o_reg = {12'h0, xreg2_q, 3'h0, 5'hB, riscv::OpcodeOpImm};
        end
        if (issue_ack_i) state_d = IDLE;
      end

      PUSH_ADDI: begin
        instr_o_reg = {sp_imm_q, 5'h2, 3'h0, 5'h2, riscv::OpcodeOpImm};
        if (macro_type_q == POPRETZ || macro_type_q == POPRET) begin
          fetch_stall_o = 1'b1;
          if (issue_ack_i) state_d = POPRETZ_1;
        end else begin
          is_last_macro_instr_o = 1'b1;
          fetch_stall_o         = ~issue_ack_i;
          if (issue_ack_i) state_d = IDLE;
        end
      end

      PUSH_POP_INSTR_2: begin
        fetch_stall_o = 1'b1;
        if (macro_type_q == PUSH) begin
          instr_o_reg = {offset_q[11:5], store_reg_q, 5'h2, 3'h2, offset_q[4:0], riscv::OpcodeStore};
        end else begin
          instr_o_reg = {offset_q[11:0], 5'h2, 3'h2, store_reg_q, riscv::OpcodeLoad};
        end
        if (issue_ack_i) begin
          offset_d    = offset_q + 12'hFFC;
          store_reg_d = store_reg_q - 5'd1;
          state_d     = INIT;
        end
      end

      POPRETZ_1: begin
        unique case (popretz_inst_q)
          2'b11: begin
            instr_o_reg   = {20'h0, 5'hA, riscv::OpcodeLui};
            fetch_stall_o = 1'b1;
            if (issue_ack_i) popretz_inst_d = 2'b10;
          end
          2'b10: begin
            instr_o_reg   = {12'h0, 5'hA, 3'h0, 5'hA, riscv::OpcodeOpImm};
            fetch_stall_o = 1'b1;
            if (issue_ack_i) begin
              popretz_inst_d = 2'b01;
              state_d        = PUSH_ADDI;
            end
          end
          2'b01: begin
            instr_o_reg           = {12'h0, 5'h1, 3'h0, 5'h0, riscv::OpcodeJalr};
            is_last_macro_instr_o = 1'b1;
            fetch_stall_o         = ~issue_ack_i;
            if (issue_ack_i) begin
              popretz_inst_d = 2'b00;
              state_d        = IDLE;
            end
          end
          default: begin
            illegal_instr_o = 1'b1;
            instr_o_reg     = instr_i;
          end
        endcase
      end

      default: state_d = IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      state_q        <= IDLE;
      macro_type_q   <= PUSH;
      xreg2_q        <= '0;
      sp_imm_q       <= '0;
      offset_q       <= '0;
      popretz_inst_q <= '0;
      reg_numbers_q  <= '0;
      store_reg_q    <= '0;
    end else if (!is_macro_instr_i) begin
      state_q        <= IDLE;
      macro_type_q   <= PUSH;
      xreg2_q        <= '0;
      sp_imm_q       <= '0;
      offset_q       <= '0;
      popretz_inst_q <= '0;
      reg_numbers_q  <= '0;
      store_reg_q    <= '0;
    end else begin
      state_q        <= state_d;
      macro_type_q   <= macro_type_d;
      xreg2_q        <= xreg2_d;
      sp_imm_q       <= sp_imm_d;
      offset_q       <= offset_d;
      reg_numbers_q  <= reg_numbers_d;
      store_reg_q    <= store_reg_d;
      popretz_inst_q <= popretz_inst_d;
    end
  end
endmodule
