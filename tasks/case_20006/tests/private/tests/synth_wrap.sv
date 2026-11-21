// Concrete synthesis wrapper instantiating axi_llc_hit_miss (AxiIdLookupBits=0)
// and axi_llc_miss_counters (AxiIdLookupBits=0 and AxiIdLookupBits=2) for gate-level parity!
module synth_hit_miss_wrap (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        test_i,
  input  logic [77:0] desc_in_flat,
  input  logic        valid_i,
  output logic        ready_o,
  output logic [77:0] desc_out_flat,
  output logic        miss_valid_o,
  input  logic        miss_ready_i,
  output logic        hit_valid_o,
  input  logic        hit_ready_i,
  input  logic [3:0]  spm_lock_i,
  input  logic [3:0]  flushed_i,
  input  logic [5:0]  w_unlock_flat,
  input  logic        w_unlock_req_i,
  output logic        w_unlock_gnt_o,
  input  logic [5:0]  r_unlock_flat,
  input  logic        r_unlock_req_i,
  output logic        r_unlock_gnt_o,
  input  logic [5:0]  cnt_down_flat,
  output logic [3:0]  bist_res_o,
  output logic        bist_valid_o,
  // Direct miss_counters (AxiIdLookupBits=0 & 2) gate-level probes
  input  logic [5:0]  mc_up_flat,
  input  logic [5:0]  mc_dn_flat,
  output logic        mc0_to_miss_o,
  output logic        mc0_stall_o,
  output logic        mc2_to_miss_o,
  output logic        mc2_stall_o
);
  localparam axi_llc_pkg::llc_axi_cfg_t AxiCfg = axi_llc_pkg::llc_axi_cfg_t'{
    SlvPortIdWidth: 32'd4,
    AddrWidthFull:  32'd32,
    DataWidthFull:  32'd64
  };
  localparam axi_llc_pkg::llc_cfg_t Cfg = axi_llc_pkg::llc_cfg_t'{
    SetAssociativity:  32'd4,
    NumLines:          32'd4,
    NumBlocks:         32'd2,
    BlockSize:         32'd64,
    TagLength:         32'd26,
    IndexLength:       32'd2,
    BlockOffsetLength: 32'd1,
    ByteOffsetLength:  32'd3,
    SPMLength:         32'd256
  };

  typedef logic [3:0]  id_t;
  typedef logic [31:0] addr_t;
  typedef logic [3:0]  way_ind_t;

  // 4 + 32 + 8 + 3 + 2 + 1 + 4 + 3 + 2 + 1 + 1 + 1 + 4 + 1 + 26 + 1 + 1 = 95 bits? Let's compute exact width:
  // Wait: let's define desc_t and pack/unpack with exact width 95!
  typedef struct packed {
    id_t              a_x_id;    // 4
    addr_t            a_x_addr;  // 32
    axi_pkg::len_t    a_x_len;   // 8
    axi_pkg::size_t   a_x_size;  // 3
    axi_pkg::burst_t  a_x_burst; // 2
    logic             a_x_lock;  // 1
    axi_pkg::cache_t  a_x_cache; // 4
    axi_pkg::prot_t   a_x_prot;  // 3
    axi_pkg::resp_t   x_resp;    // 2
    logic             x_last;    // 1
    logic             spm;       // 1
    logic             rw;        // 1
    way_ind_t         way_ind;   // 4
    logic             evict;     // 1
    logic [25:0]      evict_tag; // 26
    logic             refill;    // 1
    logic             flush;     // 1
  } desc_t; // Total = 95 bits!

  // Wait: let's widen desc_in_flat / desc_out_flat or pack only compact fields? Better yet, make port [94:0]!
  typedef struct packed {
    logic [1:0] index;
    way_ind_t   way_ind;
  } lock_t; // 6 bits

  typedef struct packed {
    id_t  id;
    logic rw;
    logic valid;
  } cnt_t; // 6 bits

  desc_t d_in, d_out;
  assign d_in = '{
    a_x_id:    desc_in_flat[77:74],
    a_x_addr:  desc_in_flat[73:42],
    a_x_len:   8'd0,
    a_x_size:  3'd3,
    a_x_burst: axi_pkg::BURST_INCR,
    a_x_lock:  1'b0,
    a_x_cache: 4'd0,
    a_x_prot:  3'd0,
    x_resp:    axi_pkg::resp_t'(desc_in_flat[41:40]),
    x_last:    desc_in_flat[39],
    spm:       desc_in_flat[38],
    rw:        desc_in_flat[37],
    way_ind:   desc_in_flat[36:33],
    evict:     desc_in_flat[32],
    evict_tag: desc_in_flat[31:6],
    refill:    desc_in_flat[5],
    flush:     desc_in_flat[4]
  };
  assign desc_out_flat = {
    d_out.a_x_id,
    d_out.a_x_addr,
    d_out.x_resp,
    d_out.x_last,
    d_out.spm,
    d_out.rw,
    d_out.way_ind,
    d_out.evict,
    d_out.evict_tag,
    d_out.refill,
    d_out.flush,
    4'b0
  };

  axi_llc_hit_miss #(
    .Cfg             ( Cfg       ),
    .AxiCfg          ( AxiCfg    ),
    .desc_t          ( desc_t    ),
    .lock_t          ( lock_t    ),
    .cnt_t           ( cnt_t     ),
    .way_ind_t       ( way_ind_t ),
    .AxiIdLookupBits ( 32'd0     )
  ) u_hm (
    .clk_i          ( clk_i                 ),
    .rst_ni         ( rst_ni                ),
    .test_i         ( test_i                ),
    .desc_i         ( d_in                  ),
    .valid_i        ( valid_i               ),
    .ready_o        ( ready_o               ),
    .desc_o         ( d_out                 ),
    .miss_valid_o   ( miss_valid_o          ),
    .miss_ready_i   ( miss_ready_i          ),
    .hit_valid_o    ( hit_valid_o           ),
    .hit_ready_i    ( hit_ready_i           ),
    .spm_lock_i     ( spm_lock_i            ),
    .flushed_i      ( flushed_i             ),
    .w_unlock_i     ( lock_t'(w_unlock_flat)),
    .w_unlock_req_i ( w_unlock_req_i        ),
    .w_unlock_gnt_o ( w_unlock_gnt_o        ),
    .r_unlock_i     ( lock_t'(r_unlock_flat)),
    .r_unlock_req_i ( r_unlock_req_i        ),
    .r_unlock_gnt_o ( r_unlock_gnt_o        ),
    .cnt_down_i     ( cnt_t'(cnt_down_flat) ),
    .bist_res_o     ( bist_res_o            ),
    .bist_valid_o   ( bist_valid_o          )
  );

  axi_llc_miss_counters #(
    .Cfg             ( Cfg    ),
    .cnt_t           ( cnt_t  ),
    .AxiIdLookupBits ( 32'd0  )
  ) u_mc0 (
    .clk_i      ( clk_i             ),
    .rst_ni     ( rst_ni            ),
    .cnt_up_i   ( cnt_t'(mc_up_flat)),
    .cnt_down_i ( cnt_t'(mc_dn_flat)),
    .to_miss_o  ( mc0_to_miss_o     ),
    .stall_o    ( mc0_stall_o       )
  );

  axi_llc_miss_counters #(
    .Cfg             ( Cfg    ),
    .cnt_t           ( cnt_t  ),
    .AxiIdLookupBits ( 32'd2  )
  ) u_mc2 (
    .clk_i      ( clk_i             ),
    .rst_ni     ( rst_ni            ),
    .cnt_up_i   ( cnt_t'(mc_up_flat)),
    .cnt_down_i ( cnt_t'(mc_dn_flat)),
    .to_miss_o  ( mc2_to_miss_o     ),
    .stall_o    ( mc2_stall_o       )
  );
endmodule
