// Testbench for OpenTitan ROM Controller Subsystem (ot_rom_ctrl_top)
// Pure port-level verification with cycle-accurate inline reference models (zero hierarchical references).

module ref_rom_ctrl_compare
  import prim_mubi_pkg::*;
  import prim_util_pkg::vbits;
#(
  parameter int NumWords = 8
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,
  input  logic                   start_i,
  output logic                   done_o,
  output mubi4_t                 good_o,
  input  logic [NumWords*32-1:0] digest_i,
  input  logic [NumWords*32-1:0] exp_digest_i,
  output logic                   alert_o
);
  localparam int AW = vbits(NumWords);
  localparam bit [AW-1:0] LastAddr = AW'(NumWords - 1);

  typedef enum logic [4:0] {
    Waiting  = 5'b00100,
    Checking = 5'b10010,
    Done     = 5'b11001
  } state_e;

  state_e state_q, state_d;
  logic [AW-1:0] addr_q;
  logic matches_q;
  logic fsm_alert;

  always_comb begin
    state_d = state_q;
    fsm_alert = 1'b0;
    unique case (state_q)
      Waiting:  if (start_i) state_d = Checking;
      Checking: if (addr_q == LastAddr) state_d = Done;
      Done:     ;
      default:  fsm_alert = 1'b1;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= Waiting;
      addr_q    <= '0;
      matches_q <= 1'b1;
    end else begin
      state_q <= state_d;
      if ((state_q == Checking) && (addr_q != LastAddr)) begin
        addr_q <= addr_q + AW'(1);
      end
      if (state_q == Checking) begin
        matches_q <= matches_q &&
                     (digest_i[{addr_q, 5'd31} -: 32] == exp_digest_i[{addr_q, 5'd31} -: 32]);
      end
    end
  end

  assign done_o  = (state_q == Done);
  prim_mubi4_sender u_ref_done_sender (
    .clk_i (clk_i),
    .rst_ni(rst_ni),
    .mubi_i(mubi4_bool_to_mubi(matches_q)),
    .mubi_o(good_o)
  );
  assign alert_o = fsm_alert |
                   (start_i && (state_q != Waiting)) |
                   ((state_q == Waiting) && (addr_q != '0)) |
                   ((state_q == Done) && (addr_q != LastAddr));
endmodule

module ref_rom_ctrl_mux
  import prim_mubi_pkg::*;
#(
  parameter int AW = 10,
  parameter int DW = 39
) (
  input  logic          clk_i,
  input  logic          rst_ni,
  input  mubi4_t        sel_bus_i,
  input  logic [AW-1:0] bus_rom_addr_i,
  input  logic [AW-1:0] bus_prince_addr_i,
  input  logic          bus_req_i,
  output logic          bus_gnt_o,
  output logic [DW-1:0] bus_rdata_o,
  output logic          bus_rvalid_o,
  input  logic [AW-1:0] chk_addr_i,
  input  logic          chk_req_i,
  output logic [DW-1:0] chk_rdata_o,
  output logic [AW-1:0] rom_rom_addr_o,
  output logic [AW-1:0] rom_prince_addr_o,
  output logic          rom_req_o,
  input  logic [DW-1:0] rom_scr_rdata_i,
  input  logic [DW-1:0] rom_clr_rdata_i,
  input  logic          rom_rvalid_i,
  output logic          alert_o
);
  mubi4_t sel_bus_q, sel_bus_qq;
  logic   alert_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sel_bus_q  <= MuBi4False;
      sel_bus_qq <= MuBi4False;
      alert_q    <= 1'b0;
    end else begin
      sel_bus_q  <= mubi4_or_hi(sel_bus_q, sel_bus_i);
      sel_bus_qq <= sel_bus_q;
      if (mubi4_test_invalid(sel_bus_i) ||
          mubi4_test_invalid(sel_bus_q) ||
          (mubi4_test_true_loose(sel_bus_q) & mubi4_test_false_loose(sel_bus_i)) ||
          (mubi4_test_true_loose(sel_bus_qq) & mubi4_test_false_loose(sel_bus_q))) begin
        alert_q <= 1'b1;
      end
    end
  end

  assign alert_o           = alert_q;
  assign bus_gnt_o         = mubi4_test_true_strict(sel_bus_i);
  assign bus_rdata_o       = rom_clr_rdata_i;
  assign bus_rvalid_o      = mubi4_test_true_strict(sel_bus_q) & rom_rvalid_i;
  assign chk_rdata_o       = rom_scr_rdata_i;
  assign rom_req_o         = mubi4_test_true_strict(sel_bus_i) ? bus_req_i         : chk_req_i;
  assign rom_rom_addr_o    = mubi4_test_true_strict(sel_bus_i) ? bus_rom_addr_i    : chk_addr_i;
  assign rom_prince_addr_o = mubi4_test_true_strict(sel_bus_i) ? bus_prince_addr_i : chk_addr_i;
endmodule

module ref_ot_rom_ctrl_top
  import prim_mubi_pkg::*;
  import prim_util_pkg::vbits;
  import rom_ctrl_pkg::*;
#(
  parameter int RomDepth = 1024,
  parameter int TopCount = 8,
  parameter int DW       = 39,
  localparam int AW      = vbits(RomDepth),
  localparam int TAW     = vbits(TopCount)
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  input  logic [TopCount*32-1:0]    digest_i,
  input  logic [TopCount*32-1:0]    exp_digest_i,
  output logic [TopCount*32-1:0]    digest_o,
  output logic                      digest_vld_o,
  output logic [31:0]               exp_digest_word_o,
  output logic                      exp_digest_vld_o,
  output logic [TAW-1:0]            exp_digest_idx_o,
  output pwrmgr_data_t              pwrmgr_data_o,
  output keymgr_data_t              keymgr_data_o,
  input  logic                      kmac_rom_rdy_i,
  output logic                      kmac_rom_vld_o,
  output logic                      kmac_rom_last_o,
  output logic [DW-1:0]             kmac_rom_data_o,
  input  logic                      kmac_done_i,
  input  logic [TopCount*32-1:0]    kmac_digest_i,
  input  logic                      kmac_err_i,
  input  logic [AW-1:0]             bus_rom_addr_i,
  input  logic [AW-1:0]             bus_prince_addr_i,
  input  logic                      bus_req_i,
  output logic                      bus_gnt_o,
  output logic [DW-1:0]             bus_rdata_o,
  output logic                      bus_rvalid_o,
  output logic [AW-1:0]             rom_rom_addr_o,
  output logic [AW-1:0]             rom_prince_addr_o,
  output logic                      rom_req_o,
  input  logic [DW-1:0]             rom_scr_rdata_i,
  input  logic [DW-1:0]             rom_clr_rdata_i,
  input  logic                      rom_rvalid_i,
  output logic                      alert_o
);
  localparam bit [AW-1:0] TopStartAddr = AW'(RomDepth - TopCount);

  logic          counter_done;
  logic [AW-1:0] counter_read_addr;
  logic          counter_read_req;
  logic [AW-1:0] counter_data_addr;
  logic          counter_data_rdy;
  logic          counter_lnt;

  rom_ctrl_counter #(
    .RomDepth   (RomDepth),
    .RomTopCount(TopCount)
  ) u_ref_cnt (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),
    .done_o            (counter_done),
    .read_addr_o       (counter_read_addr),
    .read_req_o        (counter_read_req),
    .data_addr_o       (counter_data_addr),
    .data_rdy_i        (counter_data_rdy),
    .data_last_nontop_o(counter_lnt)
  );

  logic   start_checker_q;
  logic   checker_done, checker_alert;
  mubi4_t checker_good;

  ref_rom_ctrl_compare #(
    .NumWords(TopCount)
  ) u_ref_cmp (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .start_i     (start_checker_q),
    .done_o      (checker_done),
    .good_o      (checker_good),
    .digest_i    (digest_i),
    .exp_digest_i(exp_digest_i),
    .alert_o     (checker_alert)
  );

  fsm_state_e state_d, state_q;
  logic       fsm_alert, fsm_alert_out, mux_alert_out;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= ReadingLow;
    else         state_q <= state_d;
  end

  always_comb begin
    state_d   = state_q;
    fsm_alert = 1'b0;
    unique case (state_q)
      ReadingLow: begin
        if (counter_lnt && kmac_rom_rdy_i) state_d = ReadingHigh;
      end
      ReadingHigh: begin
        unique case ({kmac_done_i, counter_done})
          2'b01: state_d = RomAhead;
          2'b10: state_d = kmac_err_i ? Invalid : KmacAhead;
          2'b11: state_d = kmac_err_i ? Invalid : Checking;
          default: ;
        endcase
      end
      RomAhead:  if (kmac_done_i)  state_d = kmac_err_i ? Invalid : Checking;
      KmacAhead: if (counter_done) state_d = Checking;
      Checking:  if (checker_done) state_d = Done;
      Done:      ;
      default: begin
        fsm_alert = 1'b1;
        state_d   = Invalid;
      end
    endcase

    if ((checker_done && !(state_q inside {Checking, Done})) ||
        (counter_done && state_q == ReadingLow) ||
        (kmac_done_i && !(state_q inside {ReadingHigh, RomAhead}))) begin
      state_d = Invalid;
    end
    if (fsm_alert_out) begin
      state_d = Invalid;
    end
  end

  logic [9:0] state_q_bits;
  assign state_q_bits = {state_q};
  mubi4_t in_state_done;
  assign in_state_done = mubi4_t'(state_q_bits[3:0]);

  assign digest_o          = kmac_digest_i;
  assign digest_vld_o      = kmac_done_i;
  assign exp_digest_word_o = kmac_rom_data_o[31:0];
  assign exp_digest_vld_o  = (state_q == ReadingHigh || state_q == KmacAhead) & ~counter_done;
  assign exp_digest_idx_o  = counter_data_addr[TAW-1:0] - TopStartAddr[TAW-1:0];
  assign pwrmgr_data_o     = '{done: in_state_done, good: checker_good};
  assign keymgr_data_o     = '{data: digest_i, valid: mubi4_test_true_loose(in_state_done)};

  logic kmac_rom_vld_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      kmac_rom_vld_q  <= 1'b0;
      start_checker_q <= 1'b0;
    end else begin
      if (counter_read_req && state_q == ReadingLow && !counter_lnt) kmac_rom_vld_q <= 1'b1;
      else if (kmac_rom_rdy_i) kmac_rom_vld_q <= 1'b0;
      start_checker_q <= (state_q != Checking) && (state_d == Checking);
    end
  end

  assign counter_data_rdy = kmac_rom_rdy_i | (state_q inside {ReadingHigh, KmacAhead});
  assign kmac_rom_vld_o   = kmac_rom_vld_q;
  assign kmac_rom_last_o  = counter_lnt;
  assign fsm_alert_out    = fsm_alert | checker_alert | (mubi4_test_true_loose(in_state_done) & !counter_done);

  ref_rom_ctrl_mux #(
    .AW(AW),
    .DW(DW)
  ) u_ref_mux (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .sel_bus_i        (in_state_done),
    .bus_rom_addr_i   (bus_rom_addr_i),
    .bus_prince_addr_i(bus_prince_addr_i),
    .bus_req_i        (bus_req_i),
    .bus_gnt_o        (bus_gnt_o),
    .bus_rdata_o      (bus_rdata_o),
    .bus_rvalid_o     (bus_rvalid_o),
    .chk_addr_i       (counter_read_addr),
    .chk_req_i        (counter_read_req),
    .chk_rdata_o      (kmac_rom_data_o),
    .rom_rom_addr_o   (rom_rom_addr_o),
    .rom_prince_addr_o(rom_prince_addr_o),
    .rom_req_o        (rom_req_o),
    .rom_scr_rdata_i  (rom_scr_rdata_i),
    .rom_clr_rdata_i  (rom_clr_rdata_i),
    .rom_rvalid_i     (rom_rvalid_i),
    .alert_o          (mux_alert_out)
  );

  assign alert_o = fsm_alert_out | mux_alert_out;
