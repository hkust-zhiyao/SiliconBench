`timescale 1ns/1ps
module trial #(parameter SG=0)(output reg done=0);
  reg clk=0, src_clk=0, dest_clk=0, sg_clk=0;
  always #5 clk=~clk;
  always #(SG ? 7 : 5) src_clk=~src_clk;
  always #11 dest_clk=~dest_clk;
  always #13 sg_clk=~sg_clk;
  reg resetn=0, src_ext=1, dest_ext=1, sg_ext=1, en=1, pause=0;
  wire req_rst,src_rst,dest_rst,sg_rst,req_en,src_en,dest_en,sg_en;
  reg [3:0] req_pipe=0,src_pipe=0,dest_pipe=0,sg_pipe=0;
  wire req_ack=req_pipe[3], src_ack=src_pipe[3], dest_ack=dest_pipe[3], sg_ack=sg_pipe[3];
  wire [11:0] dbg; integer seed=0;
  reg saw_req_rst_low=0;
  realtime last_src_edge=-1.0, last_dest_edge=-1.0, last_sg_edge=-1.0;
  always @(posedge src_clk) last_src_edge = $realtime;
  always @(posedge dest_clk) last_dest_edge = $realtime;
  always @(posedge sg_clk) last_sg_edge = $realtime;
  always @(posedge src_rst) if (resetn && $realtime != last_src_edge)
    $fatal(1,"source reset release not aligned to src_clk posedge");
  always @(posedge dest_rst) if (resetn && $realtime != last_dest_edge)
    $fatal(1,"destination reset release not aligned to dest_clk posedge");
  always @(posedge sg_rst) if (SG && resetn && $realtime != last_sg_edge)
    $fatal(1,"SG reset release not aligned to sg_clk posedge");
  axi_dmac_reset_manager #(.DMA_SG_TRANSFER(SG),.ASYNC_CLK_REQ_SRC(SG),.ASYNC_CLK_SRC_DEST(1),.ASYNC_CLK_DEST_REQ(1),.ASYNC_CLK_REQ_SG(1)) dut
  (.clk(clk),.resetn(resetn),.ctrl_enable(en),.ctrl_pause(pause),.ctrl_hwdesc(1'b1),
   .req_resetn(req_rst),.req_enable(req_en),.req_enabled(req_ack),
   .src_clk(src_clk),.src_ext_resetn(src_ext),.src_resetn(src_rst),.src_enable(src_en),.src_enabled(src_ack),
   .dest_clk(dest_clk),.dest_ext_resetn(dest_ext),.dest_resetn(dest_rst),.dest_enable(dest_en),.dest_enabled(dest_ack),
   .sg_clk(sg_clk),.sg_ext_resetn(sg_ext),.sg_resetn(sg_rst),.sg_enable(sg_en),.sg_enabled(sg_ack),.dbg_status(dbg));
  always @(posedge clk) if (!req_rst) req_pipe<=0; else req_pipe<={req_pipe[2:0],req_en};
  always @(posedge src_clk or negedge src_rst) if (!src_rst) src_pipe<=0; else src_pipe<={src_pipe[2:0],src_en};
  always @(posedge dest_clk or negedge dest_rst) if (!dest_rst) dest_pipe<=0; else dest_pipe<={dest_pipe[2:0],dest_en};
  always @(posedge sg_clk or negedge sg_rst) if (!sg_rst) sg_pipe<=0; else sg_pipe<={sg_pipe[2:0],sg_en};
  task running; begin wait(req_en && req_ack && src_en && src_ack && dest_en && dest_ack && (!SG || (sg_en && sg_ack))); end endtask
  task full_restart; begin
    wait(!req_en); wait(!req_rst); wait(req_rst); running();
  end endtask
  always @(negedge req_rst) if (resetn && (req_ack || src_ack || dest_ack || (SG && sg_ack)))
    $fatal(1,"reset before domains acknowledged shutdown");
  always @(negedge dest_rst) if (resetn && dest_ext && dest_ack)
    $fatal(1,"reset before domains acknowledged shutdown");
  always @(negedge src_rst) if (resetn && src_ext && src_ack)
    $fatal(1,"reset before domains acknowledged shutdown");
  always @(negedge sg_rst) if (SG && resetn && sg_ext && sg_ack)
    $fatal(1,"reset before domains acknowledged shutdown");
  initial begin
    seed=0; if ($value$plusargs("seed=%d",seed)) begin end
    repeat(3) @(negedge clk); resetn=1; running();
    // This pulse starts and ends between control clock edges.
    @(negedge clk); #(1+(seed%2)); src_ext=0; #1;
    if (src_rst!==0) $fatal(1,"source reset did not assert immediately SG=%0d",SG);
    #1; src_ext=1; #1; if(src_rst!==0) $fatal(1,"source reset release asynchronous");
    full_restart();
    @(negedge clk); #2; dest_ext=0; #1;
    if(dest_rst!==0) $fatal(1,"destination reset did not assert immediately");
    wait(!req_en);
    saw_req_rst_low = !req_rst;
    repeat(45) begin
      @(negedge clk);
      if (!req_rst) saw_req_rst_low = 1;
      if (req_en || dest_rst) $fatal(1,"restarted while external reset held");
    end
    dest_ext=1; #1; if(dest_rst!==0) $fatal(1,"destination reset release asynchronous");
    if (!saw_req_rst_low) wait(!req_rst);
    wait(req_rst); running();
    pause=1; wait(!req_en); repeat(30) @(negedge clk);
    if(!req_rst || !src_rst || !dest_rst) $fatal(1,"pause must preserve state");
    pause=0; running();
    // Disable/re-enable and interrupt the following startup before acknowledgements.
    en=0; wait(!req_en); wait(!req_rst); en=1; wait(req_en);
    @(posedge clk); @(posedge clk);
    @(negedge clk); #(1+(seed%2)); src_ext=0; #1; src_ext=1; full_restart();
    @(negedge clk); #2; sg_ext=0; #1;
    if (SG && sg_rst!==0) $fatal(1,"SG reset assertion");
    #1; sg_ext=1; #1; if (SG && sg_rst!==0) $fatal(1,"SG reset release asynchronous");
    if (SG) full_restart();
    else begin repeat(30) @(negedge clk); if(!req_en || !req_rst) $fatal(1,"disabled SG affected DMA"); end
    done=1;
  end
endmodule
module tb;
  wire [1:0] done;
  trial #(0) a(done[0]); trial #(1) b(done[1]);
  initial begin wait(&done); $display("PASS"); $finish; end
  initial begin #30000; $fatal(1,"timeout"); end
endmodule
