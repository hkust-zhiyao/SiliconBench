// Lockstep isolate-clear-drain RDC + segmented low-power gating + glitch-free flags for bsg_async_fifo

`include "bsg_defines.sv"

module bsg_async_fifo #(parameter `BSG_INV_PARAM(  lg_size_p )
                        , parameter `BSG_INV_PARAM(  width_p )
                        , parameter   control_width_p = 0
                        , parameter   and_data_with_valid_p = 0)
   (
    input    w_clk_i
    , input  w_reset_i
    , input  w_enq_i
    , input  [width_p-1:0] w_data_i
    , output w_full_o

    , input  r_clk_i
    , input  r_reset_i
    , input  r_deq_i
    , output [width_p-1:0] r_data_o
    , output r_valid_o
    );

   localparam int unsigned size_lp = 1 << lg_size_p;
   localparam int unsigned data_width_lp = width_p - control_width_p;
   localparam logic [lg_size_p:0] FULL_XOR_LP = (lg_size_p + 1)'(3) << (lg_size_p - 1);

   // Symmetric 4-phase cross-domain reset-isolation & synchronous pointer clear controller
   typedef enum logic [1:0] {
      RDC_RUN      = 2'd0,
      RDC_REQ_ISO  = 2'd1,
      RDC_CLR_WAIT = 2'd2,
      RDC_DRAIN    = 2'd3
   } rdc_state_e;

   rdc_state_e w_state_q = RDC_REQ_ISO;
   rdc_state_e r_state_q = RDC_REQ_ISO;
   logic       w_retrig_q = 1'b0, r_retrig_q = 1'b0;
   logic [1:0] w_drain_q  = 2'd2, r_drain_q  = 2'd2;

   logic w_req_lnch, w_req_rsync;
   logic r_req_lnch, r_req_wsync;

   wire w_req_d = (w_state_q == RDC_REQ_ISO) ||
                  ((w_state_q == RDC_RUN || w_state_q == RDC_DRAIN) && (w_reset_i || r_req_wsync));
   wire r_req_d = (r_state_q == RDC_REQ_ISO) ||
                  ((r_state_q == RDC_RUN || r_state_q == RDC_DRAIN) && (r_reset_i || w_req_rsync));

   bsg_launch_sync_sync #(.width_p(1)) u_wrst_sync (
      .iclk_i      (w_clk_i),
      .iclk_reset_i(1'b0),
      .oclk_i      (r_clk_i),
      .iclk_data_i (w_req_d),
      .iclk_data_o (w_req_lnch),
      .oclk_data_o (w_req_rsync)
   );

   bsg_launch_sync_sync #(.width_p(1)) u_rrst_sync (
      .iclk_i      (r_clk_i),
      .iclk_reset_i(1'b0),
      .oclk_i      (w_clk_i),
      .iclk_data_i (r_req_d),
      .iclk_data_o (r_req_lnch),
      .oclk_data_o (r_req_wsync)
   );

   always_ff @(posedge w_clk_i) begin
      if (w_reset_i) begin
         if (w_state_q == RDC_CLR_WAIT) begin
            w_retrig_q <= 1'b1;
         end else begin
            w_state_q  <= RDC_REQ_ISO;
            w_retrig_q <= 1'b0;
         end
         w_drain_q <= 2'd2;
      end else begin
         unique case (w_state_q)
            RDC_RUN: begin
               if (r_req_wsync) begin
                  w_state_q <= RDC_REQ_ISO;
               end
            end
            RDC_REQ_ISO: begin
               if (r_req_wsync) begin
                  w_state_q <= RDC_CLR_WAIT;
               end
            end
            RDC_CLR_WAIT: begin
               if (!r_req_wsync) begin
                  if (w_retrig_q) begin
                     w_retrig_q <= 1'b0;
                     w_state_q  <= RDC_REQ_ISO;
                  end else begin
                     w_drain_q <= 2'd2;
                     w_state_q <= RDC_DRAIN;
                  end
               end
            end
            RDC_DRAIN: begin
               if (r_req_wsync) begin
                  w_state_q <= RDC_REQ_ISO;
               end else if (w_drain_q != 2'd0) begin
                  w_drain_q <= w_drain_q - 2'd1;
               end else begin
                  w_state_q <= RDC_RUN;
               end
            end
            default: w_state_q <= RDC_REQ_ISO;
         endcase
      end
   end

   always_ff @(posedge r_clk_i) begin
      if (r_reset_i) begin
         if (r_state_q == RDC_CLR_WAIT) begin
            r_retrig_q <= 1'b1;
         end else begin
            r_state_q  <= RDC_REQ_ISO;
            r_retrig_q <= 1'b0;
         end
         r_drain_q <= 2'd2;
      end else begin
         unique case (r_state_q)
            RDC_RUN: begin
               if (w_req_rsync) begin
                  r_state_q <= RDC_REQ_ISO;
               end
            end
            RDC_REQ_ISO: begin
               if (w_req_rsync) begin
                  r_state_q <= RDC_CLR_WAIT;
               end
            end
            RDC_CLR_WAIT: begin
               if (!w_req_rsync) begin
                  if (r_retrig_q) begin
                     r_retrig_q <= 1'b0;
                     r_state_q  <= RDC_REQ_ISO;
                  end else begin
                     r_drain_q <= 2'd2;
                     r_state_q <= RDC_DRAIN;
                  end
               end
            end
            RDC_DRAIN: begin
               if (w_req_rsync) begin
                  r_state_q <= RDC_REQ_ISO;
               end else if (r_drain_q != 2'd0) begin
                  r_drain_q <= r_drain_q - 2'd1;
               end else begin
                  r_state_q <= RDC_RUN;
               end
            end
            default: r_state_q <= RDC_REQ_ISO;
         endcase
      end
   end

   // Clear pointers ONLY while both domains are safely isolated in RDC_CLR_WAIT!
   wire w_ptr_clr = (w_state_q == RDC_CLR_WAIT);
   wire r_ptr_clr = (r_state_q == RDC_CLR_WAIT);

   logic [lg_size_p:0] r_ptr_gray_r, w_ptr_gray_r;
   logic [lg_size_p:0] w_ptr_gray_r_rsync, r_ptr_gray_r_wsync;
   logic [lg_size_p:0] r_ptr_binary_r, w_ptr_binary_r;

   logic w_full_r  = 1'b1;
   logic r_valid_r = 1'b0;

   wire w_isolated = w_reset_i || r_req_wsync || (w_state_q != RDC_RUN);
   wire r_isolated = r_reset_i || w_req_rsync || (r_state_q != RDC_RUN);

   wire w_enq_eff = w_enq_i & ~w_full_r & ~w_isolated;
   wire r_deq_eff = r_deq_i & r_valid_r & ~r_isolated;

   wire [lg_size_p:0] w_ptr_binary_n = w_ptr_clr ? '0 : (w_ptr_binary_r + {{lg_size_p{1'b0}}, w_enq_eff});
   wire [lg_size_p:0] w_ptr_gray_n   = (w_ptr_binary_n >> 1) ^ w_ptr_binary_n;

   wire [lg_size_p:0] r_ptr_binary_n = r_ptr_clr ? '0 : (r_ptr_binary_r + {{lg_size_p{1'b0}}, r_deq_eff});
   wire [lg_size_p:0] r_ptr_gray_n   = (r_ptr_binary_n >> 1) ^ r_ptr_binary_n;

   wire [lg_size_p:0] w_full_target_gray = r_ptr_gray_r_wsync ^ FULL_XOR_LP;

   always_ff @(posedge w_clk_i) begin
      if (w_reset_i || r_req_wsync || (w_state_q == RDC_REQ_ISO) || (w_state_q == RDC_CLR_WAIT) ||
          ((w_state_q == RDC_DRAIN) && (w_drain_q != 2'd0)))
         w_full_r <= 1'b1;
      else
         w_full_r <= (w_ptr_gray_n == w_full_target_gray);
   end

   always_ff @(posedge r_clk_i) begin
      if (r_reset_i || w_req_rsync || (r_state_q == RDC_REQ_ISO) || (r_state_q == RDC_CLR_WAIT) ||
          ((r_state_q == RDC_DRAIN) && (r_drain_q != 2'd0)))
         r_valid_r <= 1'b0;
      else
         r_valid_r <= (r_ptr_gray_n != w_ptr_gray_r_rsync);
   end

   assign w_full_o  = w_full_r;
   assign r_valid_o = r_valid_r;

   if (data_width_lp > 0) begin : gen_data
      wire [data_width_lp-1:0] r_data_lo_raw;
      bsg_mem_1r1w #(.width_p(data_width_lp)
                     ,.els_p(size_lp)
                     ,.read_write_same_addr_p(0)
                     ) MSYNC_1r1w
        (.w_clk_i   (w_clk_i)
         ,.w_reset_i(w_reset_i)
         ,.w_v_i    (w_enq_eff)
         ,.w_addr_i (w_ptr_binary_r[0+:lg_size_p])
         ,.w_data_i (w_data_i[0+:data_width_lp])
         ,.r_v_i    (r_valid_r)
         ,.r_addr_i (r_ptr_binary_r[0+:lg_size_p])
         ,.r_data_o (r_data_lo_raw)
         );

      if (and_data_with_valid_p != 0) begin : fi
         bsg_and #(.width_p(data_width_lp), .harden_p(1)) ba_data
           (.a_i(r_data_lo_raw)
            ,.b_i({data_width_lp{r_valid_r}})
            ,.o  (r_data_o[0+:data_width_lp])
            );
      end else begin : fi_nogate
         assign r_data_o[0+:data_width_lp] = r_data_lo_raw;
      end
   end

   if (control_width_p > 0) begin : ctrl
      wire [control_width_p-1:0] r_ctrl_hi_raw;
      bsg_mem_1r1w #(.width_p(control_width_p)
                     ,.els_p(size_lp)
                     ,.read_write_same_addr_p(0)
                     ) MSYNC_1r1w
        (.w_clk_i   (w_clk_i)
         ,.w_reset_i(w_reset_i)
         ,.w_v_i    (w_enq_eff)
         ,.w_addr_i (w_ptr_binary_r[0+:lg_size_p])
         ,.w_data_i (w_data_i[(width_p-1)-:control_width_p])
         ,.r_v_i    (r_valid_r)
         ,.r_addr_i (r_ptr_binary_r[0+:lg_size_p])
         ,.r_data_o (r_ctrl_hi_raw)
         );

      bsg_and #(.width_p(control_width_p), .harden_p(1)) ba_ctrl
        (.a_i(r_ctrl_hi_raw)
         ,.b_i({control_width_p{r_valid_r}})
         ,.o  (r_data_o[(width_p-1)-:control_width_p])
         );
   end

   bsg_async_ptr_gray #(.lg_size_p(lg_size_p+1)) bapg_wr
   (.w_clk_i(w_clk_i)
    ,.w_reset_i(w_ptr_clr)
    ,.w_inc_i(w_enq_eff)
    ,.r_clk_i(r_clk_i)
    ,.w_ptr_binary_r_o(w_ptr_binary_r)
    ,.w_ptr_gray_r_o(w_ptr_gray_r)
    ,.w_ptr_gray_r_rsync_o(w_ptr_gray_r_rsync)
    );

   bsg_async_ptr_gray #(.lg_size_p(lg_size_p+1)) bapg_rd
   (.w_clk_i(r_clk_i)
    ,.w_reset_i(r_ptr_clr)
    ,.w_inc_i(r_deq_eff)
    ,.r_clk_i(w_clk_i)
    ,.w_ptr_binary_r_o(r_ptr_binary_r)
    ,.w_ptr_gray_r_o(r_ptr_gray_r)
    ,.w_ptr_gray_r_rsync_o(r_ptr_gray_r_wsync)
    );

endmodule

`BSG_ABSTRACT_MODULE(bsg_async_fifo)
