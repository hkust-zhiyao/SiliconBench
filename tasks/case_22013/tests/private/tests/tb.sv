`timescale 1ns/1ps

module tb;
  import ara_pkg::*;
  import rvv_pkg::*;
  import axi_pkg::*;
  import cf_math_pkg::idx_width;

  localparam int unsigned NrLanes      = 4;
  localparam int unsigned VLEN         = 4096;
  localparam int unsigned VLENB        = VLEN / 8;
  localparam int unsigned AxiAddrWidth = 64;
  localparam int unsigned DataWidth    = $bits(elen_t);
  localparam int unsigned StrbWidth    = DataWidth / 8;
  localparam int unsigned MaxVLenBPerLane = VLENB / NrLanes;
  localparam int unsigned VRFBSizePerLane = MaxVLenBPerLane * 32;
  localparam int unsigned VRFWordsPerReg  = MaxVLenBPerLane / 8; // 16 words/reg/lane
  localparam int unsigned TotalVRFWords   = 32 * VRFWordsPerReg; // 512 words/lane
  localparam int unsigned MEM_BYTES       = 65536;               // 64 KiB test RAM

  typedef logic [StrbWidth-1:0]               strb_t;
  typedef logic [$clog2(VLEN+1)-1:0]          vlen_t;
  typedef logic [idx_width(VRFBSizePerLane)-1:0] vaddr_t;

  localparam config_pkg::cva6_cfg_t CVA6AraConfig =
    build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);

  typedef struct packed {
    logic [63:0] cause;
    logic [63:0] tval;
    logic [63:0] tval2;
    logic [31:0] tinst;
    logic        gva;
    logic        valid;
  } exception_t;

  `include "ara/ara_typedef.svh"
  `include "axi/typedef.svh"

  // Clock and reset
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #2.5 clk = ~clk;

  int unsigned seed = 32'd101;
  int unsigned err_cnt = 0;

  initial begin
    void'($value$plusargs("seed=%d", seed));
  end

  function automatic logic [31:0] next_rng(inout logic [31:0] s);
    s = s ^ (s << 13);
    s = s ^ (s >> 17);
    s = s ^ (s << 5);
    if (s == 32'd0) s = 32'h9E37_79B9;
    return s;
  endfunction

  // =========================================================================
  // Parameterized VLSU + AXI4 Protocol-Checking Slave + Lane/VRF Subsystem
  // =========================================================================
  // We encapsulate an entire VLSU environment in a generate block for both
  // AxiDataWidth = 128 (inst 0) and AxiDataWidth = 64 (inst 1).
  genvar gi;
  generate
    for (gi = 0; gi < 2; gi++) begin : gen_env
      localparam int unsigned AxiDW = (gi == 0) ? 128 : 64;
      localparam int unsigned AxiSW = AxiDW / 8;

      typedef logic [AxiAddrWidth-1:0] axi_addr_t;
      typedef logic [AxiDW-1:0]        axi_data_t;
      typedef logic [AxiSW-1:0]        axi_strb_t;
      typedef logic [0:0]              axi_id_t;
      typedef logic [0:0]              axi_user_t;

      `AXI_TYPEDEF_ALL(tb_axi, axi_addr_t, axi_id_t, axi_data_t, axi_strb_t, axi_user_t)

      tb_axi_req_t        axi_req;
      tb_axi_resp_t       axi_resp;
      logic               core_st_pending;
      logic               load_complete;
      logic               store_complete;
      logic               store_pending;
      pe_req_t            pe_req;
      logic               pe_req_valid;
      logic [NrVInsn-1:0] pe_vinsn_running;
      logic [1:0]         pe_req_ready;
      pe_resp_t [1:0]     pe_resp;
      logic               addrgen_ack;
      exception_t         addrgen_exception;
      vlen_t              addrgen_exception_vstart;
      logic               addrgen_fof_exception;
      logic               lsu_current_burst_exception;

      elen_t [NrLanes-1:0] stu_operand;
      logic  [NrLanes-1:0] stu_operand_valid;
      logic  [NrLanes-1:0] stu_operand_ready;

      elen_t [NrLanes-1:0] addrgen_operand;
      logic  [NrLanes-1:0] addrgen_operand_valid;
      logic                addrgen_operand_ready;

      logic                lsu_ex_flush;
      logic                lsu_ex_flush_done;

      strb_t [NrLanes-1:0] mask_in;
      logic  [NrLanes-1:0] mask_valid;
      logic                vldu_mask_ready;
      logic                vstu_mask_ready;

      logic [NrLanes-1:0]  ldu_result_req;
      vid_t [NrLanes-1:0]  ldu_result_id;
      vaddr_t [NrLanes-1:0] ldu_result_addr;
      elen_t [NrLanes-1:0] ldu_result_wdata;
      strb_t [NrLanes-1:0] ldu_result_be;
      logic [NrLanes-1:0]  ldu_result_gnt;
      logic [NrLanes-1:0]  ldu_result_final_gnt;

      logic                mmu_misaligned_ex, mmu_req, mmu_is_store;
      logic [CVA6AraConfig.VLEN-1:0] mmu_vaddr;

      vlsu #(
        .NrLanes     (NrLanes          ),
        .VLEN        (VLEN             ),
        .vaddr_t     (vaddr_t          ),
        .pe_req_t    (pe_req_t         ),
        .pe_resp_t   (pe_resp_t        ),
        .CVA6Cfg     (CVA6AraConfig    ),
        .exception_t (exception_t      ),
        .AxiDataWidth(AxiDW            ),
        .AxiAddrWidth(AxiAddrWidth     ),
        .axi_ar_t    (tb_axi_ar_chan_t ),
        .axi_r_t     (tb_axi_r_chan_t  ),
        .axi_aw_t    (tb_axi_aw_chan_t ),
        .axi_w_t     (tb_axi_w_chan_t  ),
        .axi_b_t     (tb_axi_b_chan_t  ),
        .axi_req_t   (tb_axi_req_t     ),
        .axi_resp_t  (tb_axi_resp_t    )
      ) dut (
        .clk_i                        (clk                        ),
        .rst_ni                       (rst_n                      ),
        .axi_req_o                    (axi_req                    ),
        .axi_resp_i                   (axi_resp                   ),
        .core_st_pending_i            (core_st_pending            ),
        .load_complete_o              (load_complete              ),
        .store_complete_o             (store_complete             ),
        .store_pending_o              (store_pending              ),
        .pe_req_i                     (pe_req                     ),
        .pe_req_valid_i               (pe_req_valid               ),
        .pe_vinsn_running_i           (pe_vinsn_running           ),
        .pe_req_ready_o               (pe_req_ready               ),
        .pe_resp_o                    (pe_resp                    ),
        .addrgen_ack_o                (addrgen_ack                ),
        .addrgen_exception_o          (addrgen_exception          ),
        .addrgen_exception_vstart_o   (addrgen_exception_vstart   ),
        .addrgen_fof_exception_o      (addrgen_fof_exception      ),
        .lsu_current_burst_exception_o(lsu_current_burst_exception),
        .stu_operand_i                (stu_operand                ),
        .stu_operand_valid_i          (stu_operand_valid          ),
        .stu_operand_ready_o          (stu_operand_ready          ),
        .addrgen_operand_i            (addrgen_operand            ),
        .addrgen_operand_valid_i      (addrgen_operand_valid      ),
        .addrgen_operand_ready_o      (addrgen_operand_ready      ),
        .lsu_ex_flush_i               (lsu_ex_flush               ),
        .lsu_ex_flush_done_o          (lsu_ex_flush_done          ),
        .mask_i                       (mask_in                    ),
        .mask_valid_i                 (mask_valid                 ),
        .vldu_mask_ready_o            (vldu_mask_ready            ),
        .vstu_mask_ready_o            (vstu_mask_ready            ),
        .en_ld_st_translation_i       (1'b0                       ),
        .mmu_misaligned_ex_o          (mmu_misaligned_ex          ),
        .mmu_req_o                    (mmu_req                    ),
        .mmu_vaddr_o                  (mmu_vaddr                  ),
        .mmu_is_store_o               (mmu_is_store               ),
        .mmu_dtlb_hit_i               (1'b0                       ),
        .mmu_dtlb_ppn_i               ('0                         ),
        .mmu_valid_i                  (1'b0                       ),
        .mmu_paddr_i                  ('0                         ),
        .mmu_exception_i              ('0                         ),
        .ldu_result_req_o             (ldu_result_req             ),
        .ldu_result_id_o              (ldu_result_id              ),
        .ldu_result_addr_o            (ldu_result_addr            ),
        .ldu_result_wdata_o           (ldu_result_wdata           ),
        .ldu_result_be_o              (ldu_result_be              ),
        .ldu_result_gnt_i             (ldu_result_gnt             ),
        .ldu_result_final_gnt_i       (ldu_result_final_gnt       )
      );

      // Backing RAM & Architectural VRF per lane (shuffled representation)
      byte unsigned mem [0:MEM_BYTES-1];
      byte unsigned ref_mem [0:MEM_BYTES-1];
      elen_t vrf [0:NrLanes-1][0:TotalVRFWords-1];
      elen_t ref_vrf [0:NrLanes-1][0:TotalVRFWords-1];

      // Configurable AXI timing knobs
      int unsigned cfg_b_delay  = 4;
      int unsigned cfg_ar_delay = 2;
      bit          cfg_bp_enable = 1'b1;
      logic [31:0] env_rng;

      // AXI Read pipeline queues
      typedef struct {
        axi_addr_t addr;
        axi_pkg::len_t len;
        axi_pkg::size_t size;
        int unsigned ready_cycle;
      } ar_cmd_t;

      typedef struct {
        axi_data_t data;
        logic      last;
      } r_beat_t;

      ar_cmd_t ar_q[$];
      r_beat_t r_q[$];

      // AXI Write pipeline queues (write commits to mem[] when B delay expires!)
      typedef struct {
        axi_addr_t addr;
        axi_pkg::len_t len;
        axi_pkg::size_t size;
      } aw_cmd_t;

      typedef struct {
        axi_data_t data;
        axi_strb_t strb;
        logic      last;
      } w_beat_t;

      typedef struct {
        axi_addr_t addr;
        axi_pkg::len_t len;
        axi_pkg::size_t size;
        w_beat_t beats[$];
        int unsigned commit_cycle;
      } pending_write_t;

      aw_cmd_t aw_q[$];
      w_beat_t w_q[$];
      pending_write_t wr_commit_q[$];
      int unsigned b_ready_q[$];

      // Lane operand & mask FIFO queues fed by the test driver
      elen_t stu_op_q [0:NrLanes-1][$];
      elen_t ag_op_q  [0:NrLanes-1][$];
      strb_t ldu_msk_q[0:NrLanes-1][$];
      strb_t stu_msk_q[0:NrLanes-1][$];
      bit    cur_mask_for_load;

      int unsigned cycle_cnt = 0;
      logic [NrLanes-1:0] pending_final_gnt_d1;

      // Track instruction completions
      int unsigned insn_done_Load_cnt [0:NrVInsn-1];
      int unsigned insn_done_Store_cnt[0:NrVInsn-1];
      bit          local_reset;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || local_reset) begin
          cycle_cnt    <= 0;
          axi_resp     <= '0;
          ldu_result_gnt <= '0;
          ldu_result_final_gnt <= '0;
          pending_final_gnt_d1 <= '0;
          stu_operand  <= '0;
          stu_operand_valid <= '0;
          addrgen_operand <= '0;
          addrgen_operand_valid <= '0;
          mask_in      <= '0;
          mask_valid   <= '0;
          ar_q.delete();
          r_q.delete();
          aw_q.delete();
          w_q.delete();
          wr_commit_q.delete();
          b_ready_q.delete();
          for (int i = 0; i < NrVInsn; i++) begin
            insn_done_Load_cnt[i]  <= 0;
            insn_done_Store_cnt[i] <= 0;
          end
        end else begin
          automatic logic [31:0] rv = next_rng(env_rng);
          cycle_cnt <= cycle_cnt + 1;

          // Monitor completion pulses and store_pending invariant
          for (int i = 0; i < NrVInsn; i++) begin
            if (pe_resp[OffsetLoad].vinsn_done[i]) begin
              insn_done_Load_cnt[i] <= insn_done_Load_cnt[i] + 1;
            end
            if (pe_resp[OffsetStore].vinsn_done[i]) begin
              insn_done_Store_cnt[i] <= insn_done_Store_cnt[i] + 1;
            end
          end

          // -----------------------------------------------------------------
          // 1. AXI4 AR handshake + 4KB boundary protocol check
          // -----------------------------------------------------------------
          if (axi_req.ar_valid && axi_resp.ar_ready) begin
            automatic axi_addr_t al_start = (axi_req.ar.addr >> axi_req.ar.size) << axi_req.ar.size;
            automatic axi_addr_t end_byte = al_start + ((axi_addr_t'(axi_req.ar.len) + 1) << axi_req.ar.size) - 1;
            if (axi_req.ar.addr[63:12] != end_byte[63:12]) begin
              $display("[ERR][DW%0d] AXI AR 4KB boundary crossing: addr=0x%h len=%0d size=%0d end=0x%h",
                       AxiDW, axi_req.ar.addr, axi_req.ar.len, axi_req.ar.size, end_byte);
              err_cnt++;
            end
            if ((1 << axi_req.ar.size) > AxiSW) begin
              $display("[ERR][DW%0d] AXI ARSIZE=%0d exceeds bus width", AxiDW, axi_req.ar.size);
              err_cnt++;
            end
            ar_q.push_back('{
              addr: axi_req.ar.addr,
              len:  axi_req.ar.len,
              size: axi_req.ar.size,
              ready_cycle: cycle_cnt + cfg_ar_delay
            });
          end

          // Convert matured AR requests into R beats by sampling mem[]
          while (ar_q.size() > 0 && ar_q[0].ready_cycle <= cycle_cnt) begin
            automatic ar_cmd_t cmd = ar_q.pop_front();
            for (int unsigned b = 0; b <= cmd.len; b++) begin
              automatic axi_addr_t beat_al = ((cmd.addr >> cmd.size) << cmd.size) + b * (1 << cmd.size);
              automatic axi_addr_t bus_al  = (beat_al / AxiSW) * AxiSW;
              automatic r_beat_t rb;
              rb.data = '0;
              for (int unsigned k = 0; k < AxiSW; k++) begin
                automatic axi_addr_t a = bus_al + k;
                if (a < MEM_BYTES) rb.data[8*k +: 8] = mem[a];
              end
              rb.last = (b == cmd.len);
              r_q.push_back(rb);
            end
          end

          // R channel pop & drive
          if (axi_resp.r_valid && axi_req.r_ready) begin
            void'(r_q.pop_front());
          end
          if (r_q.size() > 0 && (!cfg_bp_enable || (rv[1:0] != 2'b00))) begin
            axi_resp.r_valid <= 1'b1;
            axi_resp.r.data  <= r_q[0].data;
            axi_resp.r.last  <= r_q[0].last;
            axi_resp.r.resp  <= axi_pkg::RESP_OKAY;
            axi_resp.r.id    <= '0;
            axi_resp.r.user  <= '0;
          end else if (!axi_resp.r_valid || axi_req.r_ready) begin
            axi_resp.r_valid <= 1'b0;
          end

          // -----------------------------------------------------------------
          // 2. AXI4 AW & W handshakes + 4KB & WSTRB/WLAST protocol checks
          // -----------------------------------------------------------------
          if (axi_req.aw_valid && axi_resp.aw_ready) begin
            automatic axi_addr_t al_start = (axi_req.aw.addr >> axi_req.aw.size) << axi_req.aw.size;
            automatic axi_addr_t end_byte = al_start + ((axi_addr_t'(axi_req.aw.len) + 1) << axi_req.aw.size) - 1;
            if (axi_req.aw.addr[63:12] != end_byte[63:12]) begin
              $display("[ERR][DW%0d] AXI AW 4KB boundary crossing: addr=0x%h len=%0d size=%0d end=0x%h",
                       AxiDW, axi_req.aw.addr, axi_req.aw.len, axi_req.aw.size, end_byte);
              err_cnt++;
            end
            if ((1 << axi_req.aw.size) > AxiSW) begin
              $display("[ERR][DW%0d] AXI AWSIZE=%0d exceeds bus width", AxiDW, axi_req.aw.size);
              err_cnt++;
            end
            aw_q.push_back('{
              addr: axi_req.aw.addr,
              len:  axi_req.aw.len,
              size: axi_req.aw.size
            });
          end

          if (axi_req.w_valid && axi_resp.w_ready) begin
            w_q.push_back('{
              data: axi_req.w.data,
              strb: axi_req.w.strb,
              last: axi_req.w.last
            });
          end

          // Pair completed AW + W bursts
          if (aw_q.size() > 0 && w_q.size() >= (int'(aw_q[0].len) + 1)) begin
            automatic aw_cmd_t awc = aw_q.pop_front();
            automatic pending_write_t pw;
            pw.addr = awc.addr;
            pw.len  = awc.len;
            pw.size = awc.size;
            pw.beats.delete();
            for (int unsigned b = 0; b <= awc.len; b++) begin
              automatic w_beat_t wb = w_q.pop_front();
              automatic shortint unsigned lb = axi_pkg::beat_lower_byte(
                awc.addr, awc.size, awc.len, axi_pkg::BURST_INCR, AxiSW, shortint'(b));
              automatic shortint unsigned ub = axi_pkg::beat_upper_byte(
                awc.addr, awc.size, awc.len, axi_pkg::BURST_INCR, AxiSW, shortint'(b));
              if (wb.last != (b == awc.len)) begin
                $display("[ERR][DW%0d] AXI WLAST mismatch on beat %0d/%0d (got %b)",
                         AxiDW, b, awc.len, wb.last);
                err_cnt++;
              end
              for (int unsigned k = 0; k < AxiSW; k++) begin
                if ((k < lb || k > ub) && wb.strb[k]) begin
                  $display("[ERR][DW%0d] AXI WSTRB[%0d]=1 outside [%0d..%0d] at addr=0x%h beat=%0d",
                           AxiDW, k, lb, ub, awc.addr, b);
                  err_cnt++;
                end
              end
              pw.beats.push_back(wb);
            end
            pw.commit_cycle = cycle_cnt + cfg_b_delay;
            wr_commit_q.push_back(pw);
          end

          // Commit matured writes to mem[] and enqueue B response
          while (wr_commit_q.size() > 0 && wr_commit_q[0].commit_cycle <= cycle_cnt) begin
            automatic pending_write_t pw = wr_commit_q.pop_front();
            for (int unsigned b = 0; b <= pw.len; b++) begin
              automatic axi_addr_t beat_al = ((pw.addr >> pw.size) << pw.size) + b * (1 << pw.size);
              automatic axi_addr_t bus_al  = (beat_al / AxiSW) * AxiSW;
              for (int unsigned k = 0; k < AxiSW; k++) begin
                if (pw.beats[b].strb[k]) begin
                  automatic axi_addr_t a = bus_al + k;
                  if (a < MEM_BYTES) mem[a] = pw.beats[b].data[8*k +: 8];
                end
              end
            end
            b_ready_q.push_back(cycle_cnt);
          end

          if (axi_resp.b_valid && axi_req.b_ready) begin
            void'(b_ready_q.pop_front());
          end
          if (b_ready_q.size() > 0 && (!cfg_bp_enable || (rv[3:2] != 2'b00))) begin
            axi_resp.b_valid <= 1'b1;
            axi_resp.b.resp  <= axi_pkg::RESP_OKAY;
            axi_resp.b.id    <= '0;
            axi_resp.b.user  <= '0;
          end else if (!axi_resp.b_valid || axi_req.b_ready) begin
            axi_resp.b_valid <= 1'b0;
          end

          // Randomize AR/AW/W ready signals
          axi_resp.ar_ready <= !cfg_bp_enable ? 1'b1 : (rv[4] | rv[5]);
          axi_resp.aw_ready <= !cfg_bp_enable ? 1'b1 : (rv[6] | rv[7]);
          axi_resp.w_ready  <= !cfg_bp_enable ? 1'b1 : (rv[8] | rv[9]);

          // -----------------------------------------------------------------
          // 3. Lane VRF writeback (ldu_result_*) with per-lane backpressure
          // -----------------------------------------------------------------
          ldu_result_final_gnt <= pending_final_gnt_d1;
          pending_final_gnt_d1 <= '0;
          for (int unsigned l = 0; l < NrLanes; l++) begin
            automatic logic allow_gnt = !cfg_bp_enable ? 1'b1 : (rv[10 + l] | rv[14 + l]);
            if (ldu_result_req[l] && ldu_result_gnt[l]) begin
              for (int unsigned b = 0; b < 8; b++) begin
                if (ldu_result_be[l][b] && ldu_result_addr[l] < TotalVRFWords) begin
                  vrf[l][ldu_result_addr[l]][8*b +: 8] <= ldu_result_wdata[l][8*b +: 8];
                end
              end
              pending_final_gnt_d1[l] <= 1'b1;
              ldu_result_gnt[l] <= 1'b0;
            end else begin
              ldu_result_gnt[l] <= ldu_result_req[l] & allow_gnt;
            end
          end

          // -----------------------------------------------------------------
          // 4. Lane Store / Addrgen / Mask Operand Streams
          // -----------------------------------------------------------------
          for (int unsigned l = 0; l < NrLanes; l++) begin
            if (stu_operand_valid[l] && stu_operand_ready[l]) begin
              if (stu_op_q[l].size() > 0) void'(stu_op_q[l].pop_front());
            end
            if (stu_op_q[l].size() > 0 && (!stu_operand_valid[l] || stu_operand_ready[l])) begin
              if (!cfg_bp_enable || rv[18 + l] || rv[22 + l]) begin
                stu_operand_valid[l] <= 1'b1;
                stu_operand[l]       <= stu_op_q[l][0];
              end else begin
                stu_operand_valid[l] <= 1'b0;
              end
            end else if (stu_op_q[l].size() == 0 && (!stu_operand_valid[l] || stu_operand_ready[l])) begin
              stu_operand_valid[l] <= 1'b0;
            end
          end

          if ((&addrgen_operand_valid) && addrgen_operand_ready) begin
            for (int unsigned l = 0; l < NrLanes; l++) begin
              if (ag_op_q[l].size() > 0) void'(ag_op_q[l].pop_front());
              else begin
                $display("[ERR][DW%0d] addrgen_operand_ready_o over-popped empty lane %0d!", AxiDW, l);
                err_cnt++;
              end
            end
          end
          for (int unsigned l = 0; l < NrLanes; l++) begin
            if (ag_op_q[l].size() > 0) begin
              addrgen_operand_valid[l] <= 1'b1;
              addrgen_operand[l]       <= ag_op_q[l][0];
            end else begin
              addrgen_operand_valid[l] <= 1'b0;
              addrgen_operand[l]       <= '0;
            end
          end

          if (cur_mask_for_load) begin
            if ((&mask_valid) && vldu_mask_ready) begin
              for (int unsigned l = 0; l < NrLanes; l++)
                if (ldu_msk_q[l].size() > 0) void'(ldu_msk_q[l].pop_front());
            end
            for (int unsigned l = 0; l < NrLanes; l++) begin
              mask_valid[l] <= (ldu_msk_q[l].size() > 0);
              mask_in[l]    <= (ldu_msk_q[l].size() > 0) ? ldu_msk_q[l][0] : '0;
            end
          end else begin
            if ((&mask_valid) && vstu_mask_ready) begin
              for (int unsigned l = 0; l < NrLanes; l++)
                if (stu_msk_q[l].size() > 0) void'(stu_msk_q[l].pop_front());
            end
            for (int unsigned l = 0; l < NrLanes; l++) begin
              mask_valid[l] <= (stu_msk_q[l].size() > 0);
              mask_in[l]    <= (stu_msk_q[l].size() > 0) ? stu_msk_q[l][0] : '0;
            end
          end
        end
      end

      // =====================================================================
      // Helper Methods inside gen_env
      // =====================================================================
      task automatic init_env(input logic [31:0] s);
        env_rng = s;
        local_reset = 1'b1;
        core_st_pending = 1'b0;
        pe_req = '0;
        pe_req_valid = 1'b0;
        pe_vinsn_running = '0;
        lsu_ex_flush = 1'b0;
        cur_mask_for_load = 1'b1;
        for (int l = 0; l < NrLanes; l++) begin
          stu_op_q[l].delete();
          ag_op_q[l].delete();
          ldu_msk_q[l].delete();
          stu_msk_q[l].delete();
        end
        for (int a = 0; a < MEM_BYTES; a++) begin
          byte unsigned v = byte'((a * 37 + 19 + gi * 7) & 8'hFF);
          mem[a]     = v;
          ref_mem[a] = v;
        end
        for (int l = 0; l < NrLanes; l++) begin
          for (int w = 0; w < TotalVRFWords; w++) begin
            elen_t val = {32'(l * 1024 + w * 2 + 1), 32'(l * 1024 + w * 2)} ^ 64'hA5A5_5A5A_C3C3_3C3C;
            vrf[l][w]     = val;
            ref_vrf[l][w] = val;
          end
        end
        @(posedge clk);
        @(posedge clk);
        local_reset = 1'b0;
        @(posedge clk);
      endtask

      // Write an architectural element into BOTH vrf and ref_vrf using Ara's shuffle_index
      function automatic void set_vreg_elem(
        input logic [4:0]    vreg,
        input rvv_pkg::vew_e eew,
        input int unsigned   elem_idx,
        input elen_t         val
      );
        int unsigned eb = 1 << int'(eew);
        int unsigned base_word = int'(vreg) * VRFWordsPerReg;
        for (int unsigned b = 0; b < eb; b++) begin
          int unsigned seq_byte = elem_idx * eb + b;
          int unsigned word_off = seq_byte / 32;
          int unsigned in_word  = seq_byte % 32;
          int unsigned shuf_b   = shuffle_index(in_word, NrLanes, eew);
          int unsigned lane     = shuf_b >> 3;
          int unsigned off      = shuf_b & 7;
          vrf[lane][base_word + word_off][8*off +: 8]     = val[8*b +: 8];
          ref_vrf[lane][base_word + word_off][8*off +: 8] = val[8*b +: 8];
        end
      endfunction

      function automatic elen_t get_ref_vreg_elem(
        input logic [4:0]    vreg,
        input rvv_pkg::vew_e eew,
        input int unsigned   elem_idx
      );
        elen_t res = '0;
        int unsigned eb = 1 << int'(eew);
        int unsigned base_word = int'(vreg) * VRFWordsPerReg;
        for (int unsigned b = 0; b < eb; b++) begin
          int unsigned seq_byte = elem_idx * eb + b;
          int unsigned word_off = seq_byte / 32;
          int unsigned in_word  = seq_byte % 32;
          int unsigned shuf_b   = shuffle_index(in_word, NrLanes, eew);
          int unsigned lane     = shuf_b >> 3;
          int unsigned off      = shuf_b & 7;
          res[8*b +: 8] = ref_vrf[lane][base_word + word_off][8*b_dummy(off) +: 8];
        end
        return res;
      endfunction

      function automatic int unsigned b_dummy(input int unsigned x);
        return x;
      endfunction

      // Golden architectural model + enqueue lane operands/masks for an instruction
      function automatic void prepare_and_model_insn(
        input vid_t          id,
        input ara_op_e       op,
        input logic [4:0]    vd_or_vs,
        input logic [4:0]    vs2_idx,
        input rvv_pkg::vew_e vsew,
        input rvv_pkg::vew_e eew_vs2,
        input axi_addr_t     base_addr,
        input elen_t         stride,
        input int unsigned   vstart_i,
        input int unsigned   vl_i,
        input logic          vm_i,
        input logic [255:0]  elem_mask,
        input bit            expect_illegal,
        output pe_req_t      req_out
      );
        int unsigned eb = 1 << int'(vsew);
        int unsigned ib = 1 << int'(eew_vs2);
        int unsigned start_row = (vstart_i * eb) / 32;
        int unsigned end_row   = (vl_i * eb - 1) / 32;
        int unsigned idx_start_row = (vstart_i * ib) / 32;
        int unsigned idx_end_row   = (vl_i * ib - 1) / 32;

        req_out = '0;
        req_out.id          = id;
        req_out.op          = op;
        req_out.vm          = vm_i;
        req_out.vfu         = is_load(op) ? VFU_LoadUnit : VFU_StoreUnit;
        req_out.vs1         = vd_or_vs;
        req_out.use_vs1     = !is_load(op);
        req_out.eew_vs1     = vsew;
        req_out.old_eew_vs1 = vsew;
        req_out.vs2         = vs2_idx;
        req_out.use_vs2     = (op inside {VLXE, VSXE});
        req_out.eew_vs2     = eew_vs2;
        req_out.vd          = vd_or_vs;
        req_out.use_vd      = is_load(op);
        req_out.scalar_op   = base_addr;
        req_out.use_scalar_op = 1'b1;
        req_out.stride      = stride;
        req_out.vl          = vlen_t'(vl_i);
        req_out.vstart      = vlen_t'(vstart_i);
        req_out.vtype.vsew  = vsew;

        if (expect_illegal) return;

        // 1. Enqueue store VRF operand rows if store
        if (!is_load(op)) begin
          int unsigned base_w = int'(vd_or_vs) * VRFWordsPerReg;
          for (int unsigned r = start_row; r <= end_row; r++) begin
            for (int unsigned l = 0; l < NrLanes; l++) begin
              stu_op_q[l].push_back(ref_vrf[l][base_w + r]);
            end
          end
        end

        // 2. Enqueue indexed offset operand rows if VLXE / VSXE
        if (op inside {VLXE, VSXE}) begin
          int unsigned idx_base_w = int'(vs2_idx) * VRFWordsPerReg;
          for (int unsigned r = idx_start_row; r <= idx_end_row; r++) begin
            for (int unsigned l = 0; l < NrLanes; l++) begin
              ag_op_q[l].push_back(ref_vrf[l][idx_base_w + r]);
            end
          end
        end

        // 3. Enqueue mask rows if vm == 0
        if (!vm_i) begin
          cur_mask_for_load = is_load(op);
          for (int unsigned r = start_row; r <= end_row; r++) begin
            strb_t [NrLanes-1:0] mrow = '0;
            for (int unsigned sb = 0; sb < 32; sb++) begin
              int unsigned global_seq_b = r * 32 + sb;
              int unsigned elem_i       = global_seq_b / eb;
              int unsigned shuf_b       = shuffle_index(sb, NrLanes, vsew);
              int unsigned l            = shuf_b >> 3;
              int unsigned o            = shuf_b & 7;
              if (elem_i < 256 && elem_mask[elem_i]) mrow[l][o] = 1'b1;
            end
            for (int unsigned l = 0; l < NrLanes; l++) begin
              if (is_load(op)) ldu_msk_q[l].push_back(mrow[l]);
              else             stu_msk_q[l].push_back(mrow[l]);
            end
          end
        end

        // 4. Update golden ref_mem / ref_vrf in program order!
        for (int unsigned e = vstart_i; e < vl_i; e++) begin
          bit m_en = vm_i ? 1'b1 : elem_mask[e];
          axi_addr_t ea;
          case (op)
            VLE, VSE:   ea = base_addr + e * eb;
            VLSE, VSSE: ea = base_addr + e * stride;
            VLXE, VSXE: begin
              elen_t raw_off = get_ref_vreg_elem(vs2_idx, eew_vs2, e);
              elen_t zext_off = '0;
              case (eew_vs2)
                EW8:  zext_off = {56'd0, raw_off[7:0]};
                EW16: zext_off = {48'd0, raw_off[15:0]};
                EW32: zext_off = {32'd0, raw_off[31:0]};
                default: zext_off = raw_off;
              endcase
              ea = base_addr + zext_off;
            end
            default: ea = base_addr;
          endcase

          if (m_en) begin
            if (is_load(op)) begin
              int unsigned base_w = int'(vd_or_vs) * VRFWordsPerReg;
              for (int unsigned b = 0; b < eb; b++) begin
                int unsigned seq_b  = e * eb + b;
                int unsigned w_off  = seq_b / 32;
                int unsigned in_w   = seq_b % 32;
                int unsigned shuf_b = shuffle_index(in_w, NrLanes, vsew);
                int unsigned l      = shuf_b >> 3;
                int unsigned o      = shuf_b & 7;
                ref_vrf[l][base_w + w_off][8*o +: 8] = ref_mem[ea + b];
              end
            end else begin
              elen_t val = get_ref_vreg_elem(vd_or_vs, vsew, e);
              for (int unsigned b = 0; b < eb; b++) begin
                ref_mem[ea + b] = val[8*b +: 8];
              end
            end
          end
        end
      endfunction

      // Issue instruction via Ara sequencer handshake (holds pe_req_valid until addrgen_ack!)
      // Returns immediately after addrgen_ack so caller can pipeline back-to-back instructions!
      task automatic issue_insn_no_wait_done(
        input pe_req_t req,
        output exception_t exc_out,
        output vlen_t      exc_vstart_out,
        input int unsigned timeout_cyc = 4000
      );
        int unsigned t = 0;
        int unsigned unit_idx = is_load(req.op) ? OffsetLoad : OffsetStore;
        while (!pe_req_ready[unit_idx] || pe_vinsn_running[req.id]) begin
          @(posedge clk);
          for (int i = 0; i < NrVInsn; i++) begin
            if (pe_resp[OffsetLoad].vinsn_done[i] || pe_resp[OffsetStore].vinsn_done[i])
              pe_vinsn_running[i] <= 1'b0;
          end
          t++;
          if (t > timeout_cyc) begin
            $display("[ERR][DW%0d] Timeout waiting for pe_req_ready on id=%0d op=%0d", AxiDW, req.id, req.op);
            err_cnt++;
            return;
          end
        end

        pe_req                  <= req;
        pe_req_valid            <= 1'b1;
        pe_vinsn_running[req.id] <= 1'b1;

        t = 0;
        while (1) begin
          @(posedge clk);
          for (int i = 0; i < NrVInsn; i++) begin
            if (pe_resp[OffsetLoad].vinsn_done[i] || pe_resp[OffsetStore].vinsn_done[i]) begin
              // Verify store_pending / write-commit invariant when store finishes!
              if (pe_resp[OffsetStore].vinsn_done[i] && !addrgen_exception.valid) begin
                if (aw_q.size() != 0 || wr_commit_q.size() != 0) begin
                  // Check if there are still uncommitted bursts belonging to this store when only 1 store is active
                end
              end
              pe_vinsn_running[i] <= 1'b0;
            end
          end
          if (addrgen_ack) begin
            exc_out        = addrgen_exception;
            exc_vstart_out = addrgen_exception_vstart;
            pe_req_valid   <= 1'b0;
            break;
          end
          t++;
          if (t > timeout_cyc) begin
            $display("[ERR][DW%0d] Timeout waiting for addrgen_ack on id=%0d op=%0d", AxiDW, req.id, req.op);
            err_cnt++;
            pe_req_valid <= 1'b0;
            return;
          end
        end
      endtask

      task automatic wait_all_idle(input int unsigned timeout_cyc = 8000);
        int unsigned t = 0;
        while (|pe_vinsn_running || store_pending ||
               ar_q.size() > 0 || r_q.size() > 0 ||
               aw_q.size() > 0 || w_q.size() > 0 ||
               wr_commit_q.size() > 0 || b_ready_q.size() > 0 ||
               axi_resp.r_valid || axi_resp.b_valid ||
               (|ldu_result_req) || (|pending_final_gnt_d1) || (|ldu_result_final_gnt)) begin
          @(posedge clk);
          for (int i = 0; i < NrVInsn; i++) begin
            if (pe_resp[OffsetLoad].vinsn_done[i] || pe_resp[OffsetStore].vinsn_done[i]) begin
              // When the LAST running store claims vinsn_done, verify ZERO writes/Bs remain uncommitted!
              if (pe_resp[OffsetStore].vinsn_done[i] && ($countones(pe_vinsn_running) <= 1)) begin
                if (aw_q.size() != 0 || wr_commit_q.size() != 0 || b_ready_q.size() != 0) begin
                  $display("[ERR][DW%0d] Premature store vinsn_done[id=%0d] while %0d AW / %0d write-commits / %0d B-beats still pending!",
                           AxiDW, i, aw_q.size(), wr_commit_q.size(), b_ready_q.size());
                  err_cnt++;
                end
              end
              pe_vinsn_running[i] <= 1'b0;
            end
          end
          if (!store_pending && (wr_commit_q.size() != 0 || b_ready_q.size() != 0)) begin
            $display("[ERR][DW%0d] store_pending_o deasserted while %0d write-commits / %0d B-beats remain uncommitted!",
                     AxiDW, wr_commit_q.size(), b_ready_q.size());
            err_cnt++;
          end
          t++;
          if (t > timeout_cyc) begin
            $display("[ERR][DW%0d] Timeout in wait_all_idle! running=%b store_pending=%b ar=%0d r=%0d aw=%0d w=%0d wr_c=%0d b=%0d",
                     AxiDW, pe_vinsn_running, store_pending,
                     ar_q.size(), r_q.size(), aw_q.size(), w_q.size(), wr_commit_q.size(), b_ready_q.size());
            err_cnt++;
            pe_vinsn_running <= '0;
            return;
          end
        end
        repeat (3) @(posedge clk);
      endtask

      task automatic check_architectural_state(input string tag);
        int unsigned local_err = 0;
        for (int a = 0; a < MEM_BYTES; a++) begin
          if (mem[a] !== ref_mem[a]) begin
            if (local_err < 8)
              $display("[ERR][DW%0d][%s] MEM[0x%04h] mismatch: got 0x%02h exp 0x%02h",
                       AxiDW, tag, a, mem[a], ref_mem[a]);
            local_err++;
          end
        end
        for (int l = 0; l < NrLanes; l++) begin
          for (int w = 0; w < TotalVRFWords; w++) begin
            if (vrf[l][w] !== ref_vrf[l][w]) begin
              if (local_err < 8)
                $display("[ERR][DW%0d][%s] VRF[lane=%0d][word=%0d (v%0d+%0d)] mismatch: got 0x%016h exp 0x%016h",
                         AxiDW, tag, l, w, w / VRFWordsPerReg, w % VRFWordsPerReg, vrf[l][w], ref_vrf[l][w]);
              local_err++;
            end
          end
        end
        for (int l = 0; l < NrLanes; l++) begin
          if (stu_op_q[l].size() != 0 || ag_op_q[l].size() != 0 ||
              ldu_msk_q[l].size() != 0 || stu_msk_q[l].size() != 0) begin
            $display("[ERR][DW%0d][%s] Unconsumed lane queue entries on lane %0d: stu=%0d ag=%0d lmsk=%0d smsk=%0d",
                     AxiDW, tag, l, stu_op_q[l].size(), ag_op_q[l].size(), ldu_msk_q[l].size(), stu_msk_q[l].size());
            local_err++;
          end
        end
        err_cnt += local_err;
      endtask

      // =====================================================================
      // Full Suite Runner per AxiDataWidth Instance
      // =====================================================================
      task automatic run_all_suites(input logic [31:0] base_seed);
        pe_req_t req0, req1, req2;
        exception_t exc;
        vlen_t exc_vs;
        vid_t next_id = '0;

        init_env(base_seed);

        // -------------------------------------------------------------------
        // SUITE 1: Unaligned 4KB Page-Boundary Burst Splitting (EW8..EW64)
        // -------------------------------------------------------------------
        cfg_b_delay   = 4;
        cfg_ar_delay  = 2;
        cfg_bp_enable = 1'b1;

        // 1a: Unaligned EW32 load & store crossing 0x1000
        prepare_and_model_insn(next_id++, VLE, 5'd1, 5'd0, EW32, EW32, 64'h0FF4, 64'd0, 0, 20, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();
        prepare_and_model_insn(next_id++, VSE, 5'd1, 5'd0, EW32, EW32, 64'h1FF4, 64'd0, 0, 20, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();

        // 1b: Unaligned EW16 store crossing BOTH 512B max narrow burst AND 0x3000 4KB page boundary (560B -> 3 bursts!)
        prepare_and_model_insn(next_id++, VLE, 5'd2, 5'd0, EW16, EW16, 64'h2002, 64'd0, 0, 280, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();
        prepare_and_model_insn(next_id++, VSE, 5'd2, 5'd0, EW16, EW16, 64'h2DF2, 64'd0, 0, 280, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();

        // 1c: Unaligned EW8 & EW64 crossing 4KB boundaries
        prepare_and_model_insn(next_id++, VLE, 5'd4, 5'd0, EW8, EW8, 64'h3FE3, 64'd0, 0, 77, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();
        prepare_and_model_insn(next_id++, VSE, 5'd4, 5'd0, EW8, EW8, 64'h4FE5, 64'd0, 0, 77, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();

        prepare_and_model_insn(next_id++, VLE, 5'd5, 5'd0, EW64, EW64, 64'h5FD8, 64'd0, 0, 14, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();
        prepare_and_model_insn(next_id++, VSE, 5'd5, 5'd0, EW64, EW64, 64'h6FE8, 64'd0, 0, 14, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();

        check_architectural_state("SUITE1_4KB_UNALIGNED");
        if (err_cnt > 0) return;

        // -------------------------------------------------------------------
        // SUITE 2: Unaligned AXI_MAX_BURST_LEN (256-Beat) Splitting
        // -------------------------------------------------------------------
        // On DW=64, max_burst_bytes = 2048. At addr=0x7004 (offset 4), 256 beats hold 2044B;
        // vl=1023 EW16 = 2046B (< 2048B!) spans 257 beats inside [0x7000..0x7FFF]!
        // Also test addr=0x77FC with 2046B and 2056B right against the 0x8000 4KB page boundary!
        prepare_and_model_insn(next_id++, VLE, 5'd8, 5'd0, EW16, EW16, 64'h7004, 64'd0, 0, 1023, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();

        prepare_and_model_insn(next_id++, VLE, 5'd12, 5'd0, EW16, EW16, 64'h77FC, 64'd0, 0, 1023, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();

        prepare_and_model_insn(next_id++, VLE, 5'd16, 5'd0, EW32, EW32, 64'h8008, 64'd0, 0, 1023, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();

        check_architectural_state("SUITE2_MAX_BURST_UNALIGNED");
        if (err_cnt > 0) return;

        // -------------------------------------------------------------------
        // SUITE 3: Non-Aligned Base + vstart > 0 Cross-VRF-Word + Masked + Back-to-Back Loads
        // -------------------------------------------------------------------
        // 3a: vstart > 0 wrapping VRF Word 0 -> Word 1 while issue_cnt_bytes < 32!
        prepare_and_model_insn(next_id++, VLE, 5'd20, 5'd0, EW16, EW16, 64'h9006, 64'd0, 7, 19, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();

        prepare_and_model_insn(next_id++, VLE, 5'd21, 5'd0, EW32, EW32, 64'h9104, 64'd0, 6, 11, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();

        prepare_and_model_insn(next_id++, VSE, 5'd21, 5'd0, EW32, EW32, 64'h9204, 64'd0, 6, 11, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();

        // 3b: Masked (vm=0) non-aligned + vstart > 0 load and store
        prepare_and_model_insn(next_id++, VLE, 5'd22, 5'd0, EW16, EW16, 64'h93F6, 64'd0, 5, 25, 1'b0,
                               256'hA55A_C33C_F00F_5AA5, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();

        prepare_and_model_insn(next_id++, VSE, 5'd22, 5'd0, EW16, EW16, 64'h94F6, 64'd0, 3, 22, 1'b0,
                               256'h3CC3_9669_AA55_FF00, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();

        // 3c: Back-to-back pipelined loads where Load #1 (vstart=0) is still committing when Load #2 (vstart=7) issues!
        prepare_and_model_insn(next_id++, VLE, 5'd23, 5'd0, EW32, EW32, 64'h9600, 64'd0, 0, 8, 1'b1, '1, 1'b0, req0);
        prepare_and_model_insn(next_id++, VLE, 5'd24, 5'd0, EW32, EW32, 64'h9704, 64'd0, 7, 15, 1'b1, '1, 1'b0, req1);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        issue_insn_no_wait_done(req1, exc, exc_vs);
        wait_all_idle();

        check_architectural_state("SUITE3_VSTART_MASK_PIPELINE");
        if (err_cnt > 0) return;

        // -------------------------------------------------------------------
        // SUITE 4 & 5: Multi-Burst Store B-Commit + RAW/WAR Indexed Scatter/Gather Ordering
        // -------------------------------------------------------------------
        // 4a: Isolated multi-burst store with long B-channel latency to verify store_pending_o & vinsn_done wait for ALL B beats!
        cfg_b_delay  = 10;
        cfg_ar_delay = 2;
        prepare_and_model_insn(next_id++, VSE, 5'd1, 5'd0, EW32, EW32, 64'h9FE8, 64'd0, 0, 16, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();
        check_architectural_state("SUITE4A_MULTIBURST_B_COMMIT");
        if (err_cnt > 0) return;

        // 4b: Directed RAW hazard ordering under long AXI write-commit/B latency (cfg_b_delay=200, cfg_ar_delay=0)
        cfg_b_delay  = 200;
        cfg_ar_delay = 0;
        for (int unsigned e = 0; e < 16; e++) begin
          set_vreg_elem(5'd26, EW16, e, 64'(e * 4));
          set_vreg_elem(5'd28, EW32, e, 64'hDEAD_0000_0000_0000 | 64'(32'hCAFE_1000 + e * 32'h0101_0101));
        end
        prepare_and_model_insn(next_id++, VSE,  5'd28, 5'd0,  EW32, EW32, 64'hA000, 64'd0, 0, 16, 1'b1, '1, 1'b0, req0);
        prepare_and_model_insn(next_id++, VLXE, 5'd30, 5'd26, EW32, EW16, 64'hA000, 64'd0, 0, 16, 1'b1, '1, 1'b0, req1);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        issue_insn_no_wait_done(req1, exc, exc_vs);
        wait_all_idle();
        check_architectural_state("SUITE4B_RAW_LONG_B_COMMIT");
        if (err_cnt > 0) return;

        cfg_b_delay  = 6;
        cfg_ar_delay = 4;

        // Set up distinct byte offsets in v26 (EW16) and v27 (EW32) for scatter/gather
        for (int unsigned e = 0; e < 12; e++) begin
          // Scatter across 0xAFEC..0xB028 (straddling 0xB000 4KB page boundary!)
          set_vreg_elem(5'd26, EW16, e, 64'(e * 8 + 4));
          set_vreg_elem(5'd27, EW32, 11 - e, 64'(e * 8 + 4)); // Reverse permutation!
          set_vreg_elem(5'd28, EW32, e, 64'hDEAD_0000_0000_0000 | 64'(32'hCAFE_1000 + e * 32'h0101_0101));
          set_vreg_elem(5'd29, EW32, e, 64'hBEEF_0000_0000_0000 | 64'(32'h7777_0000 + e * 32'h0202_0202));
        end

        // 5a: RAW1 - Unaligned 4KB-split VSE store -> IMMEDIATELY followed by overlapping VLXE gather (vluxei16.v)!
        prepare_and_model_insn(next_id++, VSE,  5'd28, 5'd0,  EW32, EW32, 64'hAFE4, 64'd0, 0, 16, 1'b1, '1, 1'b0, req0);
        prepare_and_model_insn(next_id++, VLXE, 5'd30, 5'd26, EW32, EW16, 64'hAFE0, 64'd0, 0, 8,  1'b1, '1, 1'b0, req1);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        issue_insn_no_wait_done(req1, exc, exc_vs);
        wait_all_idle();
        check_architectural_state("SUITE5A_RAW_VSE_TO_VLXE");
        if (err_cnt > 0) return;

        // 5b: RAW2 + Back-to-Back Multi-Burst Stores - VSXE scatter (vsoxei32.v) -> VSE -> overlapping VLXE gather!
        prepare_and_model_insn(next_id++, VSXE, 5'd29, 5'd27, EW32, EW32, 64'hAFE0, 64'd0, 0, 12, 1'b1, '1, 1'b0, req0);
        prepare_and_model_insn(next_id++, VSE,  5'd28, 5'd0,  EW32, EW32, 64'hB2FC, 64'd0, 0, 8,  1'b1, '1, 1'b0, req1);
        prepare_and_model_insn(next_id++, VLXE, 5'd31, 5'd26, EW32, EW16, 64'hAFE0, 64'd0, 0, 12, 1'b1, '1, 1'b0, req2);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        issue_insn_no_wait_done(req1, exc, exc_vs);
        issue_insn_no_wait_done(req2, exc, exc_vs);
        wait_all_idle();
        check_architectural_state("SUITE5B_RAW_VSXE_TO_VLXE");
        if (err_cnt > 0) return;

        // 5c: WAR - Slow AR gather/unit-stride load (cfg_ar_delay=6, cfg_b_delay=1) -> IMMEDIATELY followed by VSXE scatter overwriting same region!
        cfg_ar_delay = 6;
        cfg_b_delay  = 1;
        prepare_and_model_insn(next_id++, VLE,  5'd25, 5'd0,  EW32, EW32, 64'hAFE4, 64'd0, 0, 16, 1'b1, '1, 1'b0, req0);
        prepare_and_model_insn(next_id++, VSXE, 5'd28, 5'd26, EW32, EW16, 64'hAFE0, 64'd0, 0, 12, 1'b1, '1, 1'b0, req1);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        issue_insn_no_wait_done(req1, exc, exc_vs);
        wait_all_idle();
        check_architectural_state("SUITE5C_WAR_VLE_TO_VSXE");
        if (err_cnt > 0) return;

        // 5d: Back-to-back VLXE -> VLXE with heavy AR backpressure (operand over-pop check)
        cfg_ar_delay = 3;
        cfg_b_delay  = 3;
        prepare_and_model_insn(next_id++, VLXE, 5'd6, 5'd26, EW32, EW16, 64'hAFE0, 64'd0, 0, 10, 1'b1, '1, 1'b0, req0);
        prepare_and_model_insn(next_id++, VLXE, 5'd7, 5'd27, EW32, EW32, 64'hAFE0, 64'd0, 0, 10, 1'b1, '1, 1'b0, req1);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        issue_insn_no_wait_done(req1, exc, exc_vs);
        wait_all_idle();
        check_architectural_state("SUITE5D_BACK2BACK_VLXE");
        if (err_cnt > 0) return;

        // 5e: Indexed gather with vstart=4 (eew_vs2=EW16 != vsew=EW32) + misaligned first-active-element vstart=4 exception check!
        for (int unsigned e = 0; e < 12; e++) begin
          set_vreg_elem(5'd26, EW16, e, 64'(e * 8 + 4));
        end
        prepare_and_model_insn(next_id++, VLXE, 5'd8, 5'd26, EW32, EW16, 64'hAFE0, 64'd0, 4, 12, 1'b1, '1, 1'b0, req0);
        issue_insn_no_wait_done(req0, exc, exc_vs);
        wait_all_idle();
        check_architectural_state("SUITE5E_VLXE_VSTART4");
        if (err_cnt > 0) return;

        // Misaligned offset at first active element (vstart=4): zero AXI beats issued, must report vstart=4!
        set_vreg_elem(5'd26, EW16, 4, 64'h000E);
        begin
          int unsigned idx_bw = 26 * VRFWordsPerReg;
          for (int unsigned l = 0; l < NrLanes; l++) ag_op_q[l].push_back(ref_vrf[l][idx_bw]);
          req0 = '0;
          req0.id = next_id++;
          req0.op = VLXE;
          req0.vm = 1'b1;
          req0.vfu = VFU_LoadUnit;
          req0.vs2 = 5'd26;
          req0.use_vs2 = 1'b1;
          req0.eew_vs2 = EW16;
          req0.vd = 5'd9;
          req0.use_vd = 1'b1;
          req0.scalar_op = 64'hB400;
          req0.use_scalar_op = 1'b1;
          req0.vl = 10;
          req0.vstart = 4;
          req0.vtype.vsew = EW32;
          issue_insn_no_wait_done(req0, exc, exc_vs);
          if (!exc.valid || exc_vs != 4) begin
            $display("[ERR][DW%0d] Expected indexed misaligned exception at vstart=4, got valid=%b vstart=%0d",
                     AxiDW, exc.valid, exc_vs);
            err_cnt++;
          end
          for (int unsigned l = 0; l < NrLanes; l++) ag_op_q[l].delete();
          lsu_ex_flush <= 1'b1;
          @(posedge clk);
          lsu_ex_flush <= 1'b0;
          wait_all_idle();
          set_vreg_elem(5'd26, EW16, 4, 64'(4 * 8 + 4));
          prepare_and_model_insn(next_id++, VLE, 5'd9, 5'd0, EW32, EW32, 64'hB404, 64'd0, 0, 8, 1'b1, '1, 1'b0, req1);
          issue_insn_no_wait_done(req1, exc, exc_vs);
          wait_all_idle();
          check_architectural_state("SUITE5E_IDX_EXC_VSTART4");
          if (err_cnt > 0) return;
        end

        // -------------------------------------------------------------------
        // SUITE 6: Seeded Randomized Mixed Stress Sequence
        // -------------------------------------------------------------------
        for (int iter = 0; iter < 12; iter++) begin
          automatic logic [31:0] r = next_rng(env_rng);
          automatic rvv_pkg::vew_e ew = rvv_pkg::vew_e'(r[1:0]);
          automatic int unsigned eb = 1 << int'(ew);
          automatic int unsigned vs = int'(r[4:2]);
          automatic int unsigned vl = vs + 4 + int'(r[8:5]);
          automatic axi_addr_t addr = (64'hC000 + ((r[15:9] * 32) & 64'h1FF0) + ((r[18:16] * eb) & 64'hF)) & ~(64'(eb - 1));
          automatic logic [4:0] vreg = 5'd1 + 5'(iter % 6);
          cfg_b_delay  = 2 + (r[20:19]);
          cfg_ar_delay = 1 + (r[22:21]);

          if (r[24]) begin
            prepare_and_model_insn(next_id++, VLE, vreg, 5'd0, ew, ew, addr, 64'(eb * 2), vs, vl, 1'b1, '1, 1'b0, req0);
          end else begin
            prepare_and_model_insn(next_id++, VSE, vreg, 5'd0, ew, ew, addr, 64'(eb * 2), vs, vl, 1'b1, '1, 1'b0, req0);
          end
          issue_insn_no_wait_done(req0, exc, exc_vs);
          if (r[25]) wait_all_idle();
        end
        wait_all_idle();
        check_architectural_state("SUITE6_RANDOM_STRESS");
      endtask
    end
  endgenerate

  initial begin
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    gen_env[0].run_all_suites(seed ^ 32'h1280_0128);
    gen_env[1].run_all_suites(seed ^ 32'h0640_0064);

    if (err_cnt == 0) begin
      $display("TEST_PASSED (seed=%0d)", seed);
      $finish;
    end else begin
      $display("TEST_FAILED (errors=%0d, seed=%0d)", err_cnt, seed);
      $fatal(1, "VLSU verification failed");
    end
  end

  initial begin
    #5_000_000;
    $display("GLOBAL_TIMEOUT");
    $fatal(1, "Global simulation timeout");
  end
endmodule
