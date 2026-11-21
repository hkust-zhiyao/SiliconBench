`include "bsg_manycore_defines.svh"

module network_tx
  import bsg_manycore_pkg::*;
  import bsg_vanilla_pkg::*;
  #(`BSG_INV_PARAM(data_width_p)
    , `BSG_INV_PARAM(addr_width_p)
    , `BSG_INV_PARAM(x_cord_width_p)
    , `BSG_INV_PARAM(y_cord_width_p)
    , `BSG_INV_PARAM(pod_x_cord_width_p)
    , `BSG_INV_PARAM(pod_y_cord_width_p)
    , `BSG_INV_PARAM(vcache_size_p)
    , `BSG_INV_PARAM(vcache_block_size_in_words_p)
    , `BSG_INV_PARAM(vcache_sets_p)
    , `BSG_INV_PARAM(ipoly_hashing_p)
    , `BSG_INV_PARAM(num_tiles_x_p)
    , `BSG_INV_PARAM(num_tiles_y_p)
    , localparam x_subcord_width_lp=`BSG_SAFE_CLOG2(num_tiles_x_p)
    , y_subcord_width_lp=`BSG_SAFE_CLOG2(num_tiles_y_p)
    , parameter `BSG_INV_PARAM(icache_entries_p)
    , `BSG_INV_PARAM(icache_tag_width_p)
    , localparam vcache_addr_width_lp=`BSG_SAFE_CLOG2(vcache_size_p)
    , vcache_word_offset_width_lp = `BSG_SAFE_CLOG2(vcache_block_size_in_words_p)
    , icache_addr_width_lp=`BSG_SAFE_CLOG2(icache_entries_p)
    , pc_width_lp=(icache_tag_width_p+icache_addr_width_lp)
    , reg_addr_width_lp=RV32_reg_addr_width_gp
    , packet_width_lp=`bsg_manycore_packet_width(addr_width_p,data_width_p,x_cord_width_p,y_cord_width_p)
  )
  (
    input clk_i
    , input reset_i
    , input flush_i

    , output logic [packet_width_lp-1:0] out_packet_o
    , output logic out_v_o
    , input out_credit_or_ready_i

    , input returned_v_i
    , input [data_width_p-1:0] returned_data_i
    , input [bsg_manycore_reg_id_width_gp-1:0] returned_reg_id_i
    , input bsg_manycore_return_packet_type_e returned_pkt_type_i
    , input returned_fifo_full_i
    , output logic returned_yumi_o

    , input [x_subcord_width_lp-1:0] tgo_x_i
    , input [y_subcord_width_lp-1:0] tgo_y_i
    , input [x_subcord_width_lp-1:0] my_x_i
    , input [y_subcord_width_lp-1:0] my_y_i
    , input [pod_x_cord_width_p-1:0] pod_x_i
    , input [pod_y_cord_width_p-1:0] pod_y_i
    , input [pod_x_cord_width_p-1:0] cfg_pod_x_i
    , input [pod_y_cord_width_p-1:0] cfg_pod_y_i

    , input remote_req_s remote_req_i
    , input remote_req_v_i
    , output logic remote_req_credit_o

    , output logic ifetch_v_o
    , output logic [data_width_p-1:0] ifetch_instr_o

    , output logic [reg_addr_width_lp-1:0] float_remote_load_resp_rd_o
    , output logic [data_width_p-1:0] float_remote_load_resp_data_o
    , output logic float_remote_load_resp_v_o
    , output logic float_remote_load_resp_force_o
    , input float_remote_load_resp_yumi_i

    , output logic [reg_addr_width_lp-1:0] int_remote_load_resp_rd_o
    , output logic [data_width_p-1:0] int_remote_load_resp_data_o
    , output logic int_remote_load_resp_v_o
    , output logic int_remote_load_resp_force_o
    , input int_remote_load_resp_yumi_i

    , output logic invalid_eva_access_o
  );

  `declare_bsg_manycore_packet_s(addr_width_p,data_width_p,x_cord_width_p,y_cord_width_p);

  logic is_invalid_addr_lo;
  logic is_invalid_eva;
  logic [x_cord_width_p-1:0] x_cord_lo;
  logic [y_cord_width_p-1:0] y_cord_lo;
  logic [addr_width_p-1:0] epa_lo;

  wire [x_cord_width_p-1:0] src_x_cord = {pod_x_i, my_x_i};
  wire [y_cord_width_p-1:0] src_y_cord = {pod_y_i, my_y_i};

  wire proxy_is_in_the_south = src_y_cord[y_subcord_width_lp-1];
  wire [pod_y_cord_width_p-1:0] proxy_pod_y_step = proxy_is_in_the_south ? {{(pod_y_cord_width_p-1){1'b0}}, 1'b1} : {pod_y_cord_width_p{1'b1}};
  wire [pod_y_cord_width_p-1:0] proxy_pod_y = pod_y_i + proxy_pod_y_step;

  wire [x_cord_width_p-1:0] proxy_x_cord_lo = src_x_cord;
  wire [y_cord_width_p-1:0] proxy_y_cord_lo = {proxy_pod_y, {y_subcord_width_lp{~proxy_is_in_the_south}}};

  wire [addr_width_p-1:0] io_addr = remote_req_i.addr[addr_width_p+1:2];
  wire is_uncached_op = remote_req_i.is_uncached_op;
  assign is_invalid_addr_lo = is_invalid_eva & ~is_uncached_op & ~remote_req_i.load_info.icache_fetch;

  bsg_manycore_eva_to_npa #(
    .data_width_p(data_width_p)
    ,.addr_width_p(addr_width_p)
    ,.x_cord_width_p(x_cord_width_p)
    ,.y_cord_width_p(y_cord_width_p)
    ,.num_tiles_x_p(num_tiles_x_p)
    ,.num_tiles_y_p(num_tiles_y_p)
    ,.vcache_block_size_in_words_p(vcache_block_size_in_words_p)
    ,.vcache_size_p(vcache_size_p)
    ,.vcache_sets_p(vcache_sets_p)
    ,.pod_x_cord_width_p(pod_x_cord_width_p)
    ,.pod_y_cord_width_p(pod_y_cord_width_p)
    ,.ipoly_hashing_p(ipoly_hashing_p)
  ) eva2npa (
    .eva_i(remote_req_i.addr)
    ,.tgo_x_i(tgo_x_i)
    ,.tgo_y_i(tgo_y_i)
    ,.x_cord_o(x_cord_lo)
    ,.y_cord_o(y_cord_lo)
    ,.epa_o(epa_lo)
    ,.is_invalid_addr_o(is_invalid_eva)
    ,.pod_x_i(remote_req_i.load_info.icache_fetch ? pod_x_i : cfg_pod_x_i)
    ,.pod_y_i(remote_req_i.load_info.icache_fetch ? pod_y_i : cfg_pod_y_i)
  );

  bsg_manycore_packet_s live_pkt;
  always_comb begin
    if (remote_req_i.write_not_read | remote_req_i.is_amo_op) begin
      live_pkt.payload = remote_req_i.data;
    end
    else begin
      live_pkt.payload.load_info_s.load_info = remote_req_i.load_info;
      live_pkt.payload.load_info_s.reserved  = '0;
    end

    if (is_uncached_op) begin
      live_pkt.y_cord = proxy_y_cord_lo;
      live_pkt.x_cord = proxy_x_cord_lo;
      live_pkt.addr   = io_addr;
    end
    else begin
      live_pkt.y_cord = y_cord_lo;
      live_pkt.x_cord = x_cord_lo;
      live_pkt.addr   = epa_lo;
    end

    if (remote_req_i.write_not_read) begin
      live_pkt.reg_id.store_mask_s.mask   = remote_req_i.mask;
      live_pkt.reg_id.store_mask_s.unused = 1'b0;
    end
    else begin
      live_pkt.reg_id = remote_req_i.reg_id;
    end

    live_pkt.src_y_cord = src_y_cord;
    live_pkt.src_x_cord = src_x_cord;

    if (remote_req_i.is_amo_op) begin
      case (remote_req_i.amo_type)
        e_vanilla_amoswap: live_pkt.op_v2 = e_remote_amoswap;
        e_vanilla_amoor:   live_pkt.op_v2 = e_remote_amoor;
        e_vanilla_amoadd:  live_pkt.op_v2 = e_remote_amoadd;
        default:           live_pkt.op_v2 = e_remote_amoswap;
      endcase
    end
    else if (remote_req_i.write_not_read) begin
      live_pkt.op_v2 = is_uncached_op ? e_remote_uncached_store : e_remote_store;
    end
    else begin
      live_pkt.op_v2 = is_uncached_op ? e_remote_uncached_load : e_remote_load;
    end
  end

  typedef struct packed {
    logic [addr_width_p-1:0] addr;
    bsg_manycore_packet_op_e op_v2;
    bsg_manycore_packet_reg_id_u reg_id;
    bsg_manycore_packet_payload_u payload;
    logic [y_cord_width_p-1:0] y_cord;
    logic [x_cord_width_p-1:0] x_cord;
  } held_pkt_s;

  logic held_v_r;
  held_pkt_s held_pkt_r;

  wire live_req_valid = ~held_v_r & remote_req_v_i & ~is_invalid_addr_lo & ~flush_i;

  always_ff @(posedge clk_i) begin
    if (reset_i | flush_i) begin
      held_v_r <= 1'b0;
    end
    else if (held_v_r) begin
      if (out_credit_or_ready_i) begin
        held_v_r <= 1'b0;
      end
    end
    else if (remote_req_v_i & ~is_invalid_addr_lo & ~out_credit_or_ready_i) begin
      held_v_r <= 1'b1;
    end
  end

  always_ff @(posedge clk_i) begin
    if (~held_v_r & ~out_credit_or_ready_i) begin
      held_pkt_r <= '{
        addr    : live_pkt.addr,
        op_v2   : live_pkt.op_v2,
        reg_id  : live_pkt.reg_id,
        payload : live_pkt.payload,
        y_cord  : live_pkt.y_cord,
        x_cord  : live_pkt.x_cord
      };
    end
  end

  bsg_manycore_packet_s out_packet;
  always_comb begin
    if (held_v_r) begin
      out_packet.addr       = held_pkt_r.addr;
      out_packet.op_v2      = held_pkt_r.op_v2;
      out_packet.reg_id     = held_pkt_r.reg_id;
      out_packet.payload    = held_pkt_r.payload;
      out_packet.src_y_cord = src_y_cord;
      out_packet.src_x_cord = src_x_cord;
      out_packet.y_cord     = held_pkt_r.y_cord;
      out_packet.x_cord     = held_pkt_r.x_cord;
    end
    else begin
      out_packet = live_pkt;
    end
  end

  assign out_packet_o = out_packet;
  assign out_v_o = ~flush_i & (held_v_r | live_req_valid);
  assign remote_req_credit_o = out_credit_or_ready_i & ~held_v_r;
  assign invalid_eva_access_o = ~held_v_r & ~flush_i & remote_req_v_i & is_invalid_addr_lo;

  assign ifetch_instr_o = returned_data_i;
  assign int_remote_load_resp_data_o = returned_data_i;
  assign int_remote_load_resp_rd_o = returned_reg_id_i;
  assign float_remote_load_resp_data_o = returned_data_i;
  assign float_remote_load_resp_rd_o = returned_reg_id_i;

  always_comb begin
    ifetch_v_o = 1'b0;
    int_remote_load_resp_v_o = 1'b0;
    int_remote_load_resp_force_o = 1'b0;
    float_remote_load_resp_v_o = 1'b0;
    float_remote_load_resp_force_o = 1'b0;
    returned_yumi_o = 1'b0;

    unique casez (returned_pkt_type_i)
      e_return_ifetch: begin
        ifetch_v_o = returned_v_i;
        returned_yumi_o = returned_v_i;
      end
      e_return_float_wb: begin
        float_remote_load_resp_v_o = returned_v_i;
        float_remote_load_resp_force_o = returned_v_i & returned_fifo_full_i;
        returned_yumi_o = returned_v_i & float_remote_load_resp_yumi_i;
      end
      e_return_int_wb: begin
        int_remote_load_resp_v_o = returned_v_i;
        int_remote_load_resp_force_o = returned_v_i & returned_fifo_full_i;
        returned_yumi_o = returned_v_i & int_remote_load_resp_yumi_i;
      end
      default: begin
      end
    endcase
  end

endmodule
