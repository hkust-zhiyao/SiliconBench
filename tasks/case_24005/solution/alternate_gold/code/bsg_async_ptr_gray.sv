`include "bsg_defines.sv"

module bsg_async_ptr_gray #(parameter `BSG_INV_PARAM(lg_size_p )
                            ,parameter use_negedge_for_launch_p=0
                            ,parameter use_async_reset_p = 0)
   (
    input w_clk_i
    , input w_reset_i
    , input w_inc_i
    , input r_clk_i
    , output [lg_size_p-1:0] w_ptr_binary_r_o
    , output [lg_size_p-1:0] w_ptr_gray_r_o
    , output [lg_size_p-1:0] w_ptr_gray_r_rsync_o
    );

   logic [lg_size_p-1:0] w_ptr_r, w_ptr_n;
   logic [lg_size_p-1:0] w_ptr_p1_r, w_ptr_p1_n, w_ptr_p2;
   logic [lg_size_p-1:0] w_ptr_gray_n, w_ptr_gray_r, w_ptr_gray_r_rsync;

   assign w_ptr_p2     = w_ptr_p1_r + 1'b1;
   assign w_ptr_n      = w_inc_i ? w_ptr_p1_r : w_ptr_r;
   assign w_ptr_p1_n   = w_inc_i ? w_ptr_p2   : w_ptr_p1_r;
   assign w_ptr_gray_n = w_inc_i ? ((w_ptr_p1_r >> 1) ^ w_ptr_p1_r) : w_ptr_gray_r;

   if (use_async_reset_p == 0) begin: sync
     if (use_negedge_for_launch_p) begin
       always @(negedge w_clk_i)
         if (w_reset_i) begin w_ptr_r <= 0; w_ptr_p1_r <= 1; end
         else begin w_ptr_r <= w_ptr_n; w_ptr_p1_r <= w_ptr_p1_n; end
     end else begin
       always @(posedge w_clk_i)
         if (w_reset_i) begin w_ptr_r <= 0; w_ptr_p1_r <= 1; end
         else begin w_ptr_r <= w_ptr_n; w_ptr_p1_r <= w_ptr_p1_n; end
     end
   end else begin: async
     if (use_negedge_for_launch_p) begin : BSG_NO_CLOCK_GATE_1
       logic [lg_size_p-1:0] async_reset_w_ptr_r, async_reset_w_ptr_p1_r;
       assign w_ptr_r = async_reset_w_ptr_r;
       assign w_ptr_p1_r = async_reset_w_ptr_p1_r;
       always @(negedge w_clk_i or posedge w_reset_i)
         if (w_reset_i) begin async_reset_w_ptr_r <= 0; async_reset_w_ptr_p1_r <= 1; end
         else begin async_reset_w_ptr_r <= w_ptr_n; async_reset_w_ptr_p1_r <= w_ptr_p1_n; end
     end else begin : BSG_NO_CLOCK_GATE_2
       logic [lg_size_p-1:0] async_reset_w_ptr_r, async_reset_w_ptr_p1_r;
       assign w_ptr_r = async_reset_w_ptr_r;
       assign w_ptr_p1_r = async_reset_w_ptr_p1_r;
       always @(posedge w_clk_i or posedge w_reset_i)
         if (w_reset_i) begin async_reset_w_ptr_r <= 0; async_reset_w_ptr_p1_r <= 1; end
         else begin async_reset_w_ptr_r <= w_ptr_n; async_reset_w_ptr_p1_r <= w_ptr_p1_n; end
     end
   end

   assign w_ptr_binary_r_o = w_ptr_r;

   bsg_launch_sync_sync #(.width_p(lg_size_p)
                          ,.use_negedge_for_launch_p(use_negedge_for_launch_p)
                          ,.use_async_reset_p(use_async_reset_p)) ptr_sync
     (.iclk_i(w_clk_i)
      ,.iclk_reset_i(w_reset_i)
      ,.oclk_i(r_clk_i)
      ,.iclk_data_i(w_ptr_gray_n)
      ,.iclk_data_o(w_ptr_gray_r)
      ,.oclk_data_o(w_ptr_gray_r_rsync)
      );

   assign w_ptr_gray_r_o       = w_ptr_gray_r;
   assign w_ptr_gray_r_rsync_o = w_ptr_gray_r_rsync;
endmodule

`BSG_ABSTRACT_MODULE(bsg_async_ptr_gray)
