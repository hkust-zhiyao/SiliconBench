`include "prim_assert.sv"

module prim_packer #(
  parameter int unsigned InW  = 32,
  parameter int unsigned OutW = 32,
  parameter int HintByteData = 0,
  parameter bit EnProtection = 1'b0
) (
  input clk_i ,
  input rst_ni,

  input                   valid_i,
  input        [InW-1:0]  data_i,
  input        [InW-1:0]  mask_i,
  output                  ready_o,

  output logic            valid_o,
  output logic [OutW-1:0] data_o,
  output logic [OutW-1:0] mask_o,
  input                   ready_i,

  input                   flush_i,
  output logic            flush_done_o,

  output logic            err_o
);

  localparam int unsigned InB     = InW / 8;
  localparam int unsigned OutB    = OutW / 8;
  localparam int unsigned WidthB  = InB + OutB;
  localparam int unsigned ConcatB = WidthB + InB;
  localparam int unsigned PtrBW   = $clog2(ConcatB+1);
  localparam int unsigned IdxBW   = prim_util_pkg::vbits(InB);
  localparam int unsigned OnesBW  = $clog2(InB+1);

  logic [InB-1:0] in_bmask;
  logic [InW-1:0] in_data_masked;
  for (genvar i = 0; i < InB; i++) begin : g_in_bmask
    assign in_bmask[i] = mask_i[8*i];
    assign in_data_masked[8*i +: 8] = (valid_i && in_bmask[i]) ? data_i[8*i +: 8] : 8'h00;
  end

  logic [OnesBW-1:0] inmask_bytes;
  logic [IdxBW-1:0]  lod_bidx;
  always_comb begin
    inmask_bytes = '0;
    lod_bidx = '0;
    for (int i = 0; i < InB; i++) begin
      inmask_bytes = inmask_bytes + OnesBW'(in_bmask[i]);
    end
    for (int i = 0; i < InB; i++) begin
      if (in_bmask[i] && (lod_bidx == '0) && !in_bmask[0]) lod_bidx = IdxBW'(unsigned'(i));
    end
  end

  logic [PtrBW-1:0] pos_b_q, pos_b_d;
  wire  [PtrBW-1:0] pos_b_with_in = pos_b_q + PtrBW'(inmask_bytes);

  logic ack_in, ack_out;
  logic flush_valid, flush_done;

  always_comb begin
    unique case ({ack_in, ack_out})
      2'b00: pos_b_d = pos_b_q;
      2'b01: pos_b_d = (int'(pos_b_q) <= OutB) ? '0 : pos_b_q - PtrBW'(OutB);
      2'b10: pos_b_d = pos_b_with_in;
      2'b11: pos_b_d = (int'(pos_b_with_in) <= OutB) ? '0 : pos_b_with_in - PtrBW'(OutB);
      default: pos_b_d = pos_b_q;
    endcase
  end

  logic cnt_err;
  if (EnProtection == 1'b0) begin : g_pos_nodup
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        pos_b_q <= '0;
      end else if (flush_done) begin
        pos_b_q <= '0;
      end else begin
        pos_b_q <= pos_b_d;
      end
    end
    assign cnt_err = 1'b0;
  end else begin : g_pos_dupcnt
    logic             cnt_incr_en, cnt_decr_en, cnt_set_en;
    logic [PtrBW-1:0] cnt_step, cnt_set;
    assign cnt_incr_en =  ack_in && !ack_out;
    assign cnt_decr_en = !ack_in &&  ack_out;
    assign cnt_set_en  =  ack_in &&  ack_out;
    assign cnt_step    = cnt_incr_en ? PtrBW'(inmask_bytes) : PtrBW'(OutB);
    assign cnt_set     = (pos_b_with_in > PtrBW'(OutB)) ? (pos_b_with_in - PtrBW'(OutB)) : '0;

    prim_count #(
      .Width      (PtrBW),
      .ResetValue ('0)
    ) u_pos (
      .clk_i,
      .rst_ni,
      .clr_i              (flush_done),
      .set_i              (cnt_set_en),
      .set_cnt_i          (cnt_set),
      .incr_en_i          (cnt_incr_en),
      .decr_en_i          (cnt_decr_en),
      .step_i             (cnt_step),
      .commit_i           (1'b1),
      .cnt_o              (pos_b_q),
      .cnt_after_commit_o (),
      .err_o              (cnt_err)
    );
  end

  assign err_o = cnt_err;

  logic [WidthB*8-1:0] stored_data_q, stored_data_d;
  logic [WidthB-1:0]   stored_bmask_q, stored_bmask_d;

  logic [InW-1:0]       shiftr_data;
  logic [InB-1:0]       shiftr_bmask;
  logic [ConcatB*8-1:0] shiftl_data, concat_data;
  logic [ConcatB-1:0]   shiftl_bmask, concat_bmask;

  assign shiftr_data  = in_data_masked >> {lod_bidx, 3'b000};
  assign shiftr_bmask = valid_i ? (in_bmask >> lod_bidx) : '0;

  wire [PtrBW-1:0] eff_pos_b = (ack_out && (int'(pos_b_q) >= OutB)) ? (pos_b_q - PtrBW'(OutB)) : pos_b_q;
  assign shiftl_data  = (ConcatB*8)'(shiftr_data) << {eff_pos_b, 3'b000};
  assign shiftl_bmask = ConcatB'(shiftr_bmask) << eff_pos_b;

  assign concat_data  = {{InW{1'b0}}, stored_data_q} | shiftl_data;
  assign concat_bmask = {{InB{1'b0}}, stored_bmask_q} | shiftl_bmask;

  always_comb begin
    unique case ({ack_in, ack_out})
      2'b00: begin
        stored_data_d  = stored_data_q;
        stored_bmask_d = stored_bmask_q;
      end
      2'b01: begin
        stored_data_d  = {{OutW{1'b0}}, stored_data_q[WidthB*8-1:OutW]};
        stored_bmask_d = {{OutB{1'b0}}, stored_bmask_q[WidthB-1:OutB]};
      end
      2'b10: begin
        stored_data_d  = concat_data[0 +: WidthB*8];
        stored_bmask_d = concat_bmask[0 +: WidthB];
      end
      2'b11: begin
        stored_data_d  = ({{OutW{1'b0}}, stored_data_q[WidthB*8-1:OutW]} | shiftl_data[0 +: WidthB*8]);
        stored_bmask_d = ({{OutB{1'b0}}, stored_bmask_q[WidthB-1:OutB]} | shiftl_bmask[0 +: WidthB]);
      end
      default: begin
        stored_data_d  = stored_data_q;
        stored_bmask_d = stored_bmask_q;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stored_data_q  <= '0;
      stored_bmask_q <= '0;
    end else if (flush_done) begin
      stored_data_q  <= '0;
      stored_bmask_q <= '0;
    end else begin
      stored_data_q  <= stored_data_d;
      stored_bmask_q <= stored_bmask_d;
    end
  end

  typedef enum logic {
    FlushIdle,
    FlushSend
  } flush_st_e;
  flush_st_e flush_st, flush_st_next;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      flush_st <= FlushIdle;
    end else begin
      flush_st <= flush_st_next;
    end
  end

  always_comb begin
    flush_st_next = FlushIdle;
    flush_valid   = 1'b0;
    flush_done    = 1'b0;
    unique case (flush_st)
      FlushIdle: begin
        if (flush_i) flush_st_next = FlushSend;
      end
      FlushSend: begin
        if (pos_b_q == '0) begin
          flush_st_next = FlushIdle;
          flush_done    = 1'b1;
        end else begin
          flush_st_next = FlushSend;
          flush_valid   = 1'b1;
        end
      end
      default: flush_st_next = FlushIdle;
    endcase
  end

  assign flush_done_o = flush_done;
  assign valid_o = (int'(pos_b_q) >= OutB) ? 1'b1 : flush_valid;
  assign ready_o = (flush_st == FlushIdle) && !flush_i && (int'(pos_b_q) <= OutB);
  assign data_o  = stored_data_q[OutW-1:0];
  for (genvar i = 0; i < OutB; i++) begin : g_out_mask
    assign mask_o[8*i +: 8] = {8{stored_bmask_q[i]}};
  end
  assign ack_in  = valid_i & ready_o;
  assign ack_out = valid_o & ready_i;

endmodule
