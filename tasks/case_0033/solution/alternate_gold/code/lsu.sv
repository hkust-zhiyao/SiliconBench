`include "bsg_defines.sv"

module lsu
  import bsg_manycore_pkg::*;
  import bsg_manycore_addr_pkg::*;
  import bsg_vanilla_pkg::*;
  #(`BSG_INV_PARAM(data_width_p)
    , `BSG_INV_PARAM(pc_width_p)
    , `BSG_INV_PARAM(dmem_size_p)
    , localparam dmem_addr_width_lp=`BSG_SAFE_CLOG2(dmem_size_p)
    , data_mask_width_lp=(data_width_p>>3)
    , reg_addr_width_lp=RV32_reg_addr_width_gp
  )
  (
    input clk_i
    , input reset_i
    , input decode_s exe_decode_i
    , input [data_width_p-1:0] exe_rs1_i
    , input [data_width_p-1:0] exe_rs2_i
    , input [reg_addr_width_lp-1:0] exe_rd_i
    , input [RV32_Iimm_width_gp-1:0] mem_offset_i
    , input [data_width_p-1:0] pc_plus4_i
    , input icache_miss_i
    , output remote_req_s remote_req_o
    , output logic remote_req_v_o
    , output logic dmem_v_o
    , output logic dmem_w_o
    , output logic [dmem_addr_width_lp-1:0] dmem_addr_o
    , output logic [data_width_p-1:0] dmem_data_o
    , output logic [data_mask_width_lp-1:0] dmem_mask_o
    , output logic reserve_o
    , output logic [1:0] byte_sel_o
  );

  wire unused = clk_i ^ reset_i;

  wire [data_width_p-1:0] addr_a = icache_miss_i ? pc_plus4_i : exe_rs1_i;
  wire [11:0] off_lo = icache_miss_i ? 12'hffc : mem_offset_i;
  wire off_neg = icache_miss_i | mem_offset_i[11];

  // 12-bit low adder + parallel Kogge-Stone prefix +/-1 on upper 20 bits
  wire [12:0] sum_lo = {1'b0, addr_a[11:0]} + {1'b0, off_lo};
  wire c12 = sum_lo[12];
  wire do_inc = ~off_neg & c12;
  wire do_dec =  off_neg & ~c12;

  wire [19:0] h0 = addr_a[31:12];
  wire [19:0] z0 = ~h0;
  wire [3:0] grp_p = {&h0[19:15], &h0[14:10], &h0[9:5], &h0[4:0]};
  wire [3:0] grp_z = {&z0[19:15], &z0[14:10], &z0[9:5], &z0[4:0]};
  wire [3:0] grp_ci = {grp_p[2] & grp_p[1] & grp_p[0], grp_p[1] & grp_p[0], grp_p[0], 1'b1};
  wire [3:0] grp_bi = {grp_z[2] & grp_z[1] & grp_z[0], grp_z[1] & grp_z[0], grp_z[0], 1'b1};
  logic [19:0] prop_inc, prop_dec;
  for (genvar g = 0; g < 4; g++) begin : g_blk
    wire [4:0] hp = h0[5*g +: 5];
    wire [4:0] zp = z0[5*g +: 5];
    wire [4:0] loc_p = {hp[3]&hp[2]&hp[1]&hp[0], hp[2]&hp[1]&hp[0], hp[1]&hp[0], hp[0], 1'b1};
    wire [4:0] loc_z = {zp[3]&zp[2]&zp[1]&zp[0], zp[2]&zp[1]&zp[0], zp[1]&zp[0], zp[0], 1'b1};
    assign prop_inc[5*g +: 5] = {5{grp_ci[g]}} & loc_p;
    assign prop_dec[5*g +: 5] = {5{grp_bi[g]}} & loc_z;
  end

  wire [19:0] sum_hi = h0 ^ ({20{do_inc}} & prop_inc) ^ ({20{do_dec}} & prop_dec);
  wire [data_width_p-1:0] calc_addr = {sum_hi, sum_lo[11:0]};
  wire [data_width_p-1:0] req_addr = icache_miss_i ? (calc_addr | bsg_dram_npa_prefix_gp) : calc_addr;

  logic [data_width_p-1:0] store_data;
  logic [data_mask_width_lp-1:0] store_mask;

  always_comb begin
    if (exe_decode_i.is_byte_op) begin
      store_data = {4{exe_rs2_i[7:0]}};
      store_mask = {
         calc_addr[1] &  calc_addr[0],
         calc_addr[1] & ~calc_addr[0],
        ~calc_addr[1] &  calc_addr[0],
        ~calc_addr[1] & ~calc_addr[0]
      };
    end
    else if (exe_decode_i.is_hex_op) begin
      store_data = {2{exe_rs2_i[15:0]}};
      store_mask = {
        {2{calc_addr[1]}},
        {2{~calc_addr[1]}}
      };
    end
    else begin
      store_data = exe_rs2_i;
      store_mask = 4'b1111;
    end
  end

  wire is_local_dmem_addr = ~icache_miss_i & ~exe_decode_i.is_uncached_op & ~(|sum_hi);

  assign dmem_v_o = is_local_dmem_addr &
    (exe_decode_i.is_load_op | exe_decode_i.is_store_op |
     exe_decode_i.is_lr_op | exe_decode_i.is_lr_aq_op);
  assign dmem_w_o = ~icache_miss_i & exe_decode_i.is_store_op;
  assign dmem_addr_o = calc_addr[2+:dmem_addr_width_lp];
  assign dmem_data_o = store_data;
  assign dmem_mask_o = store_mask;
  assign byte_sel_o = calc_addr[1:0];

  bsg_manycore_load_info_s load_info;

  always_comb begin
    if (icache_miss_i) begin
      load_info = '{
        float_wb: 1'b0,
        icache_fetch: 1'b1,
        is_unsigned_op: 1'b0,
        is_byte_op: 1'b0,
        is_hex_op: 1'b0,
        part_sel: 2'b00
      };
    end
    else begin
      load_info = '{
        float_wb: exe_decode_i.write_frd,
        icache_fetch: 1'b0,
        is_unsigned_op: exe_decode_i.is_load_unsigned,
        is_byte_op: exe_decode_i.is_byte_op,
        is_hex_op: exe_decode_i.is_hex_op,
        part_sel: exe_decode_i.is_uncached_op ? 2'b00 : calc_addr[1:0]
      };
    end

    remote_req_o = '{
      write_not_read : (~icache_miss_i & exe_decode_i.is_store_op),
      is_amo_op : (~icache_miss_i & exe_decode_i.is_amo_op),
      is_uncached_op : (~icache_miss_i & exe_decode_i.is_uncached_op),
      amo_type : exe_decode_i.amo_type,
      mask: store_mask,
      load_info : load_info,
      reg_id : exe_rd_i,
      data : store_data,
      addr : req_addr
    };
  end

  assign remote_req_v_o = icache_miss_i |
    ((exe_decode_i.is_load_op | exe_decode_i.is_store_op | exe_decode_i.is_amo_op) & ~is_local_dmem_addr);

  assign reserve_o = ~icache_miss_i & exe_decode_i.is_lr_op & is_local_dmem_addr;

endmodule
