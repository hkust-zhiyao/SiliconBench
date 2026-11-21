module tb (
  input logic clk_i,
  input logic rst_ni
);
  import ara_pkg::*;
  import rvv_pkg::*;

  localparam int unsigned NrLanes         = 4;
  localparam int unsigned VLEN            = 1024;
  localparam int unsigned DataWidth       = $bits(elen_t);
  localparam int unsigned StrbWidth       = DataWidth / 8;
  localparam int unsigned BeatBits        = NrLanes * DataWidth;        // 256
  localparam int unsigned BeatBytes       = NrLanes * StrbWidth;        // 32
  localparam int unsigned WordsPerVReg    = (VLEN / 8) / NrLanes / 8;   // 4 words/lane/vreg
  localparam int unsigned VRFWordsPerLane = 32 * WordsPerVReg;          // 128 words/lane
  localparam int unsigned NumCh           = NrMaskFUnits + 2;           // 4 channels
  localparam int unsigned NumDirected     = 21;
  localparam int unsigned NumRandom       = 75;
  localparam int unsigned TotalSuiteTests = NumDirected + NumRandom;

  localparam type vlen_t  = logic [$clog2(VLEN+1)-1:0];
  localparam type vaddr_t = logic [9:0];
  localparam type strb_t  = logic [StrbWidth-1:0];

  `include "ara/ara_typedef.svh"

  // DUT interface signals
  pe_req_t                                    pe_req_i;
  logic                                       pe_req_valid_i;
  logic     [NrVInsn-1:0]                     pe_vinsn_running_i;
  logic                                       pe_req_ready_o;
  pe_resp_t                                   pe_resp_o;
  elen_t                                      result_scalar_o;
  logic                                       result_scalar_valid_o;
  logic                                       result_scalar_ready_i;

  elen_t    [NrLanes-1:0][NumCh-1:0]          masku_operand_i;
  logic     [NrLanes-1:0][NumCh-1:0]          masku_operand_valid_i;
  logic     [NrLanes-1:0][NumCh-1:0]          masku_operand_ready_o;

  logic     [NrLanes-1:0]                     masku_result_req_o;
  vid_t     [NrLanes-1:0]                     masku_result_id_o;
  vaddr_t   [NrLanes-1:0]                     masku_result_addr_o;
  elen_t    [NrLanes-1:0]                     masku_result_wdata_o;
  strb_t    [NrLanes-1:0]                     masku_result_be_o;
  logic     [NrLanes-1:0]                     masku_result_gnt_i;
  logic     [NrLanes-1:0]                     masku_result_final_gnt_i;

  logic     [NrLanes-1:0]                     masku_vrgat_req_valid_o;
  logic     [NrLanes-1:0]                     masku_vrgat_req_ready_i;
  vrgat_req_t                                 masku_vrgat_req_o;

  strb_t    [NrLanes-1:0]                     mask_o;
  logic     [NrLanes-1:0]                     mask_valid_o;
  logic                                       mask_valid_lane_o;
  logic     [NrLanes-1:0]                     lane_mask_ready_i;
  logic                                       vldu_mask_ready_i;
  logic                                       vstu_mask_ready_i;
  logic                                       sldu_mask_ready_i;

  assign masku_vrgat_req_ready_i = '1;
  assign lane_mask_ready_i       = '1;
  assign vldu_mask_ready_i       = 1'b0;
  assign vstu_mask_ready_i       = 1'b0;
  assign sldu_mask_ready_i       = 1'b0;

  masku #(
    .NrLanes   ( NrLanes   ),
    .VLEN      ( VLEN      ),
    .vaddr_t   ( vaddr_t   ),
    .pe_req_t  ( pe_req_t  ),
    .pe_resp_t ( pe_resp_t )
  ) i_dut (
    .clk_i                    ( clk_i                    ),
    .rst_ni                   ( rst_ni                   ),
    .pe_req_i                 ( pe_req_i                 ),
    .pe_req_valid_i           ( pe_req_valid_i           ),
    .pe_vinsn_running_i       ( pe_vinsn_running_i       ),
    .pe_req_ready_o           ( pe_req_ready_o           ),
    .pe_resp_o                ( pe_resp_o                ),
    .result_scalar_o          ( result_scalar_o          ),
    .result_scalar_valid_o    ( result_scalar_valid_o    ),
    .result_scalar_ready_i    ( result_scalar_ready_i    ),
    .masku_operand_i          ( masku_operand_i          ),
    .masku_operand_valid_i    ( masku_operand_valid_i    ),
    .masku_operand_ready_o    ( masku_operand_ready_o    ),
    .masku_result_req_o       ( masku_result_req_o       ),
    .masku_result_id_o        ( masku_result_id_o        ),
    .masku_result_addr_o      ( masku_result_addr_o      ),
    .masku_result_wdata_o     ( masku_result_wdata_o     ),
    .masku_result_be_o        ( masku_result_be_o        ),
    .masku_result_gnt_i       ( masku_result_gnt_i       ),
    .masku_result_final_gnt_i ( masku_result_final_gnt_i ),
    .masku_vrgat_req_valid_o  ( masku_vrgat_req_valid_o  ),
    .masku_vrgat_req_ready_i  ( masku_vrgat_req_ready_i  ),
    .masku_vrgat_req_o        ( masku_vrgat_req_o        ),
    .mask_o                   ( mask_o                   ),
    .mask_valid_o             ( mask_valid_o             ),
    .mask_valid_lane_o        ( mask_valid_lane_o        ),
    .lane_mask_ready_i        ( lane_mask_ready_i        ),
    .vldu_mask_ready_i        ( vldu_mask_ready_i        ),
    .vstu_mask_ready_i        ( vstu_mask_ready_i        ),
    .sldu_mask_ready_i        ( sldu_mask_ready_i        )
  );

  // ---------------------------------------------------------------------------
  // 4-Lane VRF & Reference Architectural Model State
  // ---------------------------------------------------------------------------
  elen_t dut_vrf [NrLanes][VRFWordsPerLane];
  elen_t ref_vrf [NrLanes][VRFWordsPerLane];

  elen_t op_fifo_data  [NrLanes][NumCh][$];
  int    op_stall_cnt  [NrLanes][NumCh];

  int    final_gnt_pipe [NrLanes][$];
  int    inflight_vrf_writes;

  int    scalar_stall_cnt;
  logic  scalar_seen_this_insn;
  elen_t captured_scalar_val;
  logic  prev_scalar_valid;
  elen_t prev_scalar_data;

  int unsigned rng_state;
  function automatic int unsigned next_u32();
    if (rng_state == 32'd0) rng_state = 32'h6D2B_79F5;
    rng_state ^= (rng_state << 13);
    rng_state ^= (rng_state >> 17);
    rng_state ^= (rng_state << 5);
    return rng_state;
  endfunction

  function automatic elen_t next_u64();
    elen_t hi, lo;
    lo = {32'd0, next_u32()};
    hi = {32'd0, next_u32()};
    return (hi << 32) | lo;
  endfunction

  task automatic write_seq_beat_to_both_vrfs(
    input int unsigned base_word,
    input logic [BeatBits-1:0] seq_bits,
    input vew_e ew
  );
    elen_t lane_words [NrLanes];
    for (int l = 0; l < NrLanes; l++) lane_words[l] = '0;
    for (int b = 0; b < BeatBytes; b++) begin
      automatic int shuf_b = shuffle_index(16'(b), NrLanes, ew);
      automatic int l_idx  = shuf_b / StrbWidth;
      automatic int b_off  = shuf_b % StrbWidth;
      lane_words[l_idx][8*b_off +: 8] = seq_bits[8*b +: 8];
    end
    for (int l = 0; l < NrLanes; l++) begin
      dut_vrf[l][base_word] = lane_words[l];
      ref_vrf[l][base_word] = lane_words[l];
    end
  endtask

  function automatic logic [BeatBits-1:0] read_seq_beat_from_ref_vrf(
    input int unsigned base_word,
    input vew_e ew
  );
    logic [BeatBits-1:0] seq_out;
    seq_out = '0;
    for (int b = 0; b < BeatBytes; b++) begin
      automatic int shuf_b = shuffle_index(16'(b), NrLanes, ew);
      automatic int l_idx  = shuf_b / StrbWidth;
      automatic int b_off  = shuf_b % StrbWidth;
      seq_out[8*b +: 8] = ref_vrf[l_idx][base_word][8*b_off +: 8];
    end
    return seq_out;
  endfunction

  task automatic randomize_all_vrf();
    for (int l = 0; l < NrLanes; l++) begin
      for (int w = 0; w < VRFWordsPerLane; w++) begin
        elen_t val = next_u64();
        dut_vrf[l][w] = val;
        ref_vrf[l][w] = val;
      end
    end
  endtask

  function automatic pe_req_t make_req(
    input vid_t       id,
    input ara_op_e    op,
    input logic       vm,
    input vew_e       eew_vmask,
    input logic [4:0] vs2,
    input vew_e       eew_vs2,
    input logic [4:0] vd,
    input vew_e       eew_vd_op,
    input vew_e       vsew,
    input logic       vta,
    input logic       vma,
    input vlen_t      vl,
    input vlen_t      vstart
  );
    pe_req_t r;
    r               = '0;
    r.id            = id;
    r.op            = op;
    r.vfu           = VFU_MaskUnit;
    r.vm            = vm;
    r.eew_vmask     = eew_vmask;
    r.vs2           = vs2;
    r.use_vs2       = (op != VID);
    r.eew_vs2       = eew_vs2;
    r.vd            = vd;
    r.use_vd        = !vd_scalar(op);
    r.use_vd_op     = (op inside {VMSBF, VMSOF, VMSIF});
    r.eew_vd_op     = eew_vd_op;
    r.emul          = LMUL_1;
    r.vl            = vl;
    r.vstart        = vstart;
    r.vtype.vill    = 1'b0;
    r.vtype.vma     = vma;
    r.vtype.vta     = vta;
    r.vtype.vsew    = vsew;
    r.vtype.vlmul   = LMUL_1;
    return r;
  endfunction

  task automatic apply_golden_model(
    input  pe_req_t        req,
    input  logic [1023:0]  vm_alu_raw_seq,
    output elen_t          exp_scalar
  );
    logic [1023:0] vs2_bits;
    logic [1023:0] m_bits;
    logic [1023:0] vd_old_bits;
    logic [1023:0] vd_new_bits;

    int unsigned vs2_base = int'(vaddr(req.vs2, NrLanes, VLEN));
    int unsigned m_base   = int'(vaddr(5'd0,    NrLanes, VLEN));
    int unsigned vd_base  = int'(vaddr(req.vd,  NrLanes, VLEN));

    exp_scalar  = '0;
    vs2_bits    = '0;
    m_bits      = '0;
    vd_old_bits = '0;

    for (int b = 0; b < 4; b++) begin
      if ((vs2_base + b) < VRFWordsPerLane)
        vs2_bits[b*256 +: 256]    = read_seq_beat_from_ref_vrf(vs2_base + b, req.eew_vs2);
      m_bits[b*256 +: 256]        = read_seq_beat_from_ref_vrf(m_base   + b, req.eew_vmask);
      if ((vd_base + b) < VRFWordsPerLane)
        vd_old_bits[b*256 +: 256] = read_seq_beat_from_ref_vrf(vd_base  + b, req.eew_vd_op);
    end

    if ((req.vl == '0) || (req.vstart >= req.vl)) begin
      if (req.op == VCPOP)       exp_scalar = 64'd0;
      else if (req.op == VFIRST) exp_scalar = 64'hFFFF_FFFF_FFFF_FFFF;
      return;
    end

    unique case (req.op)
      VCPOP: begin
        elen_t cnt = 64'd0;
        for (int i = 0; i < int'(req.vl); i++) begin
          if (i >= int'(req.vstart)) begin
            logic m_en = req.vm | m_bits[i];
            if (m_en && vs2_bits[i]) cnt = cnt + 64'd1;
          end
        end
        exp_scalar = cnt;
      end

      VFIRST: begin
        elen_t found_idx = 64'hFFFF_FFFF_FFFF_FFFF;
        for (int i = 0; i < int'(req.vl); i++) begin
          if ((i >= int'(req.vstart)) && (found_idx == 64'hFFFF_FFFF_FFFF_FFFF)) begin
            logic m_en = req.vm | m_bits[i];
            if (m_en && vs2_bits[i]) found_idx = 64'(unsigned'(i));
          end
        end
        exp_scalar = found_idx;
      end

      VMSBF, VMSOF, VMSIF: begin
        int unsigned num_beats = (int'(req.vl) + 255) / 256;
        logic seen_one = 1'b0;
        vd_new_bits = vd_old_bits;

        for (int i = 0; i < int'(num_beats * 256); i++) begin
          if (i < int'(req.vstart)) begin
            vd_new_bits[i] = vd_old_bits[i];
          end else if (i >= int'(req.vl)) begin
            vd_new_bits[i] = req.vtype.vta ? 1'b1 : vd_old_bits[i];
          end else begin
            logic m_en = req.vm | m_bits[i];
            if (m_en) begin
              unique case (req.op)
                VMSBF:   vd_new_bits[i] = ~seen_one & ~vs2_bits[i];
                VMSIF:   vd_new_bits[i] = ~seen_one;
                default: vd_new_bits[i] = ~seen_one &  vs2_bits[i];
              endcase
              seen_one = seen_one | vs2_bits[i];
            end else begin
              vd_new_bits[i] = req.vtype.vma ? 1'b1 : vd_old_bits[i];
            end
          end
        end

        for (int b = 0; b < int'(num_beats); b++) begin
          elen_t lane_words [NrLanes];
          for (int l = 0; l < NrLanes; l++) lane_words[l] = '0;
          for (int by = 0; by < BeatBytes; by++) begin
            automatic int shuf_b = shuffle_index(16'(by), NrLanes, req.vtype.vsew);
            lane_words[shuf_b / StrbWidth][8*(shuf_b % StrbWidth) +: 8] = vd_new_bits[b*256 + 8*by +: 8];
          end
          for (int l = 0; l < NrLanes; l++) begin
            ref_vrf[l][vd_base + b] = lane_words[l];
          end
        end
      end

      VIOTA, VID: begin
        int unsigned sew_bytes   = 1 << int'(req.vtype.vsew);
        int unsigned elms_per_bt = BeatBytes / sew_bytes;
        int unsigned num_out_bt  = (int'(req.vl) + elms_per_bt - 1) / elms_per_bt;
        int unsigned run_sum     = 0;

        for (int b = 0; b < int'(num_out_bt); b++) begin
          logic [BeatBits-1:0]  seq_wdata = '1;
          logic [BeatBytes-1:0] seq_be    = '0;

          for (int e = 0; e < int'(elms_per_bt); e++) begin
            int unsigned g_elm = b * elms_per_bt + e;
            logic        m_en  = req.vm | m_bits[g_elm];
            int unsigned val   = (req.op == VID) ? g_elm : run_sum;

            if ((req.op == VIOTA) && (g_elm < int'(req.vl)) && m_en && vs2_bits[g_elm]) begin
              run_sum = run_sum + 1;
            end

            if (g_elm < int'(req.vstart)) begin
              for (int sb = 0; sb < int'(sew_bytes); sb++) seq_be[e*sew_bytes + sb] = 1'b0;
            end else if (g_elm < int'(req.vl)) begin
              if (m_en) begin
                for (int sb = 0; sb < int'(sew_bytes); sb++) begin
                  seq_wdata[8*(e*sew_bytes + sb) +: 8] = 8'(val >> (8*sb));
                  seq_be[e*sew_bytes + sb]             = 1'b1;
                end
              end else begin
                for (int sb = 0; sb < int'(sew_bytes); sb++) begin
                  seq_wdata[8*(e*sew_bytes + sb) +: 8] = 8'hFF;
                  seq_be[e*sew_bytes + sb]             = req.vtype.vma;
                end
              end
            end else begin
              for (int sb = 0; sb < int'(sew_bytes); sb++) begin
                seq_wdata[8*(e*sew_bytes + sb) +: 8] = 8'hFF;
                seq_be[e*sew_bytes + sb]             = req.vtype.vta;
              end
            end
          end

          for (int by = 0; by < BeatBytes; by++) begin
            if (seq_be[by]) begin
              automatic int shuf_b = shuffle_index(16'(by), NrLanes, req.vtype.vsew);
              automatic int l_idx  = shuf_b / StrbWidth;
              automatic int b_off  = shuf_b % StrbWidth;
              ref_vrf[l_idx][vd_base + b][8*b_off +: 8] = seq_wdata[8*by +: 8];
            end
          end
        end
      end

      VMAND, VMOR, VMXOR: begin
        int unsigned num_beats = (int'(req.vl) + 255) / 256;
        for (int b = 0; b < int'(num_beats); b++) begin
          for (int by = 0; by < BeatBytes; by++) begin
            automatic int shuf_b = shuffle_index(16'(by), NrLanes, req.vtype.vsew);
            ref_vrf[shuf_b / StrbWidth][vd_base + b][8*(shuf_b % StrbWidth) +: 8] =
              vm_alu_raw_seq[b*256 + 8*by +: 8];
          end
        end
      end

      default: begin
        $display("FAIL: Unsupported op in reference model: %0d", req.op);
        $fatal(1);
      end
    endcase
  endtask

  task automatic build_test_case(
    input  int      idx,
    output pe_req_t req,
    output string   tag,
    output logic    bp_en,
    output int      custom_scalar_stall
  );
    custom_scalar_stall = -1;
    bp_en               = (idx >= 2);

    if (idx < NumDirected) begin
      unique case (idx)
        0: begin
          req = make_req(3'd0, VMAND, 1'b1, EW8, 5'd4, EW8, 5'd8, EW8, EW8, 1'b1, 1'b1, 11'd256, 11'd0);
          tag = "base_vmand_256";
        end
        1: begin
          req = make_req(3'd1, VMXOR, 1'b1, EW8, 5'd6, EW32, 5'd10, EW32, EW32, 1'b1, 1'b1, 11'd512, 11'd0);
          tag = "base_vmxor_512";
        end
        2: begin
          req = make_req(3'd2, VCPOP, 1'b1, EW8, 5'd2, EW8, 5'd0, EW8, EW8, 1'b0, 1'b0, 11'd0, 11'd0);
          tag = "zero_vl_vcpop";
          custom_scalar_stall = 4;
        end
        3: begin
          req = make_req(3'd3, VFIRST, 1'b1, EW16, 5'd2, EW16, 5'd0, EW16, EW16, 1'b0, 1'b0, 11'd0, 11'd0);
          tag = "zero_vl_vfirst";
          custom_scalar_stall = 3;
        end
        4: begin
          req = make_req(3'd4, VCPOP, 1'b0, EW32, 5'd3, EW16, 5'd0, EW8, EW8, 1'b0, 1'b0, 11'd48, 11'd48);
          tag = "vstart_eq_vl_vcpop";
          custom_scalar_stall = 2;
        end
        5: begin
          req = make_req(3'd5, VFIRST, 1'b0, EW64, 5'd3, EW32, 5'd0, EW8, EW8, 1'b0, 1'b0, 11'd48, 11'd60);
          tag = "vstart_gt_vl_vfirst";
          custom_scalar_stall = 5;
        end
        6: begin
          req = make_req(3'd6, VMSBF, 1'b0, EW8, 5'd4, EW8, 5'd8, EW8, EW8, 1'b0, 1'b0, 11'd0, 11'd0);
          tag = "zero_vl_vmsbf";
        end
        7: begin
          req = make_req(3'd7, VIOTA, 1'b0, EW16, 5'd4, EW32, 5'd8, EW16, EW32, 1'b0, 1'b0, 11'd32, 11'd32);
          tag = "vstart_eq_vl_viota";
        end
        8: begin
          req = make_req(3'd0, VID, 1'b1, EW8, 5'd0, EW8, 5'd8, EW8, EW64, 1'b0, 1'b0, 11'd0, 11'd5);
          tag = "zero_vl_vid";
        end
        9: begin
          for (int b = 0; b < 4; b++) begin
            write_seq_beat_to_both_vrfs(int'(vaddr(5'd2, NrLanes, VLEN)) + b, 256'd0, EW16);
            write_seq_beat_to_both_vrfs(int'(vaddr(5'd0, NrLanes, VLEN)) + b, {256{1'b1}}, EW32);
          end
          req = make_req(3'd1, VFIRST, 1'b0, EW32, 5'd2, EW16, 5'd0, EW8, EW8, 1'b0, 1'b0, 11'd900, 11'd0);
          tag = "vfirst_all_zero_900";
          custom_scalar_stall = 5;
        end
        10: begin
          req = make_req(3'd2, VCPOP, 1'b0, EW32, 5'd2, EW16, 5'd0, EW8, EW8, 1'b0, 1'b0, 11'd900, 11'd0);
          tag = "vcpop_all_zero_900";
          custom_scalar_stall = 4;
        end
        11: begin
          logic [255:0] b0_vs2 = '0;
          logic [255:0] b0_m   = '1;
          logic [255:0] b3_vs2 = '0;
          b0_vs2[3]   = 1'b1; // Prestart (< vstart=12): MUST be ignored!
          b0_vs2[20]  = 1'b1; // Masked off (m[20]=0): MUST be ignored!
          b0_m[20]    = 1'b0;
          b0_vs2[137] = 1'b1; // True first active hit!
          b0_vs2[200] = 1'b1; // Later hit in Beat 0
          b3_vs2[52]  = 1'b1; // 768 + 52 = 820 (>= vl=820 tail): MUST be ignored!
          write_seq_beat_to_both_vrfs(int'(vaddr(5'd4, NrLanes, VLEN)) + 0, b0_vs2,      EW16);
          write_seq_beat_to_both_vrfs(int'(vaddr(5'd4, NrLanes, VLEN)) + 1, {256{1'b1}}, EW16);
          write_seq_beat_to_both_vrfs(int'(vaddr(5'd4, NrLanes, VLEN)) + 2, {256{1'b1}}, EW16);
          write_seq_beat_to_both_vrfs(int'(vaddr(5'd4, NrLanes, VLEN)) + 3, b3_vs2,      EW16);
          write_seq_beat_to_both_vrfs(int'(vaddr(5'd0, NrLanes, VLEN)) + 0, b0_m,        EW64);
          write_seq_beat_to_both_vrfs(int'(vaddr(5'd0, NrLanes, VLEN)) + 1, {256{1'b1}}, EW64);
          write_seq_beat_to_both_vrfs(int'(vaddr(5'd0, NrLanes, VLEN)) + 2, {256{1'b1}}, EW64);
          write_seq_beat_to_both_vrfs(int'(vaddr(5'd0, NrLanes, VLEN)) + 3, {256{1'b1}}, EW64);
          req = make_req(3'd3, VFIRST, 1'b0, EW64, 5'd4, EW16, 5'd0, EW8, EW8, 1'b0, 1'b0, 11'd820, 11'd12);
          tag = "vfirst_beat0_hit_drain4";
          custom_scalar_stall = 5;
        end
        12: begin
          logic [255:0] b0_vs2 = '0;
          logic [255:0] b2_vs2 = '0;
          b0_vs2[5]  = 1'b1; // < vstart=10 -> ignored!
          b2_vs2[61] = 1'b1; // 512 + 61 = 573 -> first active '1'!
          b2_vs2[99] = 1'b1; // 512 + 99 = 611 -> second active '1'
          write_seq_beat_to_both_vrfs(int'(vaddr(5'd6, NrLanes, VLEN)) + 0, b0_vs2, EW32);
          write_seq_beat_to_both_vrfs(int'(vaddr(5'd6, NrLanes, VLEN)) + 1, 256'd0, EW32);
          write_seq_beat_to_both_vrfs(int'(vaddr(5'd6, NrLanes, VLEN)) + 2, b2_vs2, EW32);
          req = make_req(3'd4, VFIRST, 1'b0, EW64, 5'd6, EW32, 5'd0, EW8, EW8, 1'b0, 1'b0, 11'd700, 11'd10);
          tag = "vfirst_beat2_hit_573";
          custom_scalar_stall = 3;
        end
        13: begin
          req = make_req(3'd5, VMSBF, 1'b0, EW64, 5'd6, EW32, 5'd12, EW16, EW16, 1'b0, 1'b0, 11'd700, 11'd10);
          tag = "vmsbf_beat2_hit_undist";
        end
        14: begin
          req = make_req(3'd6, VMSOF, 1'b0, EW64, 5'd6, EW32, 5'd14, EW8, EW8, 1'b1, 1'b1, 11'd700, 11'd10);
          tag = "vmsof_beat2_hit_agnostic";
        end
        15: begin
          req = make_req(3'd7, VMSIF, 1'b0, EW64, 5'd6, EW32, 5'd16, EW64, EW64, 1'b0, 1'b1, 11'd700, 11'd10);
          tag = "vmsif_beat2_hit_mixed";
        end
        16: begin
          randomize_all_vrf();
          req = make_req(3'd0, VIOTA, 1'b0, EW16, 5'd1, EW32, 5'd8, EW8, EW8, 1'b0, 1'b0, 11'd740, 11'd19);
          tag = "viota_ew8_740_undist";
        end
        17: begin
          randomize_all_vrf();
          req = make_req(3'd1, VIOTA, 1'b0, EW64, 5'd2, EW8, 5'd8, EW16, EW16, 1'b1, 1'b0, 11'd380, 11'd7);
          tag = "viota_ew16_380_vta1_vma0";
        end
        18: begin
          randomize_all_vrf();
          req = make_req(3'd2, VIOTA, 1'b0, EW8, 5'd3, EW64, 5'd8, EW32, EW32, 1'b0, 1'b1, 11'd250, 11'd13);
          tag = "viota_ew32_250_vta0_vma1";
        end
        19: begin
          randomize_all_vrf();
          req = make_req(3'd3, VIOTA, 1'b0, EW32, 5'd4, EW16, 5'd8, EW64, EW64, 1'b1, 1'b1, 11'd125, 11'd5);
          tag = "viota_ew64_125_vta1_vma1";
        end
        default: begin // 20
          randomize_all_vrf();
          req = make_req(3'd4, VID, 1'b0, EW16, 5'd0, EW8, 5'd8, EW64, EW64, 1'b0, 1'b0, 11'd123, 11'd9);
          tag = "vid_ew64_123_undist";
        end
      endcase
    end else begin
      int          iter = idx - NumDirected;
      ara_op_e     op_sel;
      vew_e        vsew_sel, eew_vs2_sel, eew_m_sel, eew_vd_sel;
      logic        vm_sel, vta_sel, vma_sel;
      logic [4:0]  vs2_reg, vd_reg;
      int unsigned max_vl;
      vlen_t       vl_sel, vstart_sel;
      vid_t        id_sel;

      if ((iter % 8) == 0) randomize_all_vrf();

      case (next_u32() % 7)
        0: op_sel = VCPOP;
        1: op_sel = VFIRST;
        2: op_sel = VMSBF;
        3: op_sel = VMSOF;
        4: op_sel = VMSIF;
        5: op_sel = VIOTA;
        default: op_sel = VID;
      endcase

      vsew_sel    = vew_e'(next_u32() % 4);
      eew_vs2_sel = vew_e'(next_u32() % 4);
      eew_m_sel   = vew_e'(next_u32() % 4);
      eew_vd_sel  = (op_sel inside {VMSBF, VMSOF, VMSIF}) ? vsew_sel : vew_e'(next_u32() % 4);

      vm_sel  = logic'(next_u32() & 1);
      vta_sel = logic'(next_u32() & 1);
      vma_sel = logic'(next_u32() & 1);
      id_sel  = vid_t'(iter % NrVInsn);

      if (op_sel inside {VIOTA, VID}) begin
        case (next_u32() % 3)
          0: vd_reg = 5'd8;
          1: vd_reg = 5'd16;
          default: vd_reg = 5'd24;
        endcase
        vs2_reg = 5'd1 + 5'(next_u32() % 6);
        max_vl  = (8 * (VLEN / 8)) >> int'(vsew_sel);
      end else begin
        vs2_reg = 5'd1 + 5'(next_u32() % 14);
        vd_reg  = 5'd16 + 5'(next_u32() % 15);
        max_vl  = VLEN;
      end

      if ((op_sel inside {VFIRST, VMSBF, VMSOF, VMSIF}) && ((next_u32() % 3) == 0)) begin
        int unsigned target_beat = next_u32() % 4;
        int unsigned target_bit  = next_u32() % 256;
        for (int b = 0; b < 4; b++) begin
          logic [255:0] sparse_w = '0;
          if (b == int'(target_beat)) sparse_w[target_bit] = 1'b1;
          write_seq_beat_to_both_vrfs(int'(vaddr(vs2_reg, NrLanes, VLEN)) + b, sparse_w, eew_vs2_sel);
        end
      end

      case (next_u32() % 6)
        0: vl_sel = 11'd0;
        1: vl_sel = 11'd1 + vlen_t'(next_u32() % 16);
        2: vl_sel = vlen_t'(max_vl);
        default: vl_sel = 11'd1 + vlen_t'(next_u32() % max_vl);
      endcase

      case (next_u32() % 5)
        0, 1: vstart_sel = 11'd0;
        2:    vstart_sel = (vl_sel > 0) ? vlen_t'(next_u32() % int'(vl_sel)) : 11'd0;
        3:    vstart_sel = (vl_sel > 4) ? vlen_t'(1 + (next_u32() % (int'(vl_sel) - 1))) : 11'd0;
        default: vstart_sel = vl_sel + vlen_t'(next_u32() % 8);
      endcase

      bp_en = ((iter % 5) != 0);
      req   = make_req(id_sel, op_sel, vm_sel, eew_m_sel, vs2_reg, eew_vs2_sel, vd_reg, eew_vd_sel,
                       vsew_sel, vta_sel, vma_sel, vl_sel, vstart_sel);
      tag   = $sformatf("rand_%0d", iter);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Synchronous Testbench FSM & Cycle-Accurate Responders
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_INIT,
    ST_PREP,
    ST_ISSUE,
    ST_RUN,
    ST_POST
  } tb_state_e;

  tb_state_e   tb_state;
  int          seed;
  int          test_idx;
  int          total_tests;
  int unsigned watchdog;
  pe_req_t     cur_req;
  string       cur_tag;
  elen_t       cur_exp_scalar;
  logic        active_insn_busy;
  vid_t        active_insn_id;
  logic        backpressure_enable;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tb_state                 <= ST_INIT;
      test_idx                 <= 0;
      total_tests              <= 0;
      watchdog                 <= 0;
      cur_req                  <= '0;
      cur_exp_scalar           <= '0;
      pe_req_i                 <= '0;
      pe_req_valid_i           <= 1'b0;
      pe_vinsn_running_i       <= '0;
      active_insn_busy         <= 1'b0;
      active_insn_id           <= '0;
      backpressure_enable      <= 1'b0;
      masku_operand_i          <= '0;
      masku_operand_valid_i    <= '0;
      masku_result_gnt_i       <= '0;
      masku_result_final_gnt_i <= '0;
      result_scalar_ready_i    <= 1'b0;
      prev_scalar_valid        <= 1'b0;
      prev_scalar_data         <= '0;
      scalar_seen_this_insn    <= 1'b0;
      captured_scalar_val      <= '0;
      inflight_vrf_writes      <= 0;
      scalar_stall_cnt         <= 0;
      for (int l = 0; l < NrLanes; l++) begin
        final_gnt_pipe[l].delete();
        for (int c = 0; c < NumCh; c++) begin
          op_fifo_data[l][c].delete();
          op_stall_cnt[l][c] <= 0;
        end
      end
    end else begin
      // -----------------------------------------------------------------------
      // 1) Lane Operand Feeders (Active during ST_ISSUE / ST_RUN)
      // -----------------------------------------------------------------------
      if (tb_state inside {ST_ISSUE, ST_RUN}) begin
        for (int l = 0; l < NrLanes; l++) begin
          for (int c = 0; c < NumCh; c++) begin
            if (masku_operand_valid_i[l][c] && masku_operand_ready_o[l][c]) begin
              if (op_fifo_data[l][c].size() == 0) begin
                $display("FAIL [%s]: Underflow pop on lane %0d ch %0d", cur_tag, l, c);
                $fatal(1);
              end
              void'(op_fifo_data[l][c].pop_front());
              op_stall_cnt[l][c] <= backpressure_enable ? (next_u32() % 4) : 0;
            end

            if (masku_operand_valid_i[l][c] && !masku_operand_ready_o[l][c]) begin
              masku_operand_valid_i[l][c] <= 1'b1;
              masku_operand_i[l][c]       <= masku_operand_i[l][c];
            end else begin
              int rem_items;
              rem_items = op_fifo_data[l][c].size();
              if (rem_items > 0) begin
                int cur_stall;
                cur_stall = (masku_operand_valid_i[l][c] && masku_operand_ready_o[l][c])
                          ? (backpressure_enable ? (next_u32() % 4) : 0)
                          : op_stall_cnt[l][c];
                if (cur_stall == 0) begin
                  masku_operand_valid_i[l][c] <= 1'b1;
                  masku_operand_i[l][c]       <= op_fifo_data[l][c][0];
                end else begin
                  masku_operand_valid_i[l][c] <= 1'b0;
                  masku_operand_i[l][c]       <= next_u64();
                  op_stall_cnt[l][c]          <= cur_stall - 1;
                end
              end else begin
                masku_operand_valid_i[l][c] <= 1'b0;
                masku_operand_i[l][c]       <= next_u64();
              end
            end
          end
        end
      end else begin
        masku_operand_valid_i <= '0;
      end

      // -----------------------------------------------------------------------
      // 2) VRF Write Responder + Delayed final_gnt Pipeline
      // -----------------------------------------------------------------------
      masku_result_final_gnt_i <= '0;
      begin
        int delta_inflight;
        delta_inflight = 0;

        for (int l = 0; l < NrLanes; l++) begin
          for (int idx = 0; idx < final_gnt_pipe[l].size(); idx++) begin
            final_gnt_pipe[l][idx] = final_gnt_pipe[l][idx] - 1;
          end
          if ((final_gnt_pipe[l].size() > 0) && (final_gnt_pipe[l][0] <= 0)) begin
            void'(final_gnt_pipe[l].pop_front());
            masku_result_final_gnt_i[l] <= 1'b1;
            delta_inflight = delta_inflight - 1;
          end

          if (masku_result_req_o[l] && masku_result_gnt_i[l]) begin
            int unsigned waddr;
            waddr = int'(masku_result_addr_o[l]);
            if (waddr >= VRFWordsPerLane) begin
              $display("FAIL [%s]: Out-of-bounds VRF write addr=%0d on lane %0d", cur_tag, waddr, l);
              $fatal(1);
            end
            if (!active_insn_busy || (masku_result_id_o[l] != active_insn_id)) begin
              $display("FAIL [%s]: Unexpected VRF write req id=%0d (expected id=%0d, busy=%0b)",
                       cur_tag, masku_result_id_o[l], active_insn_id, active_insn_busy);
              $fatal(1);
            end
            for (int b = 0; b < StrbWidth; b++) begin
              if (masku_result_be_o[l][b]) begin
                dut_vrf[l][waddr][8*b +: 8] = masku_result_wdata_o[l][8*b +: 8];
              end
            end
            begin
              int lat;
              lat = backpressure_enable ? (1 + (next_u32() % 4)) : 1;
              if ((final_gnt_pipe[l].size() > 0) && (lat <= final_gnt_pipe[l][final_gnt_pipe[l].size()-1])) begin
                lat = final_gnt_pipe[l][final_gnt_pipe[l].size()-1] + 1;
              end
              final_gnt_pipe[l].push_back(lat);
              delta_inflight = delta_inflight + 1;
            end
          end

          if (!backpressure_enable) begin
            masku_result_gnt_i[l] <= 1'b1;
          end else begin
            masku_result_gnt_i[l] <= ((next_u32() % 100) < 55);
          end
        end

        inflight_vrf_writes <= inflight_vrf_writes + delta_inflight;
      end

      // -----------------------------------------------------------------------
      // 3) Scalar Handshake & Stability Monitor
      // -----------------------------------------------------------------------
      if (prev_scalar_valid) begin
        if (!result_scalar_valid_o) begin
          $display("FAIL [%s]: result_scalar_valid_o dropped before result_scalar_ready_i handshake!", cur_tag);
          $fatal(1);
        end
        if (result_scalar_o !== prev_scalar_data) begin
          $display("FAIL [%s]: result_scalar_o mutated from 0x%016x to 0x%016x while waiting for ready!",
                   cur_tag, prev_scalar_data, result_scalar_o);
          $fatal(1);
        end
      end

      if (result_scalar_valid_o && result_scalar_ready_i) begin
        if (scalar_seen_this_insn) begin
          $display("FAIL [%s]: Duplicate scalar result handshake in single instruction!", cur_tag);
          $fatal(1);
        end
        scalar_seen_this_insn <= 1'b1;
        captured_scalar_val   <= result_scalar_o;
        prev_scalar_valid     <= 1'b0;
        result_scalar_ready_i <= 1'b0;
      end else if (result_scalar_valid_o && !result_scalar_ready_i) begin
        prev_scalar_valid <= 1'b1;
        prev_scalar_data  <= result_scalar_o;
        if (scalar_stall_cnt == 0) begin
          result_scalar_ready_i <= 1'b1;
        end else begin
          scalar_stall_cnt      <= scalar_stall_cnt - 1;
          result_scalar_ready_i <= 1'b0;
        end
      end else begin
        prev_scalar_valid     <= 1'b0;
        if (tb_state inside {ST_ISSUE, ST_RUN}) begin
          result_scalar_ready_i <= (!backpressure_enable) ? 1'b1 : ((scalar_stall_cnt == 0) && ((next_u32() % 100) < 25));
        end else begin
          result_scalar_ready_i <= 1'b0;
        end
      end

      // -----------------------------------------------------------------------
      // 4) Test Sequencer FSM
      // -----------------------------------------------------------------------
      unique case (tb_state)
        ST_INIT: begin
          if (!$value$plusargs("seed=%d", seed)) seed = 101;
          rng_state = int'(seed == 0 ? 32'hA5A5_1234 : (32'(seed) ^ 32'h9E37_79B9));
          void'(next_u32());
          randomize_all_vrf();
          test_idx    <= 0;
          total_tests <= 0;
          tb_state    <= ST_PREP;
        end

        ST_PREP: begin
          if (test_idx >= TotalSuiteTests) begin
            $display("PASS seed=%0d total_tests=%0d", seed, total_tests);
            $finish;
          end else begin
            pe_req_t       next_req;
            string         next_tag;
            logic          next_bp;
            int            next_sc_stall;
            elen_t         next_exp_scalar;
            logic [1023:0] vm_alu_raw_seq;
            int unsigned   num_in_beats;
            int unsigned   vs2_base, m_base, vd_base;

            build_test_case(test_idx, next_req, next_tag, next_bp, next_sc_stall);

            vm_alu_raw_seq = {next_u64(), next_u64(), next_u64(), next_u64(),
                              next_u64(), next_u64(), next_u64(), next_u64(),
                              next_u64(), next_u64(), next_u64(), next_u64(),
                              next_u64(), next_u64(), next_u64(), next_u64()};

            vs2_base = int'(vaddr(next_req.vs2, NrLanes, VLEN));
            m_base   = int'(vaddr(5'd0,         NrLanes, VLEN));
            vd_base  = int'(vaddr(next_req.vd,  NrLanes, VLEN));

            if ((next_req.vl == '0) || (next_req.vstart >= next_req.vl))
              num_in_beats = 0;
            else
              num_in_beats = (int'(next_req.vl) + 255) / 256;

            for (int b = 0; b < int'(num_in_beats); b++) begin
              if (!next_req.vm) begin
                for (int l = 0; l < NrLanes; l++) op_fifo_data[l][0].push_back(dut_vrf[l][m_base + b]);
              end
              if (next_req.use_vd_op) begin
                for (int l = 0; l < NrLanes; l++) op_fifo_data[l][1].push_back(dut_vrf[l][vd_base + b]);
              end
              if (next_req.use_vs2) begin
                if (next_req.op inside {VMAND, VMOR, VMXOR}) begin
                  elen_t shuf_alu [NrLanes];
                  for (int l = 0; l < NrLanes; l++) shuf_alu[l] = '0;
                  for (int by = 0; by < BeatBytes; by++) begin
                    automatic int shuf_b = shuffle_index(16'(by), NrLanes, next_req.eew_vs2);
                    shuf_alu[shuf_b / StrbWidth][8*(shuf_b % StrbWidth) +: 8] = vm_alu_raw_seq[b*256 + 8*by +: 8];
                  end
                  for (int l = 0; l < NrLanes; l++) op_fifo_data[l][2].push_back(shuf_alu[l]);
                end else begin
                  for (int l = 0; l < NrLanes; l++) op_fifo_data[l][2].push_back(dut_vrf[l][vs2_base + b]);
                end
              end
            end

            for (int l = 0; l < NrLanes; l++) begin
              for (int c = 0; c < NumCh; c++) begin
                op_stall_cnt[l][c] <= next_bp ? (next_u32() % 4) : 0;
              end
            end

            apply_golden_model(next_req, vm_alu_raw_seq, next_exp_scalar);

            cur_req                        <= next_req;
            cur_tag                        <= next_tag;
            cur_exp_scalar                 <= next_exp_scalar;
            backpressure_enable            <= next_bp;
            scalar_seen_this_insn          <= 1'b0;
            scalar_stall_cnt               <= (next_sc_stall >= 0) ? next_sc_stall : (next_bp ? (next_u32() % 6) : 0);
            result_scalar_ready_i          <= 1'b0;
            active_insn_busy               <= 1'b1;
            active_insn_id                 <= next_req.id;
            pe_req_i                       <= next_req;
            pe_req_valid_i                 <= 1'b1;
            pe_vinsn_running_i[next_req.id] <= 1'b1;
            watchdog                       <= 0;
            total_tests                    <= total_tests + 1;
            tb_state                       <= ST_ISSUE;
          end
        end

        ST_ISSUE: begin
          if (pe_req_valid_i && pe_req_ready_o) begin
            pe_req_valid_i <= 1'b0;
            pe_req_i       <= '0;
            watchdog       <= 0;
            tb_state       <= ST_RUN;
          end else begin
            watchdog <= watchdog + 1;
            if (watchdog > 2000) begin
              $display("FAIL [%s]: Timeout waiting for pe_req_ready_o", cur_tag);
              $fatal(1);
            end
          end
        end

        ST_RUN: begin
          if (pe_resp_o.vinsn_done[cur_req.id]) begin
            if (inflight_vrf_writes != 0) begin
              $display("FAIL [%s]: vinsn_done asserted while %0d VRF final_gnt writes still in flight!",
                       cur_tag, inflight_vrf_writes);
              $fatal(1);
            end
            for (int l = 0; l < NrLanes; l++) begin
              if (masku_result_req_o[l]) begin
                $display("FAIL [%s]: vinsn_done asserted while masku_result_req_o[%0d] still high!", cur_tag, l);
                $fatal(1);
              end
            end
            pe_vinsn_running_i[cur_req.id] <= 1'b0;
            active_insn_busy               <= 1'b0;
            tb_state                       <= ST_POST;
          end else begin
            watchdog <= watchdog + 1;
            if (watchdog > 15000) begin
              $display("FAIL [%s]: Watchdog timeout waiting for pe_resp_o.vinsn_done[%0d] (op=%0d vl=%0d vstart=%0d vsew=%0d vm=%0b)",
                       cur_tag, cur_req.id, cur_req.op, cur_req.vl, cur_req.vstart, cur_req.vtype.vsew, cur_req.vm);
              $fatal(1);
            end
          end
        end

        ST_POST: begin
          for (int l = 0; l < NrLanes; l++) begin
            for (int c = 0; c < NumCh; c++) begin
              if ((op_fifo_data[l][c].size() != 0) || masku_operand_valid_i[l][c]) begin
                $display("FAIL [%s]: Leftover undrained operand beat on lane %0d ch %0d (rem=%0d, valid=%0b)",
                         cur_tag, l, c, op_fifo_data[l][c].size(), masku_operand_valid_i[l][c]);
                $fatal(1);
              end
            end
          end

          if (vd_scalar(cur_req.op)) begin
            if (!scalar_seen_this_insn) begin
              $display("FAIL [%s]: vinsn_done fired without completing result_scalar handshake!", cur_tag);
              $fatal(1);
            end
            if (captured_scalar_val !== cur_exp_scalar) begin
              $display("FAIL [%s]: Scalar mismatch op=%0d vl=%0d vstart=%0d vm=%0b got=0x%016x exp=0x%016x",
                       cur_tag, cur_req.op, cur_req.vl, cur_req.vstart, cur_req.vm, captured_scalar_val, cur_exp_scalar);
              $fatal(1);
            end
          end else begin
            if (scalar_seen_this_insn || result_scalar_valid_o) begin
              $display("FAIL [%s]: Non-scalar op=%0d spuriously asserted result_scalar_valid_o!", cur_tag, cur_req.op);
              $fatal(1);
            end
          end

          for (int l = 0; l < NrLanes; l++) begin
            for (int w = 0; w < VRFWordsPerLane; w++) begin
              if (dut_vrf[l][w] !== ref_vrf[l][w]) begin
                $display("FAIL [%s]: VRF mismatch at lane=%0d word=%0d (vreg=%0d+%0d): got=0x%016x exp=0x%016x",
                         cur_tag, l, w, w / WordsPerVReg, w % WordsPerVReg, dut_vrf[l][w], ref_vrf[l][w]);
                $fatal(1);
              end
            end
          end

          test_idx <= test_idx + 1;
          tb_state <= ST_PREP;
        end

        default: tb_state <= ST_INIT;
      endcase
    end
  end

endmodule : tb