endmodule

module tb;
  import prim_mubi_pkg::*;
  import rom_ctrl_pkg::*;

  localparam int RomDepth = 1024;
  localparam int TopCount = 8;
  localparam int DW       = 39;
  localparam int AW       = 10;
  localparam int TAW      = 3;

  logic                   clk_i;
  logic                   rst_ni;
  logic [TopCount*32-1:0] digest_i;
  logic [TopCount*32-1:0] exp_digest_i;
  logic [TopCount*32-1:0] dut_digest_o, ref_digest_o;
  logic                   dut_digest_vld_o, ref_digest_vld_o;
  logic [31:0]            dut_exp_digest_word_o, ref_exp_digest_word_o;
  logic                   dut_exp_digest_vld_o, ref_exp_digest_vld_o;
  logic [TAW-1:0]         dut_exp_digest_idx_o, ref_exp_digest_idx_o;
  pwrmgr_data_t           dut_pwrmgr_data_o, ref_pwrmgr_data_o;
  keymgr_data_t           dut_keymgr_data_o, ref_keymgr_data_o;
  logic                   kmac_rom_rdy_i;
  logic                   dut_kmac_rom_vld_o, ref_kmac_rom_vld_o;
  logic                   dut_kmac_rom_last_o, ref_kmac_rom_last_o;
  logic [DW-1:0]          dut_kmac_rom_data_o, ref_kmac_rom_data_o;
  logic                   kmac_done_i;
  logic [TopCount*32-1:0] kmac_digest_i;
  logic                   kmac_err_i;
  logic [AW-1:0]          bus_rom_addr_i;
  logic [AW-1:0]          bus_prince_addr_i;
  logic                   bus_req_i;
  logic                   dut_bus_gnt_o, ref_bus_gnt_o;
  logic [DW-1:0]          dut_bus_rdata_o, ref_bus_rdata_o;
  logic                   dut_bus_rvalid_o, ref_bus_rvalid_o;
  logic [AW-1:0]          dut_rom_rom_addr_o, ref_rom_rom_addr_o;
  logic [AW-1:0]          dut_rom_prince_addr_o, ref_rom_prince_addr_o;
  logic                   dut_rom_req_o, ref_rom_req_o;
  logic [DW-1:0]          rom_scr_rdata_i;
  logic [DW-1:0]          rom_clr_rdata_i;
  logic                   rom_rvalid_i;
  logic                   dut_alert_o, ref_alert_o;

  // Standalone comparator & mux port-level verification signals
  logic                   cmp_rst_ni, cmp_start_i;
  logic [TopCount*32-1:0] cmp_digest_i, cmp_exp_digest_i;
  logic                   dut_cmp_done_o, ref_cmp_done_o;
  mubi4_t                 dut_cmp_good_o, ref_cmp_good_o;
  logic                   dut_cmp_alert_o, ref_cmp_alert_o;

  logic                   mux_rst_ni;
  mubi4_t                 mux_sel_bus_i;
  logic [AW-1:0]          mux_bus_rom_addr_i, mux_bus_prince_addr_i, mux_chk_addr_i;
  logic                   mux_bus_req_i, mux_chk_req_i, mux_rom_rvalid_i;
  logic [DW-1:0]          mux_rom_scr_rdata_i, mux_rom_clr_rdata_i;
  logic                   dut_mux_bus_gnt_o, ref_mux_bus_gnt_o;
  logic [DW-1:0]          dut_mux_bus_rdata_o, ref_mux_bus_rdata_o;
  logic                   dut_mux_bus_rvalid_o, ref_mux_bus_rvalid_o;
  logic [DW-1:0]          dut_mux_chk_rdata_o, ref_mux_chk_rdata_o;
  logic [AW-1:0]          dut_mux_rom_rom_addr_o, ref_mux_rom_rom_addr_o;
  logic [AW-1:0]          dut_mux_rom_prince_addr_o, ref_mux_rom_prince_addr_o;
  logic                   dut_mux_rom_req_o, ref_mux_rom_req_o;
  logic                   dut_mux_alert_o, ref_mux_alert_o;

  ot_rom_ctrl_top #(
    .RomDepth(RomDepth),
    .TopCount(TopCount),
    .DW      (DW)
  ) dut (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .digest_i         (digest_i),
    .exp_digest_i     (exp_digest_i),
    .digest_o         (dut_digest_o),
    .digest_vld_o     (dut_digest_vld_o),
    .exp_digest_word_o(dut_exp_digest_word_o),
    .exp_digest_vld_o (dut_exp_digest_vld_o),
    .exp_digest_idx_o (dut_exp_digest_idx_o),
    .pwrmgr_data_o    (dut_pwrmgr_data_o),
    .keymgr_data_o    (dut_keymgr_data_o),
    .kmac_rom_rdy_i   (kmac_rom_rdy_i),
    .kmac_rom_vld_o   (dut_kmac_rom_vld_o),
    .kmac_rom_last_o  (dut_kmac_rom_last_o),
    .kmac_rom_data_o  (dut_kmac_rom_data_o),
    .kmac_done_i      (kmac_done_i),
    .kmac_digest_i    (kmac_digest_i),
    .kmac_err_i       (kmac_err_i),
    .bus_rom_addr_i   (bus_rom_addr_i),
    .bus_prince_addr_i(bus_prince_addr_i),
    .bus_req_i        (bus_req_i),
    .bus_gnt_o        (dut_bus_gnt_o),
    .bus_rdata_o      (dut_bus_rdata_o),
    .bus_rvalid_o     (dut_bus_rvalid_o),
    .rom_rom_addr_o   (dut_rom_rom_addr_o),
    .rom_prince_addr_o(dut_rom_prince_addr_o),
    .rom_req_o        (dut_rom_req_o),
    .rom_scr_rdata_i  (rom_scr_rdata_i),
    .rom_clr_rdata_i  (rom_clr_rdata_i),
    .rom_rvalid_i     (rom_rvalid_i),
    .alert_o          (dut_alert_o)
  );

  ref_ot_rom_ctrl_top #(
    .RomDepth(RomDepth),
    .TopCount(TopCount),
    .DW      (DW)
  ) u_ref (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .digest_i         (digest_i),
    .exp_digest_i     (exp_digest_i),
    .digest_o         (ref_digest_o),
    .digest_vld_o     (ref_digest_vld_o),
    .exp_digest_word_o(ref_exp_digest_word_o),
    .exp_digest_vld_o (ref_exp_digest_vld_o),
    .exp_digest_idx_o (ref_exp_digest_idx_o),
    .pwrmgr_data_o    (ref_pwrmgr_data_o),
    .keymgr_data_o    (ref_keymgr_data_o),
    .kmac_rom_rdy_i   (kmac_rom_rdy_i),
    .kmac_rom_vld_o   (ref_kmac_rom_vld_o),
    .kmac_rom_last_o  (ref_kmac_rom_last_o),
    .kmac_rom_data_o  (ref_kmac_rom_data_o),
    .kmac_done_i      (kmac_done_i),
    .kmac_digest_i    (kmac_digest_i),
    .kmac_err_i       (kmac_err_i),
    .bus_rom_addr_i   (bus_rom_addr_i),
    .bus_prince_addr_i(bus_prince_addr_i),
    .bus_req_i        (bus_req_i),
    .bus_gnt_o        (ref_bus_gnt_o),
    .bus_rdata_o      (ref_bus_rdata_o),
    .bus_rvalid_o     (ref_bus_rvalid_o),
    .rom_rom_addr_o   (ref_rom_rom_addr_o),
    .rom_prince_addr_o(ref_rom_prince_addr_o),
    .rom_req_o        (ref_rom_req_o),
    .rom_scr_rdata_i  (rom_scr_rdata_i),
    .rom_clr_rdata_i  (rom_clr_rdata_i),
    .rom_rvalid_i     (rom_rvalid_i),
    .alert_o          (ref_alert_o)
  );

  rom_ctrl_compare #(
    .NumWords(TopCount)
  ) u_dut_cmp (
    .clk_i       (clk_i),
    .rst_ni      (cmp_rst_ni),
    .start_i     (cmp_start_i),
    .done_o      (dut_cmp_done_o),
    .good_o      (dut_cmp_good_o),
    .digest_i    (cmp_digest_i),
    .exp_digest_i(cmp_exp_digest_i),
    .alert_o     (dut_cmp_alert_o)
  );

  ref_rom_ctrl_compare #(
    .NumWords(TopCount)
  ) u_ref_cmp_unit (
    .clk_i       (clk_i),
    .rst_ni      (cmp_rst_ni),
    .start_i     (cmp_start_i),
    .done_o      (ref_cmp_done_o),
    .good_o      (ref_cmp_good_o),
    .digest_i    (cmp_digest_i),
    .exp_digest_i(cmp_exp_digest_i),
    .alert_o     (ref_cmp_alert_o)
  );

  rom_ctrl_mux #(
    .AW(AW),
    .DW(DW)
  ) u_dut_mux (
    .clk_i            (clk_i),
    .rst_ni           (mux_rst_ni),
    .sel_bus_i        (mux_sel_bus_i),
    .bus_rom_addr_i   (mux_bus_rom_addr_i),
    .bus_prince_addr_i(mux_bus_prince_addr_i),
    .bus_req_i        (mux_bus_req_i),
    .bus_gnt_o        (dut_mux_bus_gnt_o),
    .bus_rdata_o      (dut_mux_bus_rdata_o),
    .bus_rvalid_o     (dut_mux_bus_rvalid_o),
    .chk_addr_i       (mux_chk_addr_i),
    .chk_req_i        (mux_chk_req_i),
    .chk_rdata_o      (dut_mux_chk_rdata_o),
    .rom_rom_addr_o   (dut_mux_rom_rom_addr_o),
    .rom_prince_addr_o(dut_mux_rom_prince_addr_o),
    .rom_req_o        (dut_mux_rom_req_o),
    .rom_scr_rdata_i  (mux_rom_scr_rdata_i),
    .rom_clr_rdata_i  (mux_rom_clr_rdata_i),
    .rom_rvalid_i     (mux_rom_rvalid_i),
    .alert_o          (dut_mux_alert_o)
  );

  ref_rom_ctrl_mux #(
    .AW(AW),
    .DW(DW)
  ) u_ref_mux_unit (
    .clk_i            (clk_i),
    .rst_ni           (mux_rst_ni),
    .sel_bus_i        (mux_sel_bus_i),
    .bus_rom_addr_i   (mux_bus_rom_addr_i),
    .bus_prince_addr_i(mux_bus_prince_addr_i),
    .bus_req_i        (mux_bus_req_i),
    .bus_gnt_o        (ref_mux_bus_gnt_o),
    .bus_rdata_o      (ref_mux_bus_rdata_o),
    .bus_rvalid_o     (ref_mux_bus_rvalid_o),
    .chk_addr_i       (mux_chk_addr_i),
    .chk_req_i        (mux_chk_req_i),
    .chk_rdata_o      (ref_mux_chk_rdata_o),
    .rom_rom_addr_o   (ref_mux_rom_rom_addr_o),
    .rom_prince_addr_o(ref_mux_rom_prince_addr_o),
    .rom_req_o        (ref_mux_rom_req_o),
    .rom_scr_rdata_i  (mux_rom_scr_rdata_i),
    .rom_clr_rdata_i  (mux_rom_clr_rdata_i),
    .rom_rvalid_i     (mux_rom_rvalid_i),
    .alert_o          (ref_mux_alert_o)
  );

  int err_cnt = 0;
  int cyc_cnt = 0;

  initial clk_i = 1'b0;
  always #5 clk_i = ~clk_i;

  task automatic step();
    @(posedge clk_i);
    #1;
    cyc_cnt++;
    if (dut_digest_o          !== ref_digest_o          ||
        dut_digest_vld_o      !== ref_digest_vld_o      ||
        dut_exp_digest_word_o !== ref_exp_digest_word_o ||
        dut_exp_digest_vld_o  !== ref_exp_digest_vld_o  ||
        dut_exp_digest_idx_o  !== ref_exp_digest_idx_o  ||
        dut_pwrmgr_data_o.done !== ref_pwrmgr_data_o.done ||
        (dut_pwrmgr_data_o.done == MuBi4True && dut_pwrmgr_data_o.good !== ref_pwrmgr_data_o.good) ||
        dut_keymgr_data_o     !== ref_keymgr_data_o     ||
        dut_kmac_rom_vld_o    !== ref_kmac_rom_vld_o    ||
        dut_kmac_rom_last_o   !== ref_kmac_rom_last_o   ||
        dut_kmac_rom_data_o   !== ref_kmac_rom_data_o   ||
        dut_bus_gnt_o         !== ref_bus_gnt_o         ||
        dut_bus_rdata_o       !== ref_bus_rdata_o       ||
        dut_bus_rvalid_o      !== ref_bus_rvalid_o      ||
        dut_rom_rom_addr_o    !== ref_rom_rom_addr_o    ||
        dut_rom_prince_addr_o !== ref_rom_prince_addr_o ||
        dut_rom_req_o         !== ref_rom_req_o         ||
        dut_alert_o           !== ref_alert_o) begin
      if (err_cnt < 20) begin
        $display("TOP MISMATCH cyc=%0d alert=%b/%b pwrmgr=%h/%h keymgr_vld=%b/%b kmac_vld=%b/%b exp_vld=%b/%b idx=%0d/%0d gnt=%b/%b rvalid=%b/%b",
                 cyc_cnt, dut_alert_o, ref_alert_o,
                 dut_pwrmgr_data_o, ref_pwrmgr_data_o,
                 dut_keymgr_data_o.valid, ref_keymgr_data_o.valid,
                 dut_kmac_rom_vld_o, ref_kmac_rom_vld_o,
                 dut_exp_digest_vld_o, ref_exp_digest_vld_o,
                 dut_exp_digest_idx_o, ref_exp_digest_idx_o,
                 dut_bus_gnt_o, ref_bus_gnt_o,
                 dut_bus_rvalid_o, ref_bus_rvalid_o);
      end
      err_cnt++;
    end

    if (dut_cmp_done_o  !== ref_cmp_done_o ||
        dut_cmp_alert_o !== ref_cmp_alert_o) begin
      if (err_cnt < 20) begin
        $display("CMP MISMATCH cyc=%0d done=%b/%b good=%h/%h alert=%b/%b",
                 cyc_cnt, dut_cmp_done_o, ref_cmp_done_o,
                 dut_cmp_good_o, ref_cmp_good_o,
                 dut_cmp_alert_o, ref_cmp_alert_o);
      end
      err_cnt++;
    end

    if (dut_mux_bus_gnt_o         !== ref_mux_bus_gnt_o         ||
        dut_mux_bus_rdata_o       !== ref_mux_bus_rdata_o       ||
        dut_mux_bus_rvalid_o      !== ref_mux_bus_rvalid_o      ||
        dut_mux_chk_rdata_o       !== ref_mux_chk_rdata_o       ||
        dut_mux_rom_rom_addr_o    !== ref_mux_rom_rom_addr_o    ||
        dut_mux_rom_prince_addr_o !== ref_mux_rom_prince_addr_o ||
        dut_mux_rom_req_o         !== ref_mux_rom_req_o         ||
        dut_mux_alert_o           !== ref_mux_alert_o) begin
      if (err_cnt < 20) begin
        $display("MUX MISMATCH cyc=%0d gnt=%b/%b rvalid=%b/%b req=%b/%b alert=%b/%b",
                 cyc_cnt, dut_mux_bus_gnt_o, ref_mux_bus_gnt_o,
                 dut_mux_bus_rvalid_o, ref_mux_bus_rvalid_o,
                 dut_mux_rom_req_o, ref_mux_rom_req_o,
                 dut_mux_alert_o, ref_mux_alert_o);
      end
      err_cnt++;
    end
  endtask

  // Automatically latch digest_o and exp_digest_word_o the same way rom_ctrl does
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      digest_i     <= '0;
      exp_digest_i <= '0;
    end else begin
      if (dut_digest_vld_o) begin
        digest_i <= dut_digest_o;
      end
      if (dut_exp_digest_vld_o) begin
        exp_digest_i[dut_exp_digest_idx_o * 32 +: 32] <= dut_exp_digest_word_o;
      end
    end
  end

  // Simple 1-cycle ROM model driven by dut_rom_req_o and dut_rom_rom_addr_o
  logic [255:0] rom_top_digest;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rom_rvalid_i    <= 1'b0;
      rom_scr_rdata_i <= '0;
      rom_clr_rdata_i <= '0;
    end else begin
      rom_rvalid_i <= dut_rom_req_o;
      if (dut_rom_req_o) begin
        if (dut_rom_rom_addr_o >= 10'd1016) begin
          logic [2:0] top_idx;
          top_idx = dut_rom_rom_addr_o[2:0];
          rom_scr_rdata_i <= {7'h2A, rom_top_digest[top_idx * 32 +: 32]};
        end else begin
          rom_scr_rdata_i <= {7'h15, 22'h12345, dut_rom_rom_addr_o};
        end
        rom_clr_rdata_i <= {7'h3C, 12'hABC, dut_rom_prince_addr_o, dut_rom_rom_addr_o};
      end
    end
  end

  task automatic reset_top();
    rst_ni            = 1'b0;
    kmac_rom_rdy_i    = 1'b0;
    kmac_done_i       = 1'b0;
    kmac_digest_i     = '0;
    kmac_err_i        = 1'b0;
    bus_rom_addr_i    = '0;
    bus_prince_addr_i = '0;
    bus_req_i         = 1'b0;
    step();
    step();
    rst_ni = 1'b1;
    step();
  endtask

  initial begin
    cmp_rst_ni            = 1'b0;
    cmp_start_i           = 1'b0;
    cmp_digest_i          = '0;
    cmp_exp_digest_i      = '0;
    mux_rst_ni            = 1'b0;
    mux_sel_bus_i         = MuBi4False;
    mux_bus_rom_addr_i    = '0;
    mux_bus_prince_addr_i = '0;
    mux_bus_req_i         = 1'b0;
    mux_chk_addr_i        = '0;
    mux_chk_req_i         = 1'b0;
    mux_rom_scr_rdata_i   = '0;
    mux_rom_clr_rdata_i   = '0;
    mux_rom_rvalid_i      = 1'b0;
    rom_top_digest        = 256'hFEDCBA98_76543210_CAFEBABE_DEADBEEF_01234567_89ABCDEF_13579BDF_2468ACE0;

    reset_top();
    cmp_rst_ni = 1'b1;
    mux_rst_ni = 1'b1;
    step();

    // ----------------------------------------------------------------------
    // Test 1: Standalone comparator & mux protocol/alert checks
    // ----------------------------------------------------------------------
    // 1a: Comparator matching digest + re-start alert check during Checking and Done
    cmp_digest_i     = rom_top_digest;
    cmp_exp_digest_i = rom_top_digest;
    cmp_start_i      = 1'b1;
    step();
    cmp_start_i      = 1'b0;
    repeat (3) step();
    // Assert start_i while in Checking -> must assert alert_o
    cmp_start_i      = 1'b1;
    step();
    if (dut_cmp_alert_o !== 1'b1) begin
      $display("FAIL: comparator start_alert did not assert during Checking");
      err_cnt++;
    end
    cmp_start_i      = 1'b0;
    repeat (6) step();
    if (dut_cmp_done_o !== 1'b1 || dut_cmp_good_o !== MuBi4True) begin
      $display("FAIL: comparator did not finish with good_o=MuBi4True");
      err_cnt++;
    end
    // Assert start_i while in Done -> must assert alert_o
    cmp_start_i      = 1'b1;
    step();
    if (dut_cmp_alert_o !== 1'b1) begin
      $display("FAIL: comparator start_alert did not assert during Done");
      err_cnt++;
    end
    cmp_start_i      = 1'b0;
    step();

    // 1b: Test comparator single-bit mismatch in every word position w = 0..7
    for (int w = 0; w < TopCount; w++) begin
      logic [255:0] mask;
      cmp_rst_ni = 1'b0;
      step();
      cmp_rst_ni       = 1'b1;
      mask             = '0;
      mask[w*32 +: 32] = 32'h0000_0001 << (w * 3);
      cmp_digest_i     = rom_top_digest;
      cmp_exp_digest_i = rom_top_digest ^ mask;
      cmp_start_i      = 1'b1;
      step();
      cmp_start_i      = 1'b0;
      repeat (10) step();
      if (dut_cmp_done_o !== 1'b1 || dut_cmp_good_o !== MuBi4False || dut_cmp_alert_o !== 1'b0) begin
        $display("FAIL: comparator word %0d mismatch not detected", w);
        err_cnt++;
      end
    end

    // 1c: Standalone mux switching, data routing, and sel_reverted / sel_invalid alerts
    mux_rst_ni            = 1'b0;
    step();
    mux_rst_ni            = 1'b1;
    mux_sel_bus_i         = MuBi4False;
    mux_chk_addr_i        = 10'h155;
    mux_chk_req_i         = 1'b1;
    mux_bus_rom_addr_i    = 10'h2AA;
    mux_bus_prince_addr_i = 10'h333;
    mux_bus_req_i         = 1'b1;
    mux_rom_scr_rdata_i   = 39'h55_AAAA_5555;
    mux_rom_clr_rdata_i   = 39'h2A_1234_5678;
    mux_rom_rvalid_i      = 1'b1;
    step();
    // Switch mux to bus (MuBi4True)
    mux_sel_bus_i         = MuBi4True;
    step();
    step();
    if (dut_mux_alert_o !== 1'b0 || dut_mux_bus_gnt_o !== 1'b1 || dut_mux_bus_rvalid_o !== 1'b1) begin
      $display("FAIL: mux normal bus switch failed");
      err_cnt++;
    end
    // Revert sel_bus_i from MuBi4True to MuBi4False -> must trigger sel_reverted alert!
    mux_sel_bus_i         = MuBi4False;
    step();
    step();
    if (dut_mux_alert_o !== 1'b1) begin
      $display("FAIL: mux sel_reverted alert did not assert when sel_bus_i reverted to MuBi4False");
      err_cnt++;
    end
    // Reset mux and test invalid MuBi4 value
    mux_rst_ni    = 1'b0;
    mux_sel_bus_i = MuBi4False;
    step();
    mux_rst_ni    = 1'b1;
    step();
    mux_sel_bus_i = mubi4_t'(4'b0000);
    step();
    step();
    if (dut_mux_alert_o !== 1'b1) begin
      $display("FAIL: mux sel_invalid alert did not assert");
      err_cnt++;
    end
    mux_rst_ni    = 1'b0;
    mux_sel_bus_i = MuBi4False;
    step();
    mux_rst_ni    = 1'b1;
    step();

    // ----------------------------------------------------------------------
    // Test 2: Full Subsystem Boot — RomAhead path (matching digest) + Bus access
    // ----------------------------------------------------------------------
    reset_top();
    for (int i = 0; i < 1500; i++) begin
      kmac_rom_rdy_i = ((i % 7) != 3);
      if (dut_kmac_rom_vld_o && dut_kmac_rom_last_o && kmac_rom_rdy_i) begin
        step();
        break;
      end
      step();
    end
    kmac_rom_rdy_i = 1'b1;
    // Wait for all 8 top words to be read into exp_digest_i (RomAhead state)
    repeat (12) step();
    // Now deliver matching KMAC digest
    kmac_digest_i = rom_top_digest;
    kmac_err_i    = 1'b0;
    kmac_done_i   = 1'b1;
    step();
    kmac_done_i   = 1'b0;
    // Wait for Checking (8 cycles) -> Done
    repeat (12) step();
    if (dut_pwrmgr_data_o.done !== MuBi4True ||
        dut_pwrmgr_data_o.good !== MuBi4True ||
        dut_keymgr_data_o.valid !== 1'b1 ||
        dut_keymgr_data_o.data !== rom_top_digest ||
        dut_bus_gnt_o !== 1'b1 ||
        dut_alert_o !== 1'b0) begin
      $display("FAIL: Test 2 RomAhead good boot failed");
      err_cnt++;
    end
    // Perform bus accesses in Done state
    for (int b = 0; b < 8; b++) begin
      bus_req_i         = (b[0] == 1'b0);
      bus_rom_addr_i    = 10'(b * 19 + 5);
      bus_prince_addr_i = 10'(b * 31 + 7);
      step();
    end
    bus_req_i = 1'b0;
    step();

    // ----------------------------------------------------------------------
    // Test 3: Full Subsystem Boot — KmacAhead path (mismatching digest)
    // ----------------------------------------------------------------------
    reset_top();
    kmac_rom_rdy_i = 1'b1;
    while (!(dut_kmac_rom_vld_o && dut_kmac_rom_last_o && kmac_rom_rdy_i)) begin
      step();
    end
    step();
    // Now in ReadingHigh; wait 2 cycles then assert kmac_done_i before counter_done
    repeat (2) step();
    kmac_digest_i = rom_top_digest ^ 256'h00000000_80000000_00000000_00000000;
    kmac_err_i    = 1'b0;
    kmac_done_i   = 1'b1;
    step();
    kmac_done_i   = 1'b0;
    repeat (20) step();
    if (dut_pwrmgr_data_o.done !== MuBi4True ||
        dut_pwrmgr_data_o.good !== MuBi4False ||
        dut_alert_o !== 1'b0) begin
      $display("FAIL: Test 3 KmacAhead mismatch boot failed");
      err_cnt++;
    end

    // ----------------------------------------------------------------------
    // Test 4: Simultaneous kmac_done_i & counter_done in ReadingHigh (2'b11)
    // ----------------------------------------------------------------------
    reset_top();
    kmac_rom_rdy_i = 1'b1;
    while (!(dut_kmac_rom_vld_o && dut_kmac_rom_last_o && kmac_rom_rdy_i)) begin
      step();
    end
    step();
    // In ReadingHigh, wait until the 8th top word (exp_digest_idx_o == 7)
    while (!(dut_exp_digest_vld_o && dut_exp_digest_idx_o == 3'd7)) begin
      step();
    end
    step();
    // Now counter_done is 1 in ReadingHigh; assert kmac_done_i simultaneously!
    kmac_digest_i = rom_top_digest;
    kmac_err_i    = 1'b0;
    kmac_done_i   = 1'b1;
    step();
    kmac_done_i   = 1'b0;
    repeat (12) step();
    if (dut_pwrmgr_data_o.done !== MuBi4True ||
        dut_pwrmgr_data_o.good !== MuBi4True ||
        dut_alert_o !== 1'b0) begin
      $display("FAIL: Test 4 simultaneous ReadingHigh 2'b11 boot failed");
      err_cnt++;
    end

    // ----------------------------------------------------------------------
    // Test 5: kmac_err_i during ReadingHigh (2'b10) -> must enter Invalid and alert!
    // ----------------------------------------------------------------------
    reset_top();
    kmac_rom_rdy_i = 1'b1;
    while (!(dut_kmac_rom_vld_o && dut_kmac_rom_last_o && kmac_rom_rdy_i)) begin
      step();
    end
    step();
    repeat (2) step();
    kmac_digest_i = rom_top_digest;
    kmac_err_i    = 1'b1;
    kmac_done_i   = 1'b1;
    step();
    kmac_done_i   = 1'b0;
    kmac_err_i    = 1'b0;
    step();
    if (dut_alert_o !== 1'b1 || dut_pwrmgr_data_o.done === MuBi4True) begin
      $display("FAIL: Test 5 kmac_err_i in ReadingHigh (2'b10) did not trigger alert");
      err_cnt++;
    end

    // ----------------------------------------------------------------------
    // Test 6: kmac_err_i during ReadingHigh simultaneous with counter_done (2'b11)
    // ----------------------------------------------------------------------
    reset_top();
    kmac_rom_rdy_i = 1'b1;
    while (!(dut_kmac_rom_vld_o && dut_kmac_rom_last_o && kmac_rom_rdy_i)) begin
      step();
    end
    step();
    while (!(dut_exp_digest_vld_o && dut_exp_digest_idx_o == 3'd7)) begin
      step();
    end
    step();
    kmac_digest_i = rom_top_digest;
    kmac_err_i    = 1'b1;
    kmac_done_i   = 1'b1;
    step();
    kmac_done_i   = 1'b0;
    kmac_err_i    = 1'b0;
    step();
    if (dut_alert_o !== 1'b1 || dut_pwrmgr_data_o.done === MuBi4True) begin
      $display("FAIL: Test 6 kmac_err_i in ReadingHigh (2'b11) did not trigger alert");
      err_cnt++;
    end

    // ----------------------------------------------------------------------
    // Test 7: kmac_err_i during RomAhead -> must enter Invalid and alert!
    // ----------------------------------------------------------------------
    reset_top();
    kmac_rom_rdy_i = 1'b1;
    while (!(dut_kmac_rom_vld_o && dut_kmac_rom_last_o && kmac_rom_rdy_i)) begin
      step();
    end
    step();
    repeat (12) step();
    kmac_digest_i = rom_top_digest;
    kmac_err_i    = 1'b1;
    kmac_done_i   = 1'b1;
    step();
    kmac_done_i   = 1'b0;
    kmac_err_i    = 1'b0;
    step();
    if (dut_alert_o !== 1'b1) begin
      $display("FAIL: Test 7 kmac_err_i in RomAhead did not trigger alert");
      err_cnt++;
    end

    // ----------------------------------------------------------------------
    // Test 8: Early kmac_done_i during ReadingLow -> must enter Invalid and alert!
    // ----------------------------------------------------------------------
    reset_top();
    kmac_rom_rdy_i = 1'b1;
    repeat (20) step();
    kmac_done_i = 1'b1;
    step();
    kmac_done_i = 1'b0;
    step();
    if (dut_alert_o !== 1'b1) begin
      $display("FAIL: Test 8 early kmac_done_i in ReadingLow did not trigger alert");
      err_cnt++;
    end

    if (err_cnt == 0) begin
      $display("PASS: All ot_rom_ctrl_top verification checks succeeded (%0d cycles).", cyc_cnt);
      $finish;
    end else begin
      $display("FAIL: %0d mismatches detected.", err_cnt);
      $fatal(1, "Verification failed");
    end
  end
endmodule
