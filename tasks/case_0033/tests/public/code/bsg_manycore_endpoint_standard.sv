`include "bsg_manycore_defines.svh"

module bsg_manycore_endpoint_standard 
  import bsg_manycore_pkg::*; 
  #(`BSG_INV_PARAM(x_cord_width_p          )
    , `BSG_INV_PARAM(y_cord_width_p         )
    , `BSG_INV_PARAM(fifo_els_p             )
    , `BSG_INV_PARAM(data_width_p           )
    , `BSG_INV_PARAM(addr_width_p           )
    , `BSG_INV_PARAM(icache_block_size_in_words_p)
    , credit_counter_width_p = `BSG_WIDTH(32)
    , warn_out_of_credits_p  = 1
    , rev_fifo_els_p         = 3
    , localparam lg_rev_fifo_els_lp     = `BSG_WIDTH(rev_fifo_els_p)
    , parameter use_credits_for_local_fifo_p = 0
    , localparam packet_width_lp =
      `bsg_manycore_packet_width(addr_width_p,data_width_p,x_cord_width_p,y_cord_width_p)
    , return_packet_width_lp =
      `bsg_manycore_return_packet_width(x_cord_width_p,y_cord_width_p,data_width_p)
    , bsg_manycore_link_sif_width_lp =
      `bsg_manycore_link_sif_width(addr_width_p,data_width_p,x_cord_width_p,y_cord_width_p)
  )
  (
    input clk_i
    , input reset_i
    , input  [bsg_manycore_link_sif_width_lp-1:0] link_sif_i
    , output [bsg_manycore_link_sif_width_lp-1:0] link_sif_o

    , output logic                            in_v_o
    , output logic [data_width_p-1:0]         in_data_o
    , output logic [(data_width_p>>3)-1:0]    in_mask_o
    , output logic [addr_width_p-1:0]         in_addr_o
    , output logic                            in_we_o
    , output bsg_manycore_load_info_s         in_load_info_o
    , output logic [x_cord_width_p-1:0]       in_src_x_cord_o
    , output logic [y_cord_width_p-1:0]       in_src_y_cord_o
    , input                                   in_yumi_i

    , input [data_width_p-1:0]              returning_data_i
    , input                                 returning_v_i

    , input                                  out_v_i
    , input  [packet_width_lp-1:0]           out_packet_i
    , output                                 out_credit_or_ready_o

    , output [data_width_p-1:0]                 returned_data_r_o
    , output [bsg_manycore_reg_id_width_gp-1:0] returned_reg_id_r_o
    , output                                    returned_v_r_o
    , output bsg_manycore_return_packet_type_e  returned_pkt_type_r_o
    , input                                     returned_yumi_i
    , output                                    returned_fifo_full_o

    , output                                    returned_credit_v_r_o
    , output [bsg_manycore_reg_id_width_gp-1:0] returned_credit_reg_id_r_o
    , output [credit_counter_width_p-1:0]       out_credits_used_o

    , input   [x_cord_width_p-1:0] global_x_i
    , input   [y_cord_width_p-1:0] global_y_i
  );

  wire unused = |{global_x_i, global_y_i};

  `declare_bsg_manycore_packet_s(addr_width_p,data_width_p,x_cord_width_p,y_cord_width_p);

  bsg_manycore_packet_s packet_lo;
  logic packet_v_lo;
  logic packet_yumi_li;

  bsg_manycore_return_packet_s return_packet_li;
  logic return_packet_v_li;

  bsg_manycore_return_packet_s return_packet_lo;
  logic return_packet_v_lo;
  logic return_packet_yumi_li;

  bsg_manycore_endpoint_fc #(
    .x_cord_width_p(x_cord_width_p)
    ,.y_cord_width_p(y_cord_width_p)
    ,.fifo_els_p(fifo_els_p)
    ,.data_width_p(data_width_p)
    ,.addr_width_p(addr_width_p)
    ,.icache_block_size_in_words_p(icache_block_size_in_words_p)
    ,.credit_counter_width_p(credit_counter_width_p)
    ,.warn_out_of_credits_p(warn_out_of_credits_p)
    ,.rev_fifo_els_p(rev_fifo_els_p)
    ,.use_credits_for_local_fifo_p(use_credits_for_local_fifo_p)
  ) bme (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.link_sif_i(link_sif_i)
    ,.link_sif_o(link_sif_o)
    ,.packet_o(packet_lo)
    ,.packet_v_o(packet_v_lo)
    ,.packet_yumi_i(packet_yumi_li)
    ,.return_packet_i(return_packet_li)
    ,.return_packet_v_i(return_packet_v_li)
    ,.packet_i(out_packet_i)
    ,.packet_v_i(out_v_i)
    ,.packet_credit_or_ready_o(out_credit_or_ready_o)
    ,.return_packet_o(return_packet_lo)
    ,.return_packet_v_o(return_packet_v_lo)
    ,.return_packet_fifo_full_o(returned_fifo_full_o)
    ,.return_packet_yumi_i(return_packet_yumi_li)
    ,.out_credits_used_o(out_credits_used_o)
  );

  logic lock_r, lock_n;
  logic lock_v_r, lock_v_n;
  logic lock_return_r;

  always_ff @ (posedge clk_i) begin
    if (reset_i) begin
      lock_r <= 1'b0;
      lock_v_r <= 1'b0;
      lock_return_r <= 1'b0;
    end
    else begin
      lock_r <= lock_n;
      lock_v_r <= lock_v_n;
      lock_return_r <= lock_r;
    end
  end

  wire [bsg_manycore_reg_id_width_gp-1:0] payload_reg_id;
  bsg_manycore_reg_id_decode pd0 (
    .data_i(packet_lo.payload)
    ,.mask_i(packet_lo.reg_id.store_mask_s.mask)
    ,.reg_id_o(payload_reg_id)
  );

  logic [bsg_manycore_reg_id_width_gp-1:0] return_reg_id;
  bsg_manycore_return_packet_type_e return_pkt_type;

  always_comb begin
    in_v_o    = 1'b0;
    in_we_o   = 1'b0;
    in_data_o = packet_lo.payload;
    in_mask_o = 4'b1111;
    in_addr_o = packet_lo.addr;
    in_load_info_o = packet_lo.payload.load_info_s.load_info;
    in_src_x_cord_o = packet_lo.src_x_cord;
    in_src_y_cord_o = packet_lo.src_y_cord;
    packet_yumi_li = 1'b0;

    lock_n = lock_r;
    lock_v_n = 1'b0;

    return_reg_id = packet_lo.reg_id;
    return_pkt_type = e_return_credit;

    case (packet_lo.op_v2)
      e_remote_load: begin
        in_v_o = packet_v_lo;
        packet_yumi_li = in_yumi_i;
        return_pkt_type = packet_lo.payload.load_info_s.load_info.float_wb
          ? e_return_float_wb
          : e_return_int_wb;
      end

      e_remote_sw: begin
        in_v_o = packet_v_lo;
        in_we_o = 1'b1;
        in_mask_o = 4'b1111;
        packet_yumi_li = in_yumi_i;
        return_pkt_type = e_return_credit;
      end

      e_remote_store: begin
        in_v_o = packet_v_lo;
        in_we_o = 1'b1;
        in_mask_o = packet_lo.reg_id.store_mask_s.mask;
        packet_yumi_li = in_yumi_i;
        return_pkt_type = e_return_credit;
        return_reg_id = payload_reg_id;
      end

      e_remote_amoswap: begin
        packet_yumi_li = packet_v_lo;
        lock_v_n = packet_v_lo;
        lock_n = packet_v_lo
          ? packet_lo.payload[0]
          : lock_r;
        return_pkt_type = e_return_int_wb;
      end

      default: begin
      end
    endcase
  end

  typedef struct packed {
    logic [y_cord_width_p-1:0] y_cord;
    logic [x_cord_width_p-1:0] x_cord;
    logic [bsg_manycore_reg_id_width_gp-1:0] reg_id;
    bsg_manycore_return_packet_type_e pkt_type;
  } return_info_s;

  return_info_s return_info_r;

  always_ff @ (posedge clk_i) begin
    if (packet_v_lo & packet_yumi_li) begin
      return_info_r <= '{
        x_cord : packet_lo.src_x_cord,
        y_cord : packet_lo.src_y_cord,
        reg_id : return_reg_id,
        pkt_type : return_pkt_type
      };
    end
  end

  assign return_packet_v_li = lock_v_r | returning_v_i;

  assign return_packet_li = '{
    pkt_type  : return_info_r.pkt_type,
    data      : lock_v_r
                ? (data_width_p)'(lock_return_r)
                : returning_data_i,
    y_cord    : return_info_r.y_cord,
    x_cord    : return_info_r.x_cord,
    reg_id    : return_info_r.reg_id
  };

  assign returned_data_r_o     = return_packet_lo.data;
  assign returned_reg_id_r_o   = return_packet_lo.reg_id;
  assign returned_pkt_type_r_o = return_packet_lo.pkt_type;
  assign returned_v_r_o        = return_packet_v_lo & (return_packet_lo.pkt_type != e_return_credit);
  assign return_packet_yumi_li = returned_yumi_i | (return_packet_v_lo & (return_packet_lo.pkt_type == e_return_credit));

  wire returned_credit              = return_packet_v_lo & return_packet_yumi_li;
  assign returned_credit_v_r_o      = returned_credit;
  assign returned_credit_reg_id_r_o = return_packet_lo.reg_id;

endmodule
