`timescale 1ns/1ps

module tb;
  logic clk = 1'b0;
  always #2.5 clk = ~clk;

  int seed = 101;
  logic rst_ni;

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

  typedef struct packed {
    id_t              a_x_id;
    addr_t            a_x_addr;
    axi_pkg::len_t    a_x_len;
    axi_pkg::size_t   a_x_size;
    axi_pkg::burst_t  a_x_burst;
    logic             a_x_lock;
    axi_pkg::cache_t  a_x_cache;
    axi_pkg::prot_t   a_x_prot;
    axi_pkg::resp_t   x_resp;
    logic             x_last;
    logic             spm;
    logic             rw;
    way_ind_t         way_ind;
    logic             evict;
    logic [25:0]      evict_tag;
    logic             refill;
    logic             flush;
  } desc_t;

  typedef struct packed {
    logic [1:0] index;
    way_ind_t   way_ind;
  } lock_t;

  typedef struct packed {
    id_t  id;
    logic rw;
    logic valid;
  } cnt_t;

  // -------------------------------------------------------------------------
  // 1. RTL vs Synthesized Gate-Level Lockstep Co-Simulation Wrapper
  // -------------------------------------------------------------------------
  logic [77:0] desc_in_flat;
  logic        hm_valid_i;
  logic        hm_ready_rtl, hm_ready_gl;
  logic [77:0] desc_out_rtl, desc_out_gl;
  logic        miss_v_rtl, miss_v_gl, miss_r_i;
  logic        hit_v_rtl,  hit_v_gl,  hit_r_i;
  logic [3:0]  spm_lock_i, flushed_i;
  logic [5:0]  w_unl_flat, r_unl_flat, cnt_dn_flat;
  logic        w_unl_req, w_unl_gnt_rtl, w_unl_gnt_gl;
  logic        r_unl_req, r_unl_gnt_rtl, r_unl_gnt_gl;
  logic [3:0]  bist_res_rtl, bist_res_gl;
  logic        bist_val_rtl, bist_val_gl;

  cnt_t        mc_up_s, mc_dn_s;
  logic        mc0_tm_rtl, mc0_tm_gl, mc0_st_rtl, mc0_st_gl;
  logic        mc2_tm_rtl, mc2_tm_gl, mc2_st_rtl, mc2_st_gl;
  logic        mc4_tm_rtl, mc4_st_rtl;

  synth_hit_miss_wrap u_rtl_wrap (
    .clk_i          ( clk           ),
    .rst_ni         ( rst_ni        ),
    .test_i         ( 1'b0          ),
    .desc_in_flat   ( desc_in_flat  ),
    .valid_i        ( hm_valid_i    ),
    .ready_o        ( hm_ready_rtl  ),
    .desc_out_flat  ( desc_out_rtl  ),
    .miss_valid_o   ( miss_v_rtl    ),
    .miss_ready_i   ( miss_r_i      ),
    .hit_valid_o    ( hit_v_rtl     ),
    .hit_ready_i    ( hit_r_i       ),
    .spm_lock_i     ( spm_lock_i    ),
    .flushed_i      ( flushed_i     ),
    .w_unlock_flat  ( w_unl_flat    ),
    .w_unlock_req_i ( w_unl_req     ),
    .w_unlock_gnt_o ( w_unl_gnt_rtl ),
    .r_unlock_flat  ( r_unl_flat    ),
    .r_unlock_req_i ( r_unl_req     ),
    .r_unlock_gnt_o ( r_unl_gnt_rtl ),
    .cnt_down_flat  ( cnt_dn_flat   ),
    .bist_res_o     ( bist_res_rtl  ),
    .bist_valid_o   ( bist_val_rtl  ),
    .mc_up_flat     ( mc_up_s       ),
    .mc_dn_flat     ( mc_dn_s       ),
    .mc0_to_miss_o  ( mc0_tm_rtl    ),
    .mc0_stall_o    ( mc0_st_rtl    ),
    .mc2_to_miss_o  ( mc2_tm_rtl    ),
    .mc2_stall_o    ( mc2_st_rtl    )
  );

  synth_hit_miss_wrap_gl u_gl_wrap (
    .clk_i          ( clk           ),
    .rst_ni         ( rst_ni        ),
    .test_i         ( 1'b0          ),
    .desc_in_flat   ( desc_in_flat  ),
    .valid_i        ( hm_valid_i    ),
    .ready_o        ( hm_ready_gl   ),
    .desc_out_flat  ( desc_out_gl   ),
    .miss_valid_o   ( miss_v_gl     ),
    .miss_ready_i   ( miss_r_i      ),
    .hit_valid_o    ( hit_v_gl      ),
    .hit_ready_i    ( hit_r_i       ),
    .spm_lock_i     ( spm_lock_i    ),
    .flushed_i      ( flushed_i     ),
    .w_unlock_flat  ( w_unl_flat    ),
    .w_unlock_req_i ( w_unl_req     ),
    .w_unlock_gnt_o ( w_unl_gnt_gl  ),
    .r_unlock_flat  ( r_unl_flat    ),
    .r_unlock_req_i ( r_unl_req     ),
    .r_unlock_gnt_o ( r_unl_gnt_gl  ),
    .cnt_down_flat  ( cnt_dn_flat   ),
    .bist_res_o     ( bist_res_gl   ),
    .bist_valid_o   ( bist_val_gl   ),
    .mc_up_flat     ( mc_up_s       ),
    .mc_dn_flat     ( mc_dn_s       ),
    .mc0_to_miss_o  ( mc0_tm_gl     ),
    .mc0_stall_o    ( mc0_st_gl     ),
    .mc2_to_miss_o  ( mc2_tm_gl     ),
    .mc2_stall_o    ( mc2_st_gl     )
  );

  // Also instantiate AxiIdLookupBits == AxiCfg.SlvPortIdWidth (4)
  axi_llc_miss_counters #(
    .Cfg             ( Cfg    ),
    .cnt_t           ( cnt_t  ),
    .AxiIdLookupBits ( 32'd4  )
  ) u_mc4 (
    .clk_i      ( clk         ),
    .rst_ni     ( rst_ni      ),
    .cnt_up_i   ( mc_up_s     ),
    .cnt_down_i ( mc_dn_s     ),
    .to_miss_o  ( mc4_tm_rtl  ),
    .stall_o    ( mc4_st_rtl  )
  );

  // Lockstep RTL vs Gate-Level checker on every posedge!
  bit enable_cosim_chk = 1'b0;
  always @(posedge clk) begin
    if (rst_ni && enable_cosim_chk) begin
      if (hm_ready_rtl !== hm_ready_gl ||
          miss_v_rtl   !== miss_v_gl   ||
          hit_v_rtl    !== hit_v_gl    ||
          bist_val_rtl !== bist_val_gl ||
          bist_res_rtl !== bist_res_gl ||
          mc0_tm_rtl   !== mc0_tm_gl   ||
          mc0_st_rtl   !== mc0_st_gl   ||
          mc2_tm_rtl   !== mc2_tm_gl   ||
          mc2_st_rtl   !== mc2_st_gl) begin
        $display("FAIL S2_Parity: RTL vs Gate-Level control mismatch! rdy(%b/%b) mv(%b/%b) hv(%b/%b) bist(%b:%h / %b:%h) mc0(%b,%b / %b,%b) mc2(%b,%b / %b,%b)",
                 hm_ready_rtl, hm_ready_gl, miss_v_rtl, miss_v_gl, hit_v_rtl, hit_v_gl,
                 bist_val_rtl, bist_res_rtl, bist_val_gl, bist_res_gl,
                 mc0_tm_rtl, mc0_st_rtl, mc0_tm_gl, mc0_st_gl,
                 mc2_tm_rtl, mc2_st_rtl, mc2_tm_gl, mc2_st_gl);
        $finish(1);
      end
      if ((miss_v_rtl || hit_v_rtl) && (desc_out_rtl !== desc_out_gl)) begin
        $display("FAIL S2_Parity: desc_o payload mismatch between RTL (%h) and Gate-Level (%h)!", desc_out_rtl, desc_out_gl);
        $finish(1);
      end
    end
  end

  // -------------------------------------------------------------------------
  // 2. Direct Multi-Latency & Fault-Injecting Tag BIST Harness (Latency=1 & Latency=4 > NumLines=2)
  // -------------------------------------------------------------------------
  localparam axi_llc_pkg::llc_cfg_t BistCfg = axi_llc_pkg::llc_cfg_t'{
    SetAssociativity:  32'd4,
    NumLines:          32'd2,
    NumBlocks:         32'd2,
    BlockSize:         32'd64,
    TagLength:         32'd6,
    IndexLength:       32'd1,
    BlockOffsetLength: 32'd1,
    ByteOffsetLength:  32'd3,
    SPMLength:         32'd64
  };
  typedef struct packed {
    logic       val;
    logic       dit;
    logic [5:0] tag;
  } bpat_t;

  logic        b_start, b_ready, b_req, b_we, b_rval, b_eoc;
  logic [0:0]  b_idx;
  bpat_t       b_pat;
  logic [3:0]  b_resi, b_reso;

  axi_llc_tag_pattern_gen #(
    .Cfg       ( BistCfg      ),
    .pattern_t ( bpat_t       ),
    .way_ind_t ( logic [3:0]  ),
    .index_t   ( logic [0:0]  )
  ) u_bist_dut (
    .clk_i            ( clk      ),
    .rst_ni           ( rst_ni   ),
    .valid_i          ( b_start  ),
    .ready_o          ( b_ready  ),
    .index_o          ( b_idx    ),
    .pattern_o        ( b_pat    ),
    .req_o            ( b_req    ),
    .we_o             ( b_we     ),
    .bist_res_i       ( b_resi   ),
    .bist_res_valid_i ( b_rval   ),
    .bist_res_o       ( b_reso   ),
    .eoc_o            ( b_eoc    )
  );

  // 4-way SRAM model with configurable Latency (up to 4 > NumLines=2!) & stuck-at fault masks
  int          b_lat_cfg = 1;
  logic [7:0]  b_mem [0:3][0:1];
  logic [3:0]  b_sa0_idx0_way; // stuck-at-0 bit 0 at index 0 per way
  logic [3:0]  b_sa1_idx1_way; // stuck-at-1 bit 7 at index 1 per way
  logic [4:0]  b_vpipe;
  bpat_t       b_ppipe [0:4];
  logic [3:0][7:0] b_dpipe [0:4];

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      b_vpipe <= '0;
      for (int s = 0; s < 5; s++) begin
        b_ppipe[s] <= '0;
        b_dpipe[s] <= '0;
      end
      for (int w = 0; w < 4; w++) begin
        b_mem[w][0] <= 8'hA5;
        b_mem[w][1] <= 8'h5A;
      end
    end else begin
      if (b_req && b_we) begin
        for (int w = 0; w < 4; w++) begin
          logic [7:0] wr_v;
          wr_v = b_pat;
          if ((b_idx == 1'b0) && b_sa0_idx0_way[w]) wr_v[0] = 1'b0;
          if ((b_idx == 1'b1) && b_sa1_idx1_way[w]) wr_v[7] = 1'b1;
          b_mem[w][b_idx] <= wr_v;
        end
      end
      b_vpipe[0] <= b_req && !b_we;
      b_ppipe[0] <= b_pat;
      for (int w = 0; w < 4; w++) begin
        b_dpipe[0][w] <= (b_req && !b_we) ? b_mem[w][b_idx] : 8'hFF;
      end
      for (int s = 1; s < 5; s++) begin
        b_vpipe[s] <= b_vpipe[s-1];
        b_ppipe[s] <= b_ppipe[s-1];
        b_dpipe[s] <= b_dpipe[s-1];
      end
    end
  end

  always_comb begin
    b_rval = b_vpipe[b_lat_cfg - 1];
    // Drive mismatching/corrupted 4'b0000 (and 4'bxxxx) whenever b_rval == 0!
    if (!b_rval) begin
      b_resi = 4'b0000;
    end else begin
      for (int w = 0; w < 4; w++) begin
        b_resi[w] = (b_dpipe[b_lat_cfg - 1][w] == b_ppipe[b_lat_cfg - 1]);
      end
    end
  end

  function automatic logic [77:0] pack_desc(
    input id_t id, input addr_t addr, input axi_pkg::resp_t resp,
    input logic spm, input logic rw, input way_ind_t way_ind, input logic flush
  );
    return {id, addr, resp, 1'b1, spm, rw, way_ind, 1'b0, 26'd0, 1'b0, flush, 4'b0};
  endfunction

  task automatic reset_all();
    enable_cosim_chk = 1'b0;
    rst_ni       = 1'b0;
    desc_in_flat = '0;
    hm_valid_i   = 1'b0;
    miss_r_i     = 1'b1;
    hit_r_i      = 1'b1;
    spm_lock_i   = 4'b0000;
    flushed_i    = 4'b0000;
    w_unl_flat   = '0; w_unl_req = 1'b0;
    r_unl_flat   = '0; r_unl_req = 1'b0;
    cnt_dn_flat  = '0;
    mc_up_s      = '0; mc_dn_s   = '0;
    b_start      = 1'b0;
    b_lat_cfg    = 1;
    b_sa0_idx0_way = 4'b0000;
    b_sa1_idx1_way = 4'b0000;
    repeat (4) @(posedge clk);
    #1; rst_ni = 1'b1;
    @(posedge clk); #1;
    enable_cosim_chk = 1'b1;
  endtask

  initial begin
    int cyc;
    if (!$value$plusargs("seed=%d", seed)) seed = 101;
    reset_all();

    // =========================================================================
    // Test 1: Miss Counters Saturation (`2**MissCntWidth == 32`, `2**MissCntMaxWWidth == 128`),
    //         `to_miss_o` Parity at Full Capacity, Simultaneous Up/Down, and Underflow/Overflow Clamping!
    // =========================================================================
    // 1a: Push 32 Read Misses for ID=4'd5 -> mc0, mc2 (bucket 1), mc4 (bucket 5) MUST all hit stall==1 AND keep to_miss_o==1!
    for (int k = 0; k < 32; k++) begin
      mc_up_s = '{id: 4'd5, rw: 1'b0, valid: 1'b1};
      mc_dn_s = '0;
      #1;
      if (k == 0 && (mc0_tm_rtl || mc2_tm_rtl || mc4_tm_rtl)) begin
        $display("FAIL Test1a_0: Expected to_miss_o==0 when count==0!"); $finish(1);
      end
      if (k > 0 && (!mc0_tm_rtl || !mc2_tm_rtl || !mc4_tm_rtl)) begin
        $display("FAIL Test1a_mid: Expected to_miss_o==1 at count=%0d!", k); $finish(1);
      end
      if (mc0_st_rtl || mc2_st_rtl || mc4_st_rtl) begin
        $display("FAIL Test1a_early_stall: Unexpected stall before 32 at k=%0d!", k); $finish(1);
      end
      @(posedge clk); #1;
    end

    // Now exactly 32 misses are in flight! Probe with valid=0 (proving no combinational dependency on cnt_up_i.valid!)
    mc_up_s = '{id: 4'd5, rw: 1'b0, valid: 1'b0};
    mc_dn_s = '0;
    #1;
    if (!mc0_st_rtl || !mc2_st_rtl || !mc4_st_rtl) begin
      $display("FAIL Test1a_stall: Expected stall_o==1 at 32 misses! st=(%b,%b,%b)", mc0_st_rtl, mc2_st_rtl, mc4_st_rtl);
      $finish(1);
    end
    if (!mc0_tm_rtl || !mc2_tm_rtl || !mc4_tm_rtl) begin
      $display("FAIL Test1a_sat_tomiss: to_miss_o wrapped to 0 when counter saturated at 32! tm=(%b,%b,%b)",
               mc0_tm_rtl, mc2_tm_rtl, mc4_tm_rtl);
      $finish(1);
    end
    // Check ID folding difference across AxiIdLookupBits={0, 2, 4}:
    // Probe ID=4'd9 (low 2 bits == 2'b01 == 5[1:0]!):
    //   - AxiIdLookupBits=0 -> bucket 0 -> to_miss=1
    //   - AxiIdLookupBits=2 -> bucket 1 -> to_miss=1 (aliased with ID 5!)
    //   - AxiIdLookupBits=4 -> bucket 9 -> to_miss=0 (distinct from ID 5!)
    mc_up_s = '{id: 4'd9, rw: 1'b0, valid: 1'b0};
    #1;
    if (!mc0_tm_rtl || !mc2_tm_rtl || mc4_tm_rtl) begin
      $display("FAIL Test1b_folding: Expected (1, 1, 0) for ID=9 when ID=5 active, got (%b, %b, %b)!",
               mc0_tm_rtl, mc2_tm_rtl, mc4_tm_rtl);
      $finish(1);
    end

    // Simultaneous up & down at saturation (32) MUST hold at 32 (stall=1, to_miss=1)!
    mc_up_s = '{id: 4'd5, rw: 1'b0, valid: 1'b1};
    mc_dn_s = '{id: 4'd5, rw: 1'b0, valid: 1'b1};
    #1; @(posedge clk); #1;
    // Extra up while saturated without down MUST clamp at 32 (not advance to 33)!
    mc_up_s = '{id: 4'd5, rw: 1'b0, valid: 1'b1};
    mc_dn_s = '0;
    #1; @(posedge clk); #1;
    // Single down MUST immediately step from 32 -> 31 (clearing stall_o while keeping to_miss_o==1)!
    mc_up_s = '{id: 4'd5, rw: 1'b0, valid: 1'b0};
    mc_dn_s = '{id: 4'd5, rw: 1'b0, valid: 1'b1};
    #1; @(posedge clk); #1;
    mc_dn_s = '0; #1;
    if (mc0_st_rtl || mc2_st_rtl || mc4_st_rtl || !mc0_tm_rtl || !mc2_tm_rtl || !mc4_tm_rtl) begin
      $display("FAIL Test1c_clamp: Single decrement from saturation did not transition to 31! st=(%b,%b,%b) tm=(%b,%b,%b)",
               mc0_st_rtl, mc2_st_rtl, mc4_st_rtl, mc0_tm_rtl, mc2_tm_rtl, mc4_tm_rtl);
      $finish(1);
    end
    // Drain remaining 31 + 1 extra underflow attempt -> must clamp cleanly at 0 (no underflow stall!)
    for (int k = 0; k < 32; k++) begin
      mc_dn_s = '{id: 4'd5, rw: 1'b0, valid: 1'b1};
      #1; @(posedge clk); #1;
    end
    mc_dn_s = '0; #1;
    if (mc0_st_rtl || mc2_st_rtl || mc4_st_rtl || mc0_tm_rtl || mc2_tm_rtl || mc4_tm_rtl) begin
      $display("FAIL Test1d_underflow: Counter underflowed below 0!"); $finish(1);
    end

    // 1e: Global Write Counter Saturation (128 writes across changing IDs so per-ID counters stay <= 8!)
    for (int k = 0; k < 128; k++) begin
      mc_up_s = '{id: id_t'(k[3:0]), rw: 1'b1, valid: 1'b1};
      mc_dn_s = '0;
      #1; @(posedge clk); #1;
    end
    // Probe with a brand-new unused ID? Wait: in mc4, each of 16 IDs got 8 writes; let's drain ID=4'd15 completely (8 downs as read-tagged? No, drain ID=15 with rw=0? Wait: rw=1 drains w_cnt too!).
    // Right now w_cnt == 128 (saturated -> stall[NoCounters]==1!). Drain ID=4'd3 8 times with rw=0? No, let's check ID=4'd0 with rw=1!
    // Even better: reset, push 8 writes on each of IDs 0..14 (120 writes) + 8 writes on ID 14 (total 16 on ID 14 = 128 writes, ID 15 has ZERO misses!).
    reset_all();
    for (int k = 0; k < 128; k++) begin
      mc_up_s = '{id: id_t'(k % 15), rw: 1'b1, valid: 1'b1};
      mc_dn_s = '0;
      #1; @(posedge clk); #1;
    end
    // Now ID=15 has q_miss[15]==0, while q_write is SATURATED at 128!
    // Probe ID=15 with rw=1 (write) vs rw=0 (read) on u_mc4:
    mc_up_s = '{id: 4'd15, rw: 1'b1, valid: 1'b0};
    mc_dn_s = '0;
    #1;
    if (!mc4_st_rtl || !mc4_tm_rtl) begin
      $display("FAIL Test1e_wsat: At 128 global writes, write to_miss_o or stall_o failed on ID=15! st=%b tm=%b",
               mc4_st_rtl, mc4_tm_rtl);
      $finish(1);
    end
    mc_up_s = '{id: 4'd15, rw: 1'b0, valid: 1'b0};
    #1;
    if (mc4_tm_rtl) begin
      $display("FAIL Test1e_read_indep: Read on clean ID=15 falsely routed to_miss_o due to global writes!");
      $finish(1);
    end

    // =========================================================================
    // Test 2: March-X Tag BIST Multi-Cycle Drain (Latency=4 > NumLines=2),
    //         Trailing RONEDOWN Index-0 Stuck-at-0 Detection, & Re-Trigger Reset!
    // =========================================================================
    reset_all();
    // 2a: Inject stuck-at-0 at index=0 on Way 2 ONLY (caught ONLY on the very last RONEDOWN drain beat!), with Latency=4 > NumLines=2!
    b_lat_cfg      = 4;
    b_sa0_idx0_way = 4'b0100;
    b_sa1_idx1_way = 4'b0000;
    b_start        = 1'b1;
    #1; @(posedge clk); #1;
    b_start        = 1'b0;
    cyc = 0;
    while (!b_eoc && cyc < 120) begin @(posedge clk); #1; cyc++; end
    if (!b_eoc || b_reso !== 4'b0100) begin
      $display("FAIL Test2a: Expected BIST eoc=1 and reso=0100 (RONEDOWN idx=0 drain under Latency=4), got eoc=%b reso=%b",
               b_eoc, b_reso);
      $finish(1);
    end

    // 2b: Re-trigger BIST with clean SRAM (Latency=2) -> eoc MUST clear during run and reso MUST reset to 4'b0000!
    b_lat_cfg      = 2;
    b_sa0_idx0_way = 4'b0000;
    b_sa1_idx1_way = 4'b0000;
    b_start        = 1'b1;
    #1; @(posedge clk); #1;
    b_start        = 1'b0;
    #1;
    if (b_eoc) begin
      $display("FAIL Test2b_eoc_clear: eoc_o stayed stuck at 1 after new BIST started!");
      $finish(1);
    end
    cyc = 0;
    while (!b_eoc && cyc < 120) begin @(posedge clk); #1; cyc++; end
    if (!b_eoc || b_reso !== 4'b0000) begin
      $display("FAIL Test2b_clean: Clean re-run BIST failed! eoc=%b reso=%b", b_eoc, b_reso);
      $finish(1);
    end

    // =========================================================================
    // Test 3: Full `axi_llc_hit_miss` Subsystem Co-Simulation (RTL + Synthesized Gate-Level!):
    //   - Wait for post-reset BIST completion (`bist_valid_o == 1`, `bist_res_o == 0`)
    //   - Cold miss -> refill allocation -> subsequent hit -> Bloom-lock stall -> unlock -> hit
    //   - SPM way isolation: locking that allocated way in `spm_lock_i` MUST prevent normal cache lookup from hitting or victimizing it!
    //   - Zero-cache-way error handling: setting `(spm_lock_i | flushed_i) == 4'b1111` MUST NOT deadlock; normal cache request must return `RESP_SLVERR`, `evict=0`, `refill=0`, `way_ind=4'b0001`, routed via `miss_valid_o` when an older miss is still in flight (`to_miss==1`) and `hit_valid_o` once `cnt_down` drains!
    // =========================================================================
    reset_all();
    cyc = 0;
    while (!bist_val_rtl && cyc < 200) begin @(posedge clk); #1; cyc++; end
    if (!bist_val_rtl || bist_res_rtl !== 4'b0000) begin
      $display("FAIL Test3_bist: Subsystem BIST failed! val=%b res=%b", bist_val_rtl, bist_res_rtl);
      $finish(1);
    end

    // 3a: Issue cold read miss to addr 0x0001_0010 (index=1, tag=0x400)
    desc_in_flat = pack_desc(4'd2, 32'h0001_0010, axi_pkg::RESP_OKAY, 1'b0, 1'b0, 4'b0000, 1'b0);
    hm_valid_i   = 1'b1;
    #1;
    while (!hm_ready_rtl) begin @(posedge clk); #1; end
    @(posedge clk); #1;
    hm_valid_i   = 1'b0;
    while (!miss_v_rtl) begin @(posedge clk); #1; end
    begin
      logic [3:0] alloc_way;
      logic       got_refill, got_evict;
      alloc_way  = desc_out_rtl[36:33];
      got_evict  = desc_out_rtl[32];
      got_refill = desc_out_rtl[5];
      if (!got_refill || got_evict || $countones(alloc_way) != 1) begin
        $display("FAIL Test3a: Expected cold miss refill=1 evict=0 onehot way, got way=%b refill=%b evict=%b",
                 alloc_way, got_refill, got_evict);
        $finish(1);
      end
      @(posedge clk); #1; // miss_valid_o & miss_ready_i handshakes (increments miss_counter & locks line!)

      // Release line lock and drain miss counter:
      r_unl_flat  = {2'd1, alloc_way};
      r_unl_req   = 1'b1;
      cnt_dn_flat = {4'd2, 1'b0, 1'b1};
      #1; @(posedge clk); #1;
      r_unl_req   = 1'b0;
      cnt_dn_flat = '0;
      repeat (3) @(posedge clk); #1;

      // 3b: Same address MUST now HIT on `alloc_way` (`hit_valid_o == 1`, `refill == 0`)!
      desc_in_flat = pack_desc(4'd2, 32'h0001_0010, axi_pkg::RESP_OKAY, 1'b0, 1'b0, 4'b0000, 1'b0);
      hm_valid_i   = 1'b1;
      #1;
      while (!hm_ready_rtl) begin @(posedge clk); #1; end
      @(posedge clk); #1;
      hm_valid_i   = 1'b0;
      while (!hit_v_rtl && !miss_v_rtl) begin @(posedge clk); #1; end
      if (!hit_v_rtl || desc_out_rtl[36:33] !== alloc_way || desc_out_rtl[5] !== 1'b0) begin
        $display("FAIL Test3b: Expected cache hit on alloc_way=%b! hv=%b mv=%b way=%b",
                 alloc_way, hit_v_rtl, miss_v_rtl, desc_out_rtl[36:33]);
        $finish(1);
      end
      @(posedge clk); #1;
      // Unlock line after hit:
      r_unl_flat = {2'd1, alloc_way};
      r_unl_req  = 1'b1;
      #1; @(posedge clk); #1;
      r_unl_req  = 1'b0;
      repeat (3) @(posedge clk); #1;

      // 3c: Lock `alloc_way` as SPM (`spm_lock_i = alloc_way`)!
      //     A normal cache lookup to 0x0001_0010 MUST NOT hit `alloc_way`; it MUST miss and allocate a DIFFERENT way!
      spm_lock_i   = alloc_way;
      desc_in_flat = pack_desc(4'd3, 32'h0001_0010, axi_pkg::RESP_OKAY, 1'b0, 1'b0, 4'b0000, 1'b0);
      hm_valid_i   = 1'b1;
      #1;
      while (!hm_ready_rtl) begin @(posedge clk); #1; end
      @(posedge clk); #1;
      hm_valid_i   = 1'b0;
      cyc = 0;
      while (!hit_v_rtl && !miss_v_rtl && cyc < 30) begin @(posedge clk); #1; cyc++; end
      if (!miss_v_rtl || (desc_out_rtl[36:33] & alloc_way) != 4'b0000 || !desc_out_rtl[5]) begin
        $display("FAIL Test3c: Normal lookup hit or allocated SPM-locked way! hv=%b mv=%b way=%b spm=%b",
                 hit_v_rtl, miss_v_rtl, desc_out_rtl[36:33], alloc_way);
        $finish(1);
      end
      begin
        logic [3:0] way2;
        way2 = desc_out_rtl[36:33];
        @(posedge clk); #1; // Note: leaves 1 miss in flight (`to_miss == 1`!), unlock `way2` ONLY (do NOT cnt_down yet!)
        r_unl_flat = {2'd1, way2};
        r_unl_req  = 1'b1;
        #1; @(posedge clk); #1;
        r_unl_req  = 1'b0;
        repeat (3) @(posedge clk); #1;

        // 3d: Also verify `flushed_i` excludes ways from victim allocation on misses!
        //     Lock 2 ways in spm_lock_i and 1 way in flushed_i so ONLY 1 way (`free_way`) remains!
        begin
          logic [3:0] free_way, flush_only_way;
          flush_only_way = 4'b0000;
          free_way       = 4'b0000;
          for (int w = 0; w < 4; w++) begin
            if (!alloc_way[w] && !way2[w]) begin
              if (flush_only_way == 4'b0000) flush_only_way = (4'b0001 << w);
              else                           free_way       = (4'b0001 << w);
            end
          end
          spm_lock_i = alloc_way | way2;
          flushed_i  = flush_only_way; // ONLY `free_way` is available!
          // Issue 4 misses to distinct tags -> ALL 4 MUST allocate `free_way` (never `flush_only_way`!)
          for (int t = 0; t < 4; t++) begin
            desc_in_flat = pack_desc(4'd4, 32'h0002_0020 + (t << 16), axi_pkg::RESP_OKAY, 1'b0, 1'b0, 4'b0000, 1'b0);
            hm_valid_i   = 1'b1;
            #1;
            while (!hm_ready_rtl) begin @(posedge clk); #1; end
            @(posedge clk); #1;
            hm_valid_i   = 1'b0;
            cyc = 0;
            while (!miss_v_rtl && cyc < 30) begin @(posedge clk); #1; cyc++; end
            if (!miss_v_rtl || desc_out_rtl[36:33] !== free_way) begin
              $display("FAIL Test3d: Victimizer picked flushed/SPM way %b instead of free_way %b!",
                       desc_out_rtl[36:33], free_way);
              $finish(1);
            end
            @(posedge clk); #1;
            r_unl_flat  = {2'd2, free_way};
            r_unl_req   = 1'b1;
            cnt_dn_flat = {4'd4, 1'b0, 1'b1};
            #1; @(posedge clk); #1;
            r_unl_req   = 1'b0;
            cnt_dn_flat = '0;
            repeat (3) @(posedge clk); #1;
          end
        end

        // 3e: Now set `(spm_lock_i | flushed_i) == 4'b1111` (2 ways SPM, 2 ways Flushed -> ZERO cache ways!).
        //     Remember 1 miss from Test3c is STILL in flight (`to_miss == 1` under AxiIdLookupBits=0)!
        //     Issue normal cache lookup -> MUST NOT deadlock, MUST steer to `miss_valid_o` (preserving order!)
        //     with `x_resp == RESP_SLVERR`, `evict == 0`, `refill == 0`, `way_ind == 4'b0001`!
        spm_lock_i   = 4'b0011;
        flushed_i    = 4'b1100;
        desc_in_flat = pack_desc(4'd6, 32'h0005_0000, axi_pkg::RESP_OKAY, 1'b0, 1'b0, 4'b0000, 1'b0);
        hm_valid_i   = 1'b1;
        #1;
        cyc = 0;
        while (!hm_ready_rtl && cyc < 20) begin @(posedge clk); #1; cyc++; end
        if (!hm_ready_rtl) begin $display("FAIL Test3e_1: Deadlocked accepting zero-way lookup!"); $finish(1); end
        @(posedge clk); #1;
        hm_valid_i   = 1'b0;
        cyc = 0;
        while (!hit_v_rtl && !miss_v_rtl && cyc < 20) begin @(posedge clk); #1; cyc++; end
        if (!miss_v_rtl ||
            axi_pkg::resp_t'(desc_out_rtl[41:40]) !== axi_pkg::RESP_SLVERR ||
            desc_out_rtl[36:33] !== 4'b0001 ||
            desc_out_rtl[32]    !== 1'b0    ||
            desc_out_rtl[5]     !== 1'b0) begin
          $display("FAIL Test3e_2: Zero-way lookup wrong output! hv=%b mv=%b resp=%b way=%b ev=%b rf=%b",
                   hit_v_rtl, miss_v_rtl, desc_out_rtl[41:40], desc_out_rtl[36:33], desc_out_rtl[32], desc_out_rtl[5]);
          $finish(1);
        end
        @(posedge clk); #1;
        // Unlock way 0 + drain BOTH in-flight miss counts (from 3c and 3e):
        r_unl_flat  = {2'd0, 4'b0001};
        r_unl_req   = 1'b1;
        cnt_dn_flat = {4'd6, 1'b0, 1'b1};
        #1; @(posedge clk); #1;
        r_unl_req   = 1'b0;
        @(posedge clk); #1; // 2nd cnt_down -> miss counter back to 0!
        cnt_dn_flat = '0;
        repeat (3) @(posedge clk); #1;

        // When miss counter is 0, zero-way lookup MUST steer to `hit_valid_o` with `RESP_SLVERR`!
        desc_in_flat = pack_desc(4'd7, 32'h0006_0030, axi_pkg::RESP_OKAY, 1'b0, 1'b0, 4'b0000, 1'b0);
        hm_valid_i   = 1'b1;
        #1;
        while (!hm_ready_rtl) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        hm_valid_i   = 1'b0;
        cyc = 0;
        while (!hit_v_rtl && !miss_v_rtl && cyc < 20) begin @(posedge clk); #1; cyc++; end
        if (!hit_v_rtl || axi_pkg::resp_t'(desc_out_rtl[41:40]) !== axi_pkg::RESP_SLVERR) begin
          $display("FAIL Test3e_3: Expected hit_valid_o with RESP_SLVERR when miss pipeline empty!");
          $finish(1);
        end
        @(posedge clk); #1;
        r_unl_flat = {2'd3, 4'b0001};
        r_unl_req  = 1'b1;
        #1; @(posedge clk); #1;
        r_unl_req  = 1'b0;
        repeat (3) @(posedge clk); #1;
      end
    end

    // =========================================================================
    // Test 4: Seeded Randomized Transaction Stress (RTL vs Synthesized Gate-Level Lockstep!)
    // =========================================================================
    reset_all();
    cyc = 0;
    while (!bist_val_rtl && cyc < 200) begin @(posedge clk); #1; cyc++; end
    begin
      int rng, inflight_misses;
      rng = seed * 1103515245 + 12345;
      inflight_misses = 0;
      for (int step = 0; step < 80; step++) begin
        id_t      rid;
        addr_t    raddr;
        logic     rrw, rspm;
        way_ind_t rway;
        rng   = rng * 1664525 + 1013904223;
        rid   = rng[19:16];
        rrw   = rng[20];
        rspm  = (rng[22:21] == 2'b00);
        rway  = 4'b0001 << rng[25:24];
        raddr = {16'h0000, 6'd0, rng[11:8], rng[5:4], 4'b0000};
        if (step % 15 == 14) begin
          spm_lock_i = 4'b0011;
          flushed_i  = 4'b1100;
        end else begin
          spm_lock_i = 4'b0001;
          flushed_i  = 4'b0000;
        end

        desc_in_flat = pack_desc(rid, raddr, axi_pkg::RESP_OKAY, rspm, rrw, rway, 1'b0);
        hm_valid_i   = 1'b1;
        #1;
        cyc = 0;
        while (!hm_ready_rtl && cyc < 40) begin @(posedge clk); #1; cyc++; end
        if (!hm_ready_rtl) begin $display("FAIL Test4_rdy at step %0d!", step); $finish(1); end
        @(posedge clk); #1;
        hm_valid_i   = 1'b0;
        cyc = 0;
        while (!hit_v_rtl && !miss_v_rtl && cyc < 40) begin @(posedge clk); #1; cyc++; end
        if (!hit_v_rtl && !miss_v_rtl) begin $display("FAIL Test4_out at step %0d!", step); $finish(1); end
        begin
          logic [1:0] out_idx;
          logic [3:0] out_way;
          logic       went_miss, out_rw;
          out_idx   = desc_out_rtl[47:46];
          out_way   = desc_out_rtl[36:33];
          out_rw    = desc_out_rtl[37];
          went_miss = miss_v_rtl;
          @(posedge clk); #1;
          if (went_miss) inflight_misses++;
          // Immediately unlock line; drain miss counter probabilistically or when >=3
          if (out_rw) begin w_unl_flat = {out_idx, out_way}; w_unl_req = 1'b1; end
          else        begin r_unl_flat = {out_idx, out_way}; r_unl_req = 1'b1; end
          if (inflight_misses > 0 && ((rng[7] == 1'b1) || (inflight_misses >= 3))) begin
            cnt_dn_flat = {rid, out_rw, 1'b1};
            inflight_misses--;
          end
          #1; @(posedge clk); #1;
          w_unl_req   = 1'b0;
          r_unl_req   = 1'b0;
          cnt_dn_flat = '0;
          repeat (2) @(posedge clk); #1;
        end
      end
    end

    $display("PASS seed=%0d", seed);
    $finish(0);
  end
endmodule
