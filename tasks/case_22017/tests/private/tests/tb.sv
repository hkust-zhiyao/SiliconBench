`timescale 1ns/1ps

module sldu_lane_harness import ara_pkg::*; import rvv_pkg::*; #(
  parameter int unsigned NrLanes = 4,
  parameter int unsigned VLEN    = 1024
) (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  int         seed_i,
  input  logic       start_i,
  output logic       done_o,
  output int         err_cnt_o
);
  import cf_math_pkg::idx_width;

  localparam int unsigned RowBytes       = 8 * NrLanes;
  localparam int unsigned VLenBytes      = VLEN / 8;
  localparam int unsigned VRFSizePerLane = VLEN * 32 / NrLanes;
  localparam int unsigned VRFWords       = VRFSizePerLane / 64;
  localparam type         vaddr_t        = logic [$clog2(VRFWords)-1:0];
  localparam type         strb_t         = logic [7:0];
  localparam type         vlen_t         = logic [$clog2(VLEN+1)-1:0];
  localparam int unsigned StrideW        = idx_width(RowBytes);

  // Unit-under-test 1: standalone p2_stride_gen
  logic [StrideW-1:0]              u_p2_stride_i;
  logic                            u_p2_valid_i;
  logic                            u_p2_update_i;
  logic [idx_width(StrideW):0]     u_p2_popc_o;
  logic [StrideW-1:0]              u_p2_stride_o;
  logic                            u_p2_valid_o;

  p2_stride_gen #(
    .NrLanes(NrLanes)
  ) i_unit_p2 (
    .clk_i      (clk_i        ),
    .rst_ni     (rst_ni       ),
    .stride_i   (u_p2_stride_i),
    .valid_i    (u_p2_valid_i ),
    .update_i   (u_p2_update_i),
    .popc_o     (u_p2_popc_o  ),
    .stride_p2_o(u_p2_stride_o),
    .valid_o    (u_p2_valid_o )
  );

  // Unit-under-test 2: full sldu_subsys_top
  vid_t                   req_id;
  ara_op_e                req_op;
  logic                   req_vm;
  vew_e                   req_eew_vs2;
  logic                   req_use_vs2;
  elen_t                  req_scalar_op;
  logic                   req_use_scalar_op;
  elen_t                  req_stride;
  logic                   req_is_stride_np2;
  vfu_e                   req_vfu;
  logic [4:0]             req_vd;
  logic                   req_use_vd;
  vlen_t                  req_vl;
  vtype_t                 req_vtype;
  logic                   pe_req_valid;
  logic [NrVInsn-1:0]     pe_vinsn_running;
  logic                   pe_req_ready;
  logic [NrVInsn-1:0]     pe_vinsn_done;

  elen_t [NrLanes-1:0]    sldu_operand;
  logic  [NrLanes-1:0]    sldu_operand_valid;
  logic  [NrLanes-1:0]    sldu_operand_ready;
  logic  [NrLanes-1:0]    sldu_result_req;
  vid_t  [NrLanes-1:0]    sldu_result_id;
  vaddr_t[NrLanes-1:0]    sldu_result_addr;
  elen_t [NrLanes-1:0]    sldu_result_wdata;
  strb_t [NrLanes-1:0]    sldu_result_be;
  logic  [NrLanes-1:0]    sldu_result_gnt;
  logic  [NrLanes-1:0]    sldu_result_final_gnt;
  sldu_mux_e              sldu_mux_sel;
  logic  [NrLanes-1:0]    sldu_red_valid;
  strb_t [NrLanes-1:0]    mask_data;
  logic  [NrLanes-1:0]    mask_valid;
  logic                   mask_ready;

  sldu_subsys_top #(
    .NrLanes(NrLanes),
    .VLEN   (VLEN   )
  ) i_dut (
    .clk_i                  (clk_i                ),
    .rst_ni                 (rst_ni               ),
    .req_id_i               (req_id               ),
    .req_op_i               (req_op               ),
    .req_vm_i               (req_vm               ),
    .req_eew_vs2_i          (req_eew_vs2          ),
    .req_use_vs2_i          (req_use_vs2          ),
    .req_scalar_op_i        (req_scalar_op        ),
    .req_use_scalar_op_i    (req_use_scalar_op    ),
    .req_stride_i           (req_stride           ),
    .req_is_stride_np2_i    (req_is_stride_np2    ),
    .req_vfu_i              (req_vfu              ),
    .req_vd_i               (req_vd               ),
    .req_use_vd_i           (req_use_vd           ),
    .req_vl_i               (req_vl               ),
    .req_vtype_i            (req_vtype            ),
    .pe_req_valid_i         (pe_req_valid         ),
    .pe_vinsn_running_i     (pe_vinsn_running     ),
    .pe_req_ready_o         (pe_req_ready         ),
    .pe_vinsn_done_o        (pe_vinsn_done        ),
    .sldu_operand_i         (sldu_operand         ),
    .sldu_operand_valid_i   (sldu_operand_valid   ),
    .sldu_operand_ready_o   (sldu_operand_ready   ),
    .sldu_result_req_o      (sldu_result_req      ),
    .sldu_result_id_o       (sldu_result_id       ),
    .sldu_result_addr_o     (sldu_result_addr     ),
    .sldu_result_wdata_o    (sldu_result_wdata    ),
    .sldu_result_be_o       (sldu_result_be       ),
    .sldu_result_gnt_i      (sldu_result_gnt      ),
    .sldu_result_final_gnt_i(sldu_result_final_gnt),
    .sldu_mux_sel_o         (sldu_mux_sel         ),
    .sldu_red_valid_o       (sldu_red_valid       ),
    .mask_i                 (mask_data            ),
    .mask_valid_i           (mask_valid           ),
    .mask_ready_o           (mask_ready           )
  );

  // Architectural & DUT VRF byte images
  logic [7:0] dut_vrf [0:VRFWords-1][0:NrLanes-1][0:7];
  logic [7:0] ref_vrf [0:VRFWords-1][0:NrLanes-1][0:7];

  // Stream queues for back-to-back pipelined slide verification
  typedef struct {
    vid_t    id;
    ara_op_e op;
    logic    vm;
    vew_e    eew_vs2;
    logic    use_vs2;
    elen_t   scalar_op;
    logic    use_scalar_op;
    elen_t   stride;
    logic    is_stride_np2;
    vfu_e    vfu;
    logic [4:0] vd;
    logic    use_vd;
    vlen_t   vl;
    vtype_t  vtype;
  } tb_insn_t;

  typedef struct {
    strb_t [NrLanes-1:0] data;
    logic  [NrLanes-1:0] vld_mask;
  } mask_beat_t;

  tb_insn_t   insn_q [$];
  vid_t       commit_order_q [$];
  elen_t      op_q   [NrLanes][$];
  mask_beat_t msk_q  [$];

  // Delayed final_gnt pipeline per lane (models operand_requester bank arbitration delay)
  logic [2:0] fgnt_pipe [NrLanes];
  int         rng_state;

  function automatic int next_rand();
    logic [31:0] x;
    x = rng_state;
    if (x == 0) x = 32'h6D2B79F5;
    x ^= (x << 13);
    x ^= (x >> 17);
    x ^= (x << 5);
    rng_state = int'(x);
    return int'(x & 32'h7fff_ffff);
  endfunction

  function automatic int unsigned get_vlmax_bytes(vlmul_e lmul);
    unique case (lmul)
      LMUL_1  : return VLenBytes;
      LMUL_2  : return VLenBytes << 1;
      LMUL_4  : return VLenBytes << 2;
      LMUL_8  : return VLenBytes << 3;
      LMUL_1_2: return VLenBytes >> 1;
      LMUL_1_4: return VLenBytes >> 2;
      LMUL_1_8: return VLenBytes >> 3;
      default : return VLenBytes;
    endcase
  endfunction

  function automatic logic calc_disp_np2(elen_t stride_val);
    int popc;
    popc = 0;
    for (int i = 0; i < idx_width(VLenBytes << 3); i++) begin
      popc += int'(stride_val[i]);
    end
    return (popc > 1);
  endfunction

  logic [NrVInsn-1:0] id_in_use;
  vid_t               next_vid;

  task automatic init_vrfs(input int tag);
    for (int w = 0; w < VRFWords; w++) begin
      for (int l = 0; l < NrLanes; l++) begin
        for (int b = 0; b < 8; b++) begin
          logic [7:0] v;
          v = 8'((w * 37 + l * 13 + b * 7 + tag * 29 + 8'h5A) & 8'hFF);
          if (v == 8'h00) v = 8'hA5;
          dut_vrf[w][l][b] = v;
          ref_vrf[w][l][b] = v;
        end
      end
    end
  endtask

  task automatic alloc_vid(output vid_t id_out);
    id_out   = next_vid;
    next_vid = vid_t'(next_vid + 1'b1);
  endtask

  // Enqueue a slide instruction + exact upstream operand/mask beats + update architectural ref_vrf
  task automatic enqueue_slide(
    input ara_op_e    op,
    input logic       use_scalar_op,
    input elen_t      scalar_op,
    input elen_t      stride,
    input logic       vm,
    input vew_e       eew_vs2,
    input vew_e       vsew,
    input vlmul_e     vlmul,
    input int         vl_int,
    input logic [4:0] vd,
    input logic       sparse_mask_vld
  );
    tb_insn_t   ins;
    vid_t       id_alloc;
    int         sew_b, vl_b, vlmax_b, vlmax_el;
    int         first_src_row, num_src_rows;
    int         first_dst_row, last_dst_row;
    logic [7:0] vs2_bytes [0:VLEN-1];
    logic       elem_mask [0:VLEN-1];
    logic       null_up;

    alloc_vid(id_alloc);
    sew_b    = 1 << int'(vsew);
    vl_b     = vl_int * sew_b;
    vlmax_b  = get_vlmax_bytes(vlmul);
    vlmax_el = vlmax_b >> int'(vsew);

    for (int i = 0; i < VLEN; i++) begin
      vs2_bytes[i] = 8'((next_rand() & 8'hFE) | 8'h01); // non-zero source bytes to distinguish from zero-fill
      elem_mask[i] = vm ? 1'b1 : logic'(next_rand() & 1);
    end

    ins = '{
      id           : id_alloc,
      op           : op,
      vm           : vm,
      eew_vs2      : eew_vs2,
      use_vs2      : 1'b1,
      scalar_op    : scalar_op,
      use_scalar_op: use_scalar_op,
      stride       : use_scalar_op ? 64'd1 : stride,
      is_stride_np2: calc_disp_np2(use_scalar_op ? 64'd1 : stride),
      vfu          : VFU_SlideUnit,
      vd           : vd,
      use_vd       : 1'b1,
      vl           : vlen_t'(vl_int),
      vtype        : '{vill: 1'b0, vma: 1'b0, vta: 1'b0, vsew: vsew, vlmul: vlmul}
    };

    null_up = (op == VSLIDEUP) && (!use_scalar_op) && ((vl_int == 0) || (stride >= 64'(unsigned'(vl_int))));

    first_src_row = 0;
    num_src_rows  = 0;
    first_dst_row = 0;
    last_dst_row  = -1;

    if (!null_up && (vl_int > 0)) begin
      if (op == VSLIDEUP && !use_scalar_op) begin
        int st_b, rem_b;
        st_b          = int'(stride[31:0]) * sew_b;
        rem_b         = vl_b - st_b;
        first_src_row = 0;
        num_src_rows  = (rem_b + RowBytes - 1) / RowBytes;
        first_dst_row = st_b / RowBytes;
        last_dst_row  = (vl_b - 1) / RowBytes;
      end else if (op == VSLIDEUP && use_scalar_op) begin
        first_src_row = 0;
        num_src_rows  = (vl_int > 1) ? (((vl_b - sew_b) + RowBytes - 1) / RowBytes) : 0;
        first_dst_row = 0;
        last_dst_row  = (vl_b - 1) / RowBytes;
      end else if (op == VSLIDEDOWN && use_scalar_op) begin
        first_src_row = 0;
        num_src_rows  = (vl_int > 1) ? ((vl_b + RowBytes - 1) / RowBytes) : 0;
        first_dst_row = 0;
        last_dst_row  = (vl_b - 1) / RowBytes;
      end else begin
        // VSLIDEDOWN (!use_scalar_op)
        first_dst_row = 0;
        last_dst_row  = (vl_b - 1) / RowBytes;
        if (stride < 64'(unsigned'(vlmax_el))) begin
          int st_b, in_off, avail_b, s_b;
          st_b          = int'(stride[31:0]) * sew_b;
          in_off        = st_b % RowBytes;
          avail_b       = vlmax_b - st_b;
          s_b           = (vl_b <= avail_b) ? vl_b : avail_b;
          first_src_row = st_b / RowBytes;
          num_src_rows  = (in_off + s_b + RowBytes - 1) / RowBytes;
        end
      end
    end

    // Push source operand row beats shuffled by eew_vs2
    for (int r = 0; r < num_src_rows; r++) begin
      elen_t row_words [NrLanes];
      for (int l = 0; l < NrLanes; l++) row_words[l] = '0;
      for (int b = 0; b < RowBytes; b++) begin
        int unsigned g_b, sb;
        g_b = (first_src_row + r) * RowBytes + b;
        sb  = shuffle_index(16'(b), NrLanes, eew_vs2);
        row_words[sb >> 3][8*sb[2:0] +: 8] = (g_b < VLEN) ? vs2_bytes[g_b] : 8'hEE;
      end
      for (int l = 0; l < NrLanes; l++) op_q[l].push_back(row_words[l]);
    end

    // Push mask beats for [first_dst_row .. last_dst_row] when vm == 0
    if (!vm && (last_dst_row >= first_dst_row)) begin
      for (int r = first_dst_row; r <= last_dst_row; r++) begin
        mask_beat_t mb;
        mb.data     = '0;
        mb.vld_mask = sparse_mask_vld ? {{(NrLanes-1){1'b0}}, 1'b1} : '1;
        for (int b = 0; b < RowBytes; b++) begin
          int unsigned g_b, el_i, sb;
          g_b  = r * RowBytes + b;
          el_i = g_b / sew_b;
          sb   = shuffle_index(16'(b), NrLanes, vsew);
          mb.data[sb >> 3][sb[2:0]] = (el_i < VLEN) ? elem_mask[el_i] : 1'b0;
        end
        msk_q.push_back(mb);
      end
    end

    // Update architectural reference VRF byte-by-byte per RVV 1.0 Sec 16.3
    for (int i = 0; i < vl_int; i++) begin
      logic        do_write;
      logic [63:0] elem_val;
      do_write = 1'b0;
      elem_val = '0;
      if (op == VSLIDEUP && !use_scalar_op) begin
        if (64'(unsigned'(i)) >= stride) begin
          int src_i;
          src_i    = i - int'(stride[31:0]);
          do_write = vm || elem_mask[i];
          for (int k = 0; k < sew_b; k++) elem_val[8*k +: 8] = vs2_bytes[src_i * sew_b + k];
        end
      end else if (op == VSLIDEUP && use_scalar_op) begin
        do_write = vm || elem_mask[i];
        if (i == 0) elem_val = scalar_op;
        else for (int k = 0; k < sew_b; k++) elem_val[8*k +: 8] = vs2_bytes[(i - 1) * sew_b + k];
      end else if (op == VSLIDEDOWN && use_scalar_op) begin
        do_write = vm || elem_mask[i];
        if (i == (vl_int - 1)) elem_val = scalar_op;
        else for (int k = 0; k < sew_b; k++) elem_val[8*k +: 8] = vs2_bytes[(i + 1) * sew_b + k];
      end else begin
        do_write = vm || elem_mask[i];
        if ((stride < 64'(unsigned'(vlmax_el))) && ((i + int'(stride[31:0])) < vlmax_el)) begin
          int src_i;
          src_i = i + int'(stride[31:0]);
          for (int k = 0; k < sew_b; k++) elem_val[8*k +: 8] = vs2_bytes[src_i * sew_b + k];
        end else begin
          elem_val = '0; // RVV 1.0 Sec 16.3.2 out-of-bounds zero-fill
        end
      end

      if (do_write) begin
        for (int k = 0; k < sew_b; k++) begin
          int unsigned g_b, row_idx, in_row_b, sb, w_addr;
          g_b      = i * sew_b + k;
          row_idx  = g_b / RowBytes;
          in_row_b = g_b % RowBytes;
          sb       = shuffle_index(16'(in_row_b), NrLanes, vsew);
          w_addr   = int'(vaddr(vd, NrLanes, VLEN)) + row_idx;
          ref_vrf[w_addr][sb >> 3][sb[2:0]] = elem_val[8*k +: 8];
        end
      end
    end

    insn_q.push_back(ins);
    commit_order_q.push_back(id_alloc);
  endtask

  task automatic check_vrfs(input string phase);
    int mism;
    mism = 0;
    for (int w = 0; w < VRFWords; w++) begin
      for (int l = 0; l < NrLanes; l++) begin
        for (int b = 0; b < 8; b++) begin
          if (dut_vrf[w][l][b] !== ref_vrf[w][l][b]) begin
            if (mism < 5) begin
              $display("[ERROR] NrLanes=%0d %s VRF mismatch @word=%0d lane=%0d byte=%0d: got=0x%02x exp=0x%02x",
                       NrLanes, phase, w, l, b, dut_vrf[w][l][b], ref_vrf[w][l][b]);
            end
            mism++;
          end
        end
      end
    end
    if (mism != 0) err_cnt_o += mism;
  endtask

  task automatic drain_stream(input string phase, input logic enable_stalls);
    int     cycles;
    logic   hold_req;
    logic   hold_op [NrLanes];
    logic   hold_msk;
    vid_t   fgnt_vid [NrLanes];

    cycles   = 0;
    hold_req = 1'b0;
    hold_msk = 1'b0;
    for (int l = 0; l < NrLanes; l++) begin
      hold_op[l]   = 1'b0;
      fgnt_pipe[l] = '0;
      fgnt_vid[l]  = '0;
    end

    while ((insn_q.size() > 0) || (commit_order_q.size() > 0)) begin
      // Drive pe_req
      if (!hold_req && (insn_q.size() > 0) && !pe_vinsn_running[insn_q[0].id]) begin
        if (!enable_stalls || ((next_rand() % 4) != 0)) begin
          hold_req          = 1'b1;
          req_id            = insn_q[0].id;
          req_op            = insn_q[0].op;
          req_vm            = insn_q[0].vm;
          req_eew_vs2       = insn_q[0].eew_vs2;
          req_use_vs2       = insn_q[0].use_vs2;
          req_scalar_op     = insn_q[0].scalar_op;
          req_use_scalar_op = insn_q[0].use_scalar_op;
          req_stride        = insn_q[0].stride;
          req_is_stride_np2 = insn_q[0].is_stride_np2;
          req_vfu           = insn_q[0].vfu;
          req_vd            = insn_q[0].vd;
          req_use_vd        = insn_q[0].use_vd;
          req_vl            = insn_q[0].vl;
          req_vtype         = insn_q[0].vtype;
        end
      end
      pe_req_valid = hold_req;

      // Drive per-lane sldu_operand_i
      for (int l = 0; l < NrLanes; l++) begin
        if (!hold_op[l] && (op_q[l].size() > 0)) begin
          if (!enable_stalls || ((next_rand() % 3) != 0)) begin
            hold_op[l]      = 1'b1;
            sldu_operand[l] = op_q[l][0];
          end
        end
        sldu_operand_valid[l] = hold_op[l];
      end

      // Drive mask_i
      if (!hold_msk && (msk_q.size() > 0)) begin
        if (!enable_stalls || ((next_rand() % 3) != 0)) begin
          hold_msk  = 1'b1;
          mask_data = msk_q[0].data;
        end
      end
      mask_valid = hold_msk ? msk_q[0].vld_mask : '0;

      // Drive sldu_result_gnt_i & sldu_result_final_gnt_i
      for (int l = 0; l < NrLanes; l++) begin
        sldu_result_final_gnt[l] = fgnt_pipe[l][0];
        if (fgnt_pipe[l] != '0) begin
          // Stream register full until previous bank write final_gnt completes
          sldu_result_gnt[l] = 1'b0;
        end else if (!enable_stalls) begin
          sldu_result_gnt[l] = 1'b1;
        end else begin
          sldu_result_gnt[l] = ((next_rand() % 3) != 0);
        end
      end

      begin
        logic                   req_hs;
        logic [NrLanes-1:0]     op_hs;
        logic                   msk_hs;
        logic [NrLanes-1:0]     res_hs;
        vaddr_t [NrLanes-1:0]   res_addr_s;
        elen_t  [NrLanes-1:0]   res_wdata_s;
        strb_t  [NrLanes-1:0]   res_be_s;
        vid_t   [NrLanes-1:0]   res_id_s;
        logic [NrVInsn-1:0]     done_s;

        #1; // Sample pre-edge steady-state combinational signals
        req_hs      = pe_req_valid && pe_req_ready;
        msk_hs      = (|mask_valid) && mask_ready;
        done_s      = pe_vinsn_done;
        res_addr_s  = sldu_result_addr;
        res_wdata_s = sldu_result_wdata;
        res_be_s    = sldu_result_be;
        res_id_s    = sldu_result_id;
        for (int l = 0; l < NrLanes; l++) begin
          op_hs[l]  = sldu_operand_valid[l] && sldu_operand_ready[l];
          res_hs[l] = sldu_result_req[l] && sldu_result_gnt[l];
        end

        // Check pe_vinsn_done_o ordering and final_gnt completion
        for (int id_i = 0; id_i < NrVInsn; id_i++) begin
          if (done_s[id_i]) begin
            if ((commit_order_q.size() == 0) || (vid_t'(id_i) != commit_order_q[0])) begin
              $display("[ERROR] NrLanes=%0d %s out-of-order or spurious pe_vinsn_done[%0d]", NrLanes, phase, id_i);
              err_cnt_o++;
            end else begin
              for (int l = 0; l < NrLanes; l++) begin
                if ((fgnt_vid[l] == vid_t'(id_i)) && (fgnt_pipe[l][2:1] != '0)) begin
                  $display("[ERROR] NrLanes=%0d %s premature pe_vinsn_done[%0d] before final_gnt on lane %0d",
                           NrLanes, phase, id_i, l);
                  err_cnt_o++;
                end
              end
              void'(commit_order_q.pop_front());
            end
          end
        end

        @(posedge clk_i);
        #1;
        cycles++;
        if (cycles > 25000) begin
          $display("[FATAL] NrLanes=%0d %s timed out (rem_insn=%0d rem_commit=%0d rem_op0=%0d rem_msk=%0d)",
                   NrLanes, phase, insn_q.size(), commit_order_q.size(), op_q[0].size(), msk_q.size());
          err_cnt_o += 100;
          insn_q.delete();
          commit_order_q.delete();
          return;
        end

        for (int id_i = 0; id_i < NrVInsn; id_i++) begin
          if (done_s[id_i]) pe_vinsn_running[id_i] = 1'b0;
        end

        if (req_hs) begin
          pe_vinsn_running[insn_q[0].id] = 1'b1;
          void'(insn_q.pop_front());
          hold_req = 1'b0;
        end

        for (int l = 0; l < NrLanes; l++) begin
          if (op_hs[l]) begin
            void'(op_q[l].pop_front());
            hold_op[l] = 1'b0;
          end
        end

        if (msk_hs) begin
          void'(msk_q.pop_front());
          hold_msk = 1'b0;
        end

        for (int l = 0; l < NrLanes; l++) begin
          fgnt_pipe[l] = {1'b0, fgnt_pipe[l][2:1]};
          if (res_hs[l]) begin
            int dly;
            if (int'(res_addr_s[l]) >= VRFWords) begin
              $display("[ERROR] NrLanes=%0d %s out-of-range VRF addr %0d", NrLanes, phase, res_addr_s[l]);
              err_cnt_o++;
            end else begin
              for (int b = 0; b < 8; b++) begin
                if (res_be_s[l][b]) begin
                  dut_vrf[res_addr_s[l]][l][b] = res_wdata_s[l][8*b +: 8];
                end
              end
            end
            dly = enable_stalls ? (next_rand() % 3) : 0;
            fgnt_pipe[l][dly] = 1'b1;
            fgnt_vid[l]       = res_id_s[l];
          end
        end
      end
    end

    // Wait 3 idle cycles and check that no unconsumed operand/mask beats remain
    repeat (3) begin
      pe_req_valid          = 1'b0;
      sldu_operand_valid    = '0;
      mask_valid            = '0;
      sldu_result_gnt       = '1;
      sldu_result_final_gnt = '0;
      @(posedge clk_i);
      #1;
    end

    for (int l = 0; l < NrLanes; l++) begin
      if (op_q[l].size() != 0) begin
        $display("[ERROR] NrLanes=%0d %s left %0d unconsumed operand beats on lane %0d",
                 NrLanes, phase, op_q[l].size(), l);
        err_cnt_o++;
        op_q[l].delete();
      end
    end
    if (msk_q.size() != 0) begin
      $display("[ERROR] NrLanes=%0d %s left %0d unconsumed mask beats", NrLanes, phase, msk_q.size());
      err_cnt_o++;
      msk_q.delete();
    end

    check_vrfs(phase);
  endtask

  // Standalone p2_stride_gen verification (including post-reset idle state!)
  task automatic test_unit_p2_stride_gen();
    // Immediately after reset before any valid_i, valid_o and stride_p2_o must be 0
    #1;
    if ((u_p2_valid_o !== 1'b0) || (u_p2_stride_o !== '0) || (u_p2_popc_o !== '0)) begin
      $display("[ERROR] NrLanes=%0d p2_stride_gen non-idle out of reset: valid=%b stride=0x%0x popc=%0d",
               NrLanes, u_p2_valid_o, u_p2_stride_o, u_p2_popc_o);
      err_cnt_o++;
    end

    // Load stride_i = 0
    u_p2_stride_i = '0;
    u_p2_valid_i  = 1'b1;
    u_p2_update_i = 1'b0;
    @(posedge clk_i); #1;
    u_p2_valid_i  = 1'b0;
    if ((u_p2_valid_o !== 1'b0) || (u_p2_stride_o !== '0) || (u_p2_popc_o !== '0)) begin
      $display("[ERROR] NrLanes=%0d p2_stride_gen failed zero-stride load", NrLanes);
      err_cnt_o++;
    end

    // Sweep every stride 1 .. RowBytes-1
    for (int s = 1; s < RowBytes; s++) begin
      int rem, exp_popc;
      rem = s;
      exp_popc = 0;
      for (int b = 0; b < StrideW; b++) exp_popc += ((s >> b) & 1);

      u_p2_stride_i = s[StrideW-1:0];
      u_p2_valid_i  = 1'b1;
      u_p2_update_i = logic'(s & 1); // also test valid_i priority when update_i=1
      @(posedge clk_i); #1;
      u_p2_valid_i  = 1'b0;
      u_p2_update_i = 1'b0;

      for (int step = exp_popc; step >= 1; step--) begin
        int exp_lsb;
        exp_lsb = rem & (-rem);
        if ((u_p2_valid_o !== 1'b1) || (int'(u_p2_stride_o) !== exp_lsb) || (int'(u_p2_popc_o) !== step)) begin
          $display("[ERROR] NrLanes=%0d p2_stride_gen s=%0d step=%0d got(v=%b,p2=%0d,popc=%0d) exp(1,%0d,%0d)",
                   NrLanes, s, step, u_p2_valid_o, u_p2_stride_o, u_p2_popc_o, exp_lsb, step);
          err_cnt_o++;
        end
        rem -= exp_lsb;
        u_p2_update_i = 1'b1;
        @(posedge clk_i); #1;
        u_p2_update_i = 1'b0;
      end

      if ((u_p2_valid_o !== 1'b0) || (u_p2_stride_o !== '0) || (u_p2_popc_o !== '0)) begin
        $display("[ERROR] NrLanes=%0d p2_stride_gen s=%0d did not clear after final update", NrLanes, s);
        err_cnt_o++;
      end
    end
  endtask

  // Interactive unordered tree reduction test (VREDSUM on ALU and VFREDUSUM on MFPU)
  task automatic test_unord_reduction(input logic is_mfpu);
    vid_t        id_u;
    int          n_steps, cyc;
    elen_t       lane_acc [NrLanes];
    elen_t       rx_words [NrLanes];
    elen_t       exp_sum;
    logic        done_seen;
    sldu_mux_e   exp_mux;

    alloc_vid(id_u);
    n_steps = $clog2(NrLanes) + 1;
    exp_sum = '0;
    exp_mux = is_mfpu ? MFPU_RED : ALU_RED;
    for (int l = 0; l < NrLanes; l++) begin
      lane_acc[l] = {32'(next_rand()), 32'(next_rand())};
      exp_sum    += lane_acc[l];
    end

    req_id            = id_u;
    req_op            = is_mfpu ? VFREDUSUM : VREDSUM;
    req_vm            = 1'b1;
    req_eew_vs2       = EW32;
    req_use_vs2       = 1'b1;
    req_scalar_op     = '0;
    req_use_scalar_op = 1'b0;
    req_stride        = '0;
    req_is_stride_np2 = 1'b0;
    req_vfu           = is_mfpu ? VFU_MFpu : VFU_Alu;
    req_vd            = 5'd4;
    req_use_vd        = 1'b1;
    req_vl            = vlen_t'(NrLanes * 2);
    req_vtype         = '{vill: 1'b0, vma: 1'b0, vta: 1'b0, vsew: EW32, vlmul: LMUL_1};
    pe_req_valid      = 1'b1;

    cyc = 0;
    while (!(pe_req_valid && pe_req_ready)) begin
      @(posedge clk_i); #1;
      cyc++;
      if (cyc > 200) begin err_cnt_o++; return; end
    end
    @(posedge clk_i); #1;
    pe_req_valid           = 1'b0;
    pe_vinsn_running[id_u] = 1'b1;
    done_seen              = 1'b0;

    for (int s = 0; s < n_steps; s++) begin
      logic [NrLanes-1:0] sent_op, got_red;
      sent_op = '0;
      got_red = '0;
      cyc     = 0;
      while ((sent_op != '1) || (got_red != '1)) begin
        for (int l = 0; l < NrLanes; l++) begin
          sldu_operand[l]       = lane_acc[l];
          sldu_operand_valid[l] = ~sent_op[l];
          sldu_result_gnt[l]    = ((cyc + l) % 2 == 0) || (cyc > 6);
        end
        #1;
        if (|sldu_result_req) begin
          $display("[ERROR] NrLanes=%0d unordered reduction asserted sldu_result_req", NrLanes);
          err_cnt_o++;
        end
        if ((|sldu_red_valid) && (sldu_mux_sel !== exp_mux)) begin
          $display("[ERROR] NrLanes=%0d unordered reduction wrong sldu_mux_sel=%0d exp=%0d",
                   NrLanes, sldu_mux_sel, exp_mux);
          err_cnt_o++;
        end
        begin
          logic [NrLanes-1:0] op_hs_u, red_hs_u;
          logic               done_u;
          for (int l = 0; l < NrLanes; l++) begin
            op_hs_u[l]  = sldu_operand_valid[l] && sldu_operand_ready[l];
            red_hs_u[l] = sldu_red_valid[l] && sldu_result_gnt[l];
            if (red_hs_u[l]) rx_words[l] = sldu_result_wdata[l];
          end
          done_u = pe_vinsn_done[id_u];
          @(posedge clk_i); #1;
          sent_op |= op_hs_u;
          got_red |= red_hs_u;
          if (done_u) begin
            done_seen              = 1'b1;
            pe_vinsn_running[id_u] = 1'b0;
          end
        end
        cyc++;
        if (cyc > 500) begin
          $display("[FATAL] NrLanes=%0d unordered reduction timed out at step %0d", NrLanes, s);
          err_cnt_o += 10;
          return;
        end
      end
      sldu_operand_valid = '0;
      if (s < (n_steps - 1)) begin
        int mask_s;
        mask_s = (2 << s) - 1;
        for (int l = 0; l < NrLanes; l++) begin
          if ((l & mask_s) == mask_s) lane_acc[l] += rx_words[l];
        end
      end else if (rx_words[0] !== exp_sum) begin
        $display("[ERROR] NrLanes=%0d unordered reduction final sum got=0x%016x exp=0x%016x",
                 NrLanes, rx_words[0], exp_sum);
        err_cnt_o++;
      end
    end

    cyc = 0;
    while (!done_seen && (cyc < 20)) begin
      #1;
      if (pe_vinsn_done[id_u]) begin
        done_seen              = 1'b1;
        pe_vinsn_running[id_u] = 1'b0;
      end
      @(posedge clk_i); #1;
      cyc++;
    end
    if (!done_seen) begin
      $display("[ERROR] NrLanes=%0d unordered reduction missing pe_vinsn_done", NrLanes);
      err_cnt_o++;
    end
  endtask

  // Interactive ordered reduction test (VFREDOSUM with multi-cycle gnt stall on final beat)
  task automatic test_ord_reduction(input int vl_cnt, input logic vm_flag);
    vid_t  id_o;
    elen_t run_sum, elem_v;
    int    cyc;
    logic  done_seen;

    alloc_vid(id_o);
    run_sum = 64'h0102_0304_0506_0708;

    req_id            = id_o;
    req_op            = VFREDOSUM;
    req_vm            = vm_flag;
    req_eew_vs2       = EW64;
    req_use_vs2       = 1'b1;
    req_scalar_op     = '0;
    req_use_scalar_op = 1'b0;
    req_stride        = '0;
    req_is_stride_np2 = 1'b0;
    req_vfu           = VFU_MFpu;
    req_vd            = 5'd6;
    req_use_vd        = 1'b1;
    req_vl            = vlen_t'(vl_cnt);
    req_vtype         = '{vill: 1'b0, vma: 1'b0, vta: 1'b0, vsew: EW64, vlmul: LMUL_2};
    pe_req_valid      = 1'b1;

    cyc = 0;
    while (!(pe_req_valid && pe_req_ready)) begin
      @(posedge clk_i); #1;
      cyc++;
      if (cyc > 200) begin err_cnt_o++; return; end
    end
    @(posedge clk_i); #1;
    pe_req_valid           = 1'b0;
    pe_vinsn_running[id_o] = 1'b1;
    done_seen              = 1'b0;

    for (int i = 0; i < vl_cnt; i++) begin
      int   src_ln, tgt_ln;
      logic sent_b, got_b;
      src_ln  = i % NrLanes;
      tgt_ln  = (i == (vl_cnt - 1)) ? 0 : ((src_ln + 1) % NrLanes);
      elem_v  = {32'(next_rand()), 32'(next_rand())};
      run_sum = run_sum + elem_v;
      sent_b  = 1'b0;
      got_b   = 1'b0;
      cyc     = 0;

      while (!sent_b || !got_b) begin
        sldu_operand               = '0;
        sldu_operand_valid         = '0;
        sldu_operand[src_ln]       = run_sum;
        sldu_operand_valid[src_ln] = ~sent_b;
        // Deliberately stall sldu_result_gnt on tgt_ln for 3 cycles on the final beat!
        sldu_result_gnt            = '0;
        sldu_result_gnt[tgt_ln]    = (i == (vl_cnt - 1)) ? (cyc >= 4) : ((cyc % 2) == 1);

        #1;
        if (!got_b && pe_vinsn_done[id_o]) begin
          $display("[ERROR] NrLanes=%0d VFREDOSUM premature pe_vinsn_done before final beat grant (i=%0d/%0d)",
                   NrLanes, i, vl_cnt);
          err_cnt_o++;
        end
        begin
          logic op_hs_o, red_hs_o, done_o_s;
          op_hs_o  = sldu_operand_valid[src_ln] && sldu_operand_ready[src_ln];
          red_hs_o = sldu_red_valid[tgt_ln] && sldu_result_gnt[tgt_ln];
          done_o_s = pe_vinsn_done[id_o];
          if (red_hs_o && (sldu_result_wdata[tgt_ln] !== run_sum)) begin
            $display("[ERROR] NrLanes=%0d VFREDOSUM beat %0d wdata mismatch: got=0x%016x exp=0x%016x",
                     NrLanes, i, sldu_result_wdata[tgt_ln], run_sum);
            err_cnt_o++;
          end
          @(posedge clk_i); #1;
          if (op_hs_o)  sent_b = 1'b1;
          if (red_hs_o) got_b  = 1'b1;
          if (done_o_s) begin
            done_seen              = 1'b1;
            pe_vinsn_running[id_o] = 1'b0;
          end
        end
        cyc++;
        if (cyc > 500) begin
          $display("[FATAL] NrLanes=%0d VFREDOSUM timed out at beat %0d/%0d", NrLanes, i, vl_cnt);
          err_cnt_o += 10;
          return;
        end
      end
    end

    sldu_operand_valid = '0;
    sldu_result_gnt    = '1;
    cyc                = 0;
    while (!done_seen && (cyc < 20)) begin
      #1;
      if (pe_vinsn_done[id_o]) begin
        done_seen              = 1'b1;
        pe_vinsn_running[id_o] = 1'b0;
      end
      @(posedge clk_i); #1;
      cyc++;
    end
    if (!done_seen) begin
      $display("[ERROR] NrLanes=%0d VFREDOSUM missing pe_vinsn_done", NrLanes);
      err_cnt_o++;
    end
  endtask

  initial begin
    done_o                = 1'b0;
    err_cnt_o             = 0;
    u_p2_stride_i         = '0;
    u_p2_valid_i          = 1'b0;
    u_p2_update_i         = 1'b0;
    pe_req_valid          = 1'b0;
    pe_vinsn_running      = '0;
    sldu_operand          = '0;
    sldu_operand_valid    = '0;
    sldu_result_gnt       = '1;
    sldu_result_final_gnt = '0;
    mask_data             = '0;
    mask_valid            = '0;
    next_vid              = '0;

    wait (rst_ni === 1'b0);
    wait (rst_ni === 1'b1);
    wait (start_i === 1'b1);
    rng_state = (seed_i ^ (NrLanes * 32'h13579BDF)) & 32'h7fffffff;
    if (rng_state == 0) rng_state = 1;

    // 1. Standalone p2_stride_gen check (must run immediately out of reset!)
    test_unit_p2_stride_gen();

    // 2. Directed corner-case suite (no stalls first, then full random stalls)
    init_vrfs(1);
    // 2a. Null/huge-stride VSLIDEUP (vm=1 & vm=0) interleaved with 1-elem VSLIDE1UP/1DOWN and multi-row NP2
    enqueue_slide(VSLIDEUP,   1'b0, '0, 64'd8,                     1'b1, EW32, EW32, LMUL_1, 8,  5'd0, 1'b0); // stride == vl
    enqueue_slide(VSLIDEUP,   1'b0, '0, 64'h8000_0000_0000_0002,   1'b0, EW32, EW32, LMUL_1, 12, 5'd1, 1'b0); // 64b overflow stride, vm=0
    enqueue_slide(VSLIDEUP,   1'b1, 64'hCAFE_BABE_1234_5678, 64'd1,1'b1, EW32, EW32, LMUL_1, 1,  5'd2, 1'b0); // VSLIDE1UP vl=1
    enqueue_slide(VSLIDEDOWN, 1'b1, 64'hDEAD_BEEF_8765_4321, 64'd1,1'b0, EW32, EW32, LMUL_1, 1,  5'd3, 1'b1); // VSLIDE1DOWN vl=1 sparse mask
    // Multi-row VSLIDE1DOWN at exact row + 1 element and non-row-aligned offsets
    enqueue_slide(VSLIDEDOWN, 1'b1, 64'h1122_3344_5566_7788, 64'd1,1'b1, EW32, EW32, LMUL_2, (RowBytes/4)+1, 5'd4,  1'b0);
    enqueue_slide(VSLIDEDOWN, 1'b1, 64'hA5A5_5A5A_C3C3_3C3C, 64'd1,1'b1, EW32, EW32, LMUL_2, (RowBytes/4)+3, 5'd28, 1'b0);
    enqueue_slide(VSLIDEDOWN, 1'b1, 64'hF0E1_D2C3_B4A5_9687, 64'd1,1'b0, EW16, EW16, LMUL_1, 5,              5'd30, 1'b0);
    enqueue_slide(VSLIDEUP,   1'b1, 64'h99AA_BBCC_DDEE_FF00, 64'd1,1'b0, EW16, EW16, LMUL_2, (RowBytes/2)+1, 5'd6,  1'b0);
    // Multi-row NP2 strides where popc(stride)>1 with intra-row offset = 0, P2 (1,2), and NP2 (3,5)
    enqueue_slide(VSLIDEUP,   1'b0, '0, 64'(3*(RowBytes/8)),       1'b1, EW64, EW64, LMUL_4, 4*(RowBytes/8)+1, 5'd8,  1'b0);
    enqueue_slide(VSLIDEUP,   1'b0, '0, 64'((RowBytes/4)+1),       1'b1, EW32, EW32, LMUL_2, 2*(RowBytes/4)+3, 5'd12, 1'b0);
    enqueue_slide(VSLIDEUP,   1'b0, '0, 64'((RowBytes/4)+3),       1'b0, EW32, EW32, LMUL_2, 2*(RowBytes/4)+5, 5'd14, 1'b0);
    enqueue_slide(VSLIDEDOWN, 1'b0, '0, 64'((RowBytes/2)+3),       1'b1, EW16, EW16, LMUL_2, 2*(RowBytes/2)-2, 5'd16, 1'b0);
    // Commit-row boundary crossing: vl_b = RowBytes + 8, stride_b = RowBytes - 8 (2 rows written, 16 bytes total)
    enqueue_slide(VSLIDEUP,   1'b0, '0, 64'((RowBytes/8)-1),       1'b1, EW64, EW64, LMUL_2, (RowBytes/8)+1,   5'd18, 1'b0);
    // Out-of-bounds VSLIDEDOWN (partial mid-row, multi-row, exact vlmax, and 64-bit huge stride) across fractional & integer LMUL
    enqueue_slide(VSLIDEDOWN, 1'b0, '0, 64'd3,                     1'b1, EW32, EW32, LMUL_1_4, (VLenBytes/4)/4, 5'd20, 1'b0);
    enqueue_slide(VSLIDEDOWN, 1'b0, '0, 64'd5,                     1'b0, EW16, EW16, LMUL_1_2, (VLenBytes/2)/2, 5'd21, 1'b0);
    enqueue_slide(VSLIDEDOWN, 1'b0, '0, 64'(VLenBytes/8),          1'b1, EW64, EW64, LMUL_1,   VLenBytes/8,     5'd22, 1'b0);
    enqueue_slide(VSLIDEDOWN, 1'b0, '0, 64'h9000_0000_0000_0005,   1'b0, EW8,  EW8,  LMUL_1_8, VLenBytes/8,     5'd23, 1'b0);
    // Dynamic EEW reshuffling (eew_vs2 != vsew) on stride=0, intra=0 VSLIDEUP, P2, and NP2
    enqueue_slide(VSLIDEDOWN, 1'b0, '0, 64'd0,                     1'b1, EW8,  EW32, LMUL_1,   VLenBytes/4,     5'd24, 1'b0);
    enqueue_slide(VSLIDEUP,   1'b0, '0, 64'(RowBytes/2),           1'b1, EW64, EW16, LMUL_1,   (RowBytes/2)+6,  5'd25, 1'b0);
    enqueue_slide(VSLIDEUP,   1'b0, '0, 64'd2,                     1'b0, EW16, EW64, LMUL_1,   (VLenBytes/8),   5'd26, 1'b0);
    enqueue_slide(VSLIDEDOWN, 1'b0, '0, 64'd3,                     1'b1, EW32, EW8,  LMUL_1,   (RowBytes)+7,    5'd27, 1'b0);
    drain_stream("directed_stalls", 1'b1);

    // 3. Unordered & Ordered Inter-Lane Reductions
    test_unord_reduction(1'b0); // ALU VREDSUM
    test_unord_reduction(1'b1); // MFPU VFREDUSUM
    test_ord_reduction(1, 1'b1);
    test_ord_reduction(NrLanes + 3, 1'b0);
    test_ord_reduction(2 * NrLanes + 1, 1'b1);

    // 4. Randomized pipelined slide stress stream (60 instructions per NrLanes instance)
    init_vrfs(2);
    for (int t = 0; t < 60; t++) begin
      ara_op_e    r_op;
      logic       r_sc, r_vm, r_sp;
      vew_e       r_esrc, r_edst;
      vlmul_e     r_lmul;
      int         r_sew_b, r_vlm_b, r_vlm_el, r_vl;
      elen_t      r_stride, r_scalar;
      logic [4:0] r_vd;
      vlmul_e     lmul_tbl [7];

      lmul_tbl[0] = LMUL_1_8;
      lmul_tbl[1] = LMUL_1_4;
      lmul_tbl[2] = LMUL_1_2;
      lmul_tbl[3] = LMUL_1;
      lmul_tbl[4] = LMUL_2;
      lmul_tbl[5] = LMUL_4;
      lmul_tbl[6] = LMUL_8;

      r_op     = ((next_rand() & 1) != 0) ? VSLIDEUP : VSLIDEDOWN;
      r_sc     = ((next_rand() % 4) == 0);
      r_vm     = ((next_rand() & 1) != 0);
      r_sp     = ((next_rand() % 4) == 0);
      r_edst   = vew_e'(next_rand() & 3);
      r_esrc   = ((next_rand() % 3) == 0) ? vew_e'(next_rand() & 3) : r_edst;
      begin
        int l_sel;
        l_sel  = next_rand() % 7;
        r_lmul = lmul_tbl[l_sel];
      end
      r_sew_b  = 1 << int'(r_edst);
      r_vlm_b  = get_vlmax_bytes(r_lmul);
      if (r_vlm_b < r_sew_b) begin
        r_lmul  = LMUL_1;
        r_vlm_b = VLenBytes;
      end
      r_vlm_el = r_vlm_b / r_sew_b;
      // Keep LMUL_8 lengths reasonable for fast simulation while still covering multi-row
      if (r_vlm_el > 64) r_vl = 1 + (next_rand() % 64);
      else               r_vl = 1 + (next_rand() % r_vlm_el);

      begin
        int s_sel;
        s_sel = next_rand() % 6;
        case (s_sel)
          0: r_stride = 64'd0;
          1: r_stride = 64'(1 + (next_rand() % ((r_vl > 1) ? r_vl : 2)));
          2: r_stride = 64'(r_vl);
          3: r_stride = 64'((r_vlm_el > 2) ? (r_vlm_el - 2) : 1);
          4: r_stride = 64'(r_vlm_el + (next_rand() % 8));
          default: r_stride = {1'b1, 31'(next_rand()), 32'(next_rand())};
        endcase
      end
      r_scalar = {32'(next_rand()), 32'(next_rand())};

      // Align vd to LMUL group so VRF writes never exceed 32 registers
      case (r_lmul)
        LMUL_2 : r_vd = 5'((next_rand() % 16) * 2);
        LMUL_4 : r_vd = 5'((next_rand() % 8)  * 4);
        LMUL_8 : r_vd = 5'((next_rand() % 4)  * 8);
        default: r_vd = 5'(next_rand() % 32);
      endcase

      enqueue_slide(r_op, r_sc, r_scalar, r_stride, r_vm, r_esrc, r_edst, r_lmul, r_vl, r_vd, r_sp);
      if (((t + 1) % 12) == 0) begin
        drain_stream($sformatf("random_pipelined_%0d", t), 1'b1);
      end
    end
    if (insn_q.size() > 0) begin
      drain_stream("random_pipelined_tail", 1'b1);
    end

    done_o = 1'b1;
  end

endmodule

module tb;
  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  logic start = 1'b0;
  int   seed  = 101;

  always #2.5 clk = ~clk;

  logic done_l2, done_l4, done_l8;
  int   err_l2,  err_l4,  err_l8;

  sldu_lane_harness #(.NrLanes(2), .VLEN(1024)) i_h2 (
    .clk_i(clk), .rst_ni(rst_n), .seed_i(seed), .start_i(start), .done_o(done_l2), .err_cnt_o(err_l2)
  );
  sldu_lane_harness #(.NrLanes(4), .VLEN(1024)) i_h4 (
    .clk_i(clk), .rst_ni(rst_n), .seed_i(seed), .start_i(start), .done_o(done_l4), .err_cnt_o(err_l4)
  );
  sldu_lane_harness #(.NrLanes(8), .VLEN(1024)) i_h8 (
    .clk_i(clk), .rst_ni(rst_n), .seed_i(seed), .start_i(start), .done_o(done_l8), .err_cnt_o(err_l8)
  );

  initial begin
    void'($value$plusargs("seed=%d", seed));
    rst_n = 1'b0;
    start = 1'b0;
    repeat (5) @(posedge clk);
    #1;
    rst_n = 1'b1;
    start = 1'b1;

    wait (done_l2 && done_l4 && done_l8);
    @(posedge clk);

    if ((err_l2 + err_l4 + err_l8) == 0) begin
      $display("PASS: All NrLanes={2,4,8} SLDU + p2_stride_gen checks passed (seed=%0d)", seed);
      $finish;
    end else begin
      $display("[ERROR] Total errors=%0d (L2=%0d, L4=%0d, L8=%0d) (seed=%0d)",
               err_l2 + err_l4 + err_l8, err_l2, err_l4, err_l8, seed);
      $fatal(1, "SLDU verification failed");
    end
  end

  initial begin
    #4000000;
    $display("[FATAL] Global simulation watchdog timeout");
    $fatal(1, "Watchdog timeout");
  end
endmodule
