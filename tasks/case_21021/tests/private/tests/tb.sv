`timescale 1ns / 1ps

// Multi-bank AXI4 write-commit slave memory model:
// Writes are buffered until (bvalid && bready) handshakes; reads sample committed DRAM only.
module axi_commit_mem_model #(
    parameter ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 64,
    parameter STRB_WIDTH = (DATA_WIDTH / 8),
    parameter ID_WIDTH   = 8,
    parameter MEM_WORDS  = 512
) (
    input  wire                   clk,
    input  wire                   rst,
    input  wire [1:0]             b_mode,      // 0: 1-cycle fast B; 1: hold until >=35 bursts or idle timeout; 2: hold B (manual stall)
    input  wire                   stall_aw_w,  // backpressure AW/W
    input  wire                   stall_ar,    // backpressure AR
    input  wire [3:0]             rd_lat,      // extra AR->R latency cycles

    input  wire [ID_WIDTH-1:0]    s_axi_awid,
    input  wire [ADDR_WIDTH-1:0]  s_axi_awaddr,
    input  wire [7:0]             s_axi_awlen,
    input  wire [2:0]             s_axi_awsize,
    input  wire [1:0]             s_axi_awburst,
    input  wire                   s_axi_awvalid,
    output wire                   s_axi_awready,

    input  wire [DATA_WIDTH-1:0]  s_axi_wdata,
    input  wire [STRB_WIDTH-1:0]  s_axi_wstrb,
    input  wire                   s_axi_wlast,
    input  wire                   s_axi_wvalid,
    output wire                   s_axi_wready,

    output reg  [ID_WIDTH-1:0]    s_axi_bid,
    output wire [1:0]             s_axi_bresp,
    output reg                    s_axi_bvalid,
    input  wire                   s_axi_bready,

    input  wire [ID_WIDTH-1:0]    s_axi_arid,
    input  wire [ADDR_WIDTH-1:0]  s_axi_araddr,
    input  wire [7:0]             s_axi_arlen,
    input  wire [2:0]             s_axi_arsize,
    input  wire [1:0]             s_axi_arburst,
    input  wire                   s_axi_arvalid,
    output wire                   s_axi_arready,

    output reg  [ID_WIDTH-1:0]    s_axi_rid,
    output reg  [DATA_WIDTH-1:0]  s_axi_rdata,
    output wire [1:0]             s_axi_rresp,
    output reg                    s_axi_rlast,
    output reg                    s_axi_rvalid,
    input  wire                   s_axi_rready,

    output reg  [31:0]            aw_count,
    output reg  [ADDR_WIDTH-1:0]  last_awaddr,
    output reg                    stale_read_seen
);
    localparam Q_DEPTH = 64;
    localparam WORD_SHIFT = $clog2(STRB_WIDTH);

    reg [DATA_WIDTH-1:0] dram     [0:MEM_WORDS-1];
    reg                  comm_vld [0:MEM_WORDS-1];

    reg [ADDR_WIDTH-1:0] q_awaddr [0:Q_DEPTH-1];
    reg [7:0]            q_awlen  [0:Q_DEPTH-1];
    reg [ID_WIDTH-1:0]   q_awid   [0:Q_DEPTH-1];
    integer              aw_wr_p = 0;
    integer              b_rd_p  = 0;

    reg [DATA_WIDTH-1:0] q_wdata  [0:Q_DEPTH-1][0:15];
    reg [STRB_WIDTH-1:0] q_wstrb  [0:Q_DEPTH-1][0:15];
    integer              w_wr_p  = 0;
    integer              w_beat  = 0;

    integer              b_idle_timer = 0;
    reg                  b_drain_phase = 1'b0;

    reg                  rd_active = 1'b0;
    reg [3:0]            rd_wait_q = 4'd0;
    reg [ADDR_WIDTH-1:0] rd_addr_q = 0;
    reg [7:0]            rd_rem_q  = 8'd0;
    reg [ID_WIDTH-1:0]   rd_id_q   = 0;

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    wire aw_space = (aw_wr_p - b_rd_p) < (Q_DEPTH - 2);
    wire w_space  = (w_wr_p - b_rd_p)  < (Q_DEPTH - 2);
    assign s_axi_awready = !rst && !stall_aw_w && aw_space;
    assign s_axi_wready  = !rst && !stall_aw_w && w_space;
    assign s_axi_arready = !rst && !stall_ar && !rd_active;

    integer idx, b_i, ln_i;

    initial begin
        for (idx = 0; idx < MEM_WORDS; idx = idx + 1) begin
            dram[idx] = {STRB_WIDTH{8'hDE}};
            comm_vld[idx] = 1'b0;
        end
    end

    wire integer ready_bursts = ((aw_wr_p < w_wr_p) ? aw_wr_p : w_wr_p) - b_rd_p;

    always @(posedge clk) begin
        if (rst) begin
            aw_wr_p <= 0;
            w_wr_p  <= 0;
            w_beat  <= 0;
            b_rd_p  <= 0;
            b_idle_timer <= 0;
            b_drain_phase <= 1'b0;
            s_axi_bvalid <= 1'b0;
            s_axi_bid    <= 0;
            rd_active    <= 1'b0;
            rd_wait_q    <= 4'd0;
            s_axi_rvalid <= 1'b0;
            s_axi_rlast  <= 1'b0;
            s_axi_rdata  <= 0;
            s_axi_rid    <= 0;
            aw_count     <= 32'd0;
            last_awaddr  <= 0;
            stale_read_seen <= 1'b0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                q_awaddr[aw_wr_p % Q_DEPTH] <= s_axi_awaddr;
                q_awlen[aw_wr_p % Q_DEPTH]  <= s_axi_awlen;
                q_awid[aw_wr_p % Q_DEPTH]   <= s_axi_awid;
                aw_wr_p     <= aw_wr_p + 1;
                aw_count    <= aw_count + 32'd1;
                last_awaddr <= s_axi_awaddr;
                b_idle_timer <= 0;
            end else if (ready_bursts > 0) begin
                b_idle_timer <= b_idle_timer + 1;
            end else begin
                b_idle_timer <= 0;
            end

            if (s_axi_wvalid && s_axi_wready) begin
                q_wdata[w_wr_p % Q_DEPTH][w_beat] <= s_axi_wdata;
                q_wstrb[w_wr_p % Q_DEPTH][w_beat] <= s_axi_wstrb;
                if (s_axi_wlast) begin
                    w_wr_p <= w_wr_p + 1;
                    w_beat <= 0;
                end else begin
                    w_beat <= w_beat + 1;
                end
            end

            // Commit to DRAM ONLY when (s_axi_bvalid && s_axi_bready) completes!
            if (s_axi_bvalid && s_axi_bready) begin
                for (b_i = 0; b_i <= q_awlen[b_rd_p % Q_DEPTH]; b_i = b_i + 1) begin : commit_loop
                    integer waddr;
                    waddr = ((q_awaddr[b_rd_p % Q_DEPTH] >> WORD_SHIFT) + b_i) % MEM_WORDS;
                    for (ln_i = 0; ln_i < STRB_WIDTH; ln_i = ln_i + 1) begin
                        if (q_wstrb[b_rd_p % Q_DEPTH][b_i][ln_i]) begin
                            dram[waddr][ln_i*8 +: 8] <= q_wdata[b_rd_p % Q_DEPTH][b_i][ln_i*8 +: 8];
                            comm_vld[waddr] <= 1'b1;
                        end
                    end
                end
                b_rd_p <= b_rd_p + 1;
                s_axi_bvalid <= 1'b0;
                if (ready_bursts <= 1) begin
                    b_drain_phase <= 1'b0;
                end
            end else if (!s_axi_bvalid && ready_bursts > 0) begin
                if (b_mode == 2'd0) begin
                    s_axi_bvalid <= 1'b1;
                    s_axi_bid    <= q_awid[b_rd_p % Q_DEPTH];
                end else if (b_mode == 2'd1) begin
                    if (b_drain_phase || ready_bursts >= 35 || b_idle_timer >= 90) begin
                        b_drain_phase <= 1'b1;
                        s_axi_bvalid  <= 1'b1;
                        s_axi_bid     <= q_awid[b_rd_p % Q_DEPTH];
                    end
                end
                // b_mode == 2'd2 holds s_axi_bvalid == 0 manually
            end

            // Read channel
            if (!rd_active) begin
                if (s_axi_arvalid && s_axi_arready) begin
                    rd_active <= 1'b1;
                    rd_id_q   <= s_axi_arid;
                    if (rd_lat == 4'd0) begin
                        rd_wait_q    <= 4'd0;
                        s_axi_rid    <= s_axi_arid;
                        s_axi_rdata  <= dram[(s_axi_araddr >> WORD_SHIFT) % MEM_WORDS];
                        if (!comm_vld[(s_axi_araddr >> WORD_SHIFT) % MEM_WORDS])
                            stale_read_seen <= 1'b1;
                        s_axi_rlast  <= (s_axi_arlen == 8'd0);
                        s_axi_rvalid <= 1'b1;
                        rd_addr_q    <= s_axi_araddr + STRB_WIDTH;
                        rd_rem_q     <= s_axi_arlen;
                    end else begin
                        rd_wait_q    <= rd_lat;
                        rd_addr_q    <= s_axi_araddr;
                        rd_rem_q     <= s_axi_arlen;
                        s_axi_rvalid <= 1'b0;
                    end
                end
            end else if (rd_wait_q != 4'd0) begin
                rd_wait_q <= rd_wait_q - 4'd1;
                if (rd_wait_q == 4'd1) begin
                    s_axi_rid    <= rd_id_q;
                    s_axi_rdata  <= dram[(rd_addr_q >> WORD_SHIFT) % MEM_WORDS];
                    if (!comm_vld[(rd_addr_q >> WORD_SHIFT) % MEM_WORDS])
                        stale_read_seen <= 1'b1;
                    s_axi_rlast  <= (rd_rem_q == 8'd0);
                    s_axi_rvalid <= 1'b1;
                    rd_addr_q    <= rd_addr_q + STRB_WIDTH;
                end
            end else if (s_axi_rvalid && s_axi_rready) begin
                if (rd_rem_q == 8'd0) begin
                    s_axi_rvalid <= 1'b0;
                    s_axi_rlast  <= 1'b0;
                    rd_active    <= 1'b0;
                end else begin
                    s_axi_rdata <= dram[(rd_addr_q >> WORD_SHIFT) % MEM_WORDS];
                    if (!comm_vld[(rd_addr_q >> WORD_SHIFT) % MEM_WORDS])
                        stale_read_seen <= 1'b1;
                    rd_addr_q   <= rd_addr_q + STRB_WIDTH;
                    rd_rem_q    <= rd_rem_q - 8'd1;
                    s_axi_rlast <= (rd_rem_q == 8'd1);
                end
            end
        end
    end
endmodule


module tb #(
    parameter integer SEED = 101
);
    // =========================================================================
    // DUT0: AXI_CH=1, Async Clocks (c_clk=6ns, s_clk=8ns, m_clk=8ns, a_clk=14ns)
    // =========================================================================
    reg c_clk = 1'b0;
    reg s_clk = 1'b0;
    reg m_clk = 1'b0;
    reg a_clk = 1'b0;

    always #3 c_clk = ~c_clk; // 166.7 MHz
    always #4 s_clk = ~s_clk; // 125.0 MHz
    always #4 m_clk = ~m_clk; // 125.0 MHz
    always #7 a_clk = ~a_clk; //  71.4 MHz (slower than c_clk/s_clk/m_clk!)

    reg         d0_rst = 1'b1;
    wire        d0_s_rst_out, d0_m_rst_out;
    reg  [31:0] d0_s_tdata  = 32'd0;
    reg  [3:0]  d0_s_tkeep  = 4'd0;
    reg         d0_s_tvalid = 1'b0;
    wire        d0_s_tready;
    reg         d0_s_tlast  = 1'b0;
    reg  [2:0]  d0_s_tid    = 3'd0;
    reg  [2:0]  d0_s_tdest  = 3'd0;
    reg  [1:0]  d0_s_tuser  = 2'd0;

    wire [31:0] d0_m_tdata;
    wire [3:0]  d0_m_tkeep;
    wire        d0_m_tvalid;
    reg         d0_m_tready = 1'b0;
    wire        d0_m_tlast;
    wire [2:0]  d0_m_tid;
    wire [2:0]  d0_m_tdest;
    wire [1:0]  d0_m_tuser;

    wire [7:0]  d0_awid, d0_awlen, d0_arid, d0_arlen, d0_bid, d0_rid, d0_wstrb;
    wire [11:0] d0_awaddr, d0_araddr;
    wire [2:0]  d0_awsize, d0_awprot, d0_arsize, d0_arprot;
    wire [1:0]  d0_awburst, d0_arburst, d0_bresp, d0_rresp;
    wire        d0_awlock, d0_arlock, d0_awvalid, d0_awready, d0_wlast, d0_wvalid, d0_wready;
    wire        d0_bvalid, d0_bready, d0_arvalid, d0_arready, d0_rlast, d0_rvalid, d0_rready;
    wire [3:0]  d0_awcache, d0_arcache;
    wire [63:0] d0_wdata, d0_rdata;

    reg  [11:0] d0_cfg_base   = 12'h000;
    reg  [11:0] d0_cfg_mask   = 12'h7ff; // 2 KB ring
    reg         d0_cfg_enable = 1'b0;
    reg         d0_cfg_reset  = 1'b0;

    wire [12:0] d0_sts_occ;
    wire        d0_sts_empty, d0_sts_full, d0_sts_reset, d0_sts_active, d0_sts_perr;

    reg  [1:0]  d0_b_mode     = 2'd0;
    reg         d0_stall_aw_w = 1'b0;
    reg         d0_stall_ar   = 1'b0;
    reg  [3:0]  d0_rd_lat     = 4'd0;
    wire [31:0] d0_aw_count;
    wire [11:0] d0_last_awaddr;
    wire        d0_stale_rd;

    // Gate BVALID briefly to test BVALID held while BREADY is masked or normal
    axi_vfifo #(
        .AXI_CH(1),
        .AXI_DATA_WIDTH(64),
        .AXI_ADDR_WIDTH(12),
        .AXI_STRB_WIDTH(8),
        .AXI_ID_WIDTH(8),
        .AXI_MAX_BURST_LEN(16),
        .AXIS_DATA_WIDTH(32),
        .AXIS_KEEP_ENABLE(1),
        .AXIS_KEEP_WIDTH(4),
        .AXIS_LAST_ENABLE(1),
        .AXIS_ID_ENABLE(1),
        .AXIS_ID_WIDTH(3),
        .AXIS_DEST_ENABLE(1),
        .AXIS_DEST_WIDTH(3),
        .AXIS_USER_ENABLE(1),
        .AXIS_USER_WIDTH(2),
        .LEN_WIDTH(12),
        .MAX_SEG_WIDTH(32),
        .WRITE_FIFO_DEPTH(16),
        .WRITE_MAX_BURST_LEN(4),
        .READ_FIFO_DEPTH(32),
        .READ_MAX_BURST_LEN(4)
    ) dut0 (
        .clk(c_clk),
        .rst(d0_rst),
        .s_axis_clk(s_clk),
        .s_axis_rst(d0_rst),
        .s_axis_rst_out(d0_s_rst_out),
        .s_axis_tdata(d0_s_tdata),
        .s_axis_tkeep(d0_s_tkeep),
        .s_axis_tvalid(d0_s_tvalid),
        .s_axis_tready(d0_s_tready),
        .s_axis_tlast(d0_s_tlast),
        .s_axis_tid(d0_s_tid),
        .s_axis_tdest(d0_s_tdest),
        .s_axis_tuser(d0_s_tuser),
        .m_axis_clk(m_clk),
        .m_axis_rst(d0_rst),
        .m_axis_rst_out(d0_m_rst_out),
        .m_axis_tdata(d0_m_tdata),
        .m_axis_tkeep(d0_m_tkeep),
        .m_axis_tvalid(d0_m_tvalid),
        .m_axis_tready(d0_m_tready),
        .m_axis_tlast(d0_m_tlast),
        .m_axis_tid(d0_m_tid),
        .m_axis_tdest(d0_m_tdest),
        .m_axis_tuser(d0_m_tuser),
        .m_axi_clk(a_clk),
        .m_axi_rst(d0_rst),
        .m_axi_awid(d0_awid),
        .m_axi_awaddr(d0_awaddr),
        .m_axi_awlen(d0_awlen),
        .m_axi_awsize(d0_awsize),
        .m_axi_awburst(d0_awburst),
        .m_axi_awlock(d0_awlock),
        .m_axi_awcache(d0_awcache),
        .m_axi_awprot(d0_awprot),
        .m_axi_awvalid(d0_awvalid),
        .m_axi_awready(d0_awready),
        .m_axi_wdata(d0_wdata),
        .m_axi_wstrb(d0_wstrb),
        .m_axi_wlast(d0_wlast),
        .m_axi_wvalid(d0_wvalid),
        .m_axi_wready(d0_wready),
        .m_axi_bid(d0_bid),
        .m_axi_bresp(d0_bresp),
        .m_axi_bvalid(d0_bvalid),
        .m_axi_bready(d0_bready),
        .m_axi_arid(d0_arid),
        .m_axi_araddr(d0_araddr),
        .m_axi_arlen(d0_arlen),
        .m_axi_arsize(d0_arsize),
        .m_axi_arburst(d0_arburst),
        .m_axi_arlock(d0_arlock),
        .m_axi_arcache(d0_arcache),
        .m_axi_arprot(d0_arprot),
        .m_axi_arvalid(d0_arvalid),
        .m_axi_arready(d0_arready),
        .m_axi_rid(d0_rid),
        .m_axi_rdata(d0_rdata),
        .m_axi_rresp(d0_rresp),
        .m_axi_rlast(d0_rlast),
        .m_axi_rvalid(d0_rvalid),
        .m_axi_rready(d0_rready),
        .cfg_fifo_base_addr(d0_cfg_base),
        .cfg_fifo_size_mask(d0_cfg_mask),
        .cfg_enable(d0_cfg_enable),
        .cfg_reset(d0_cfg_reset),
        .sts_fifo_occupancy(d0_sts_occ),
        .sts_fifo_empty(d0_sts_empty),
        .sts_fifo_full(d0_sts_full),
        .sts_reset(d0_sts_reset),
        .sts_active(d0_sts_active),
        .sts_hdr_parity_err(d0_sts_perr)
    );

    // Inject unrequested BVALID pulse while d0_bready == 0 when d0_spurious_b == 1
    // (or hold BVALID across !BREADY) to verify strict (bvalid && bready) handshake compliance!
    reg  d0_probe_bvalid_when_unready = 1'b0;
    wire d0_mem_bvalid;
    assign d0_bvalid = d0_mem_bvalid | (d0_probe_bvalid_when_unready & ~d0_bready);

    axi_commit_mem_model #(
        .ADDR_WIDTH(12),
        .DATA_WIDTH(64),
        .STRB_WIDTH(8),
        .ID_WIDTH(8),
        .MEM_WORDS(512)
    ) mem0 (
        .clk(a_clk),
        .rst(d0_rst),
        .b_mode(d0_b_mode),
        .stall_aw_w(d0_stall_aw_w),
        .stall_ar(d0_stall_ar),
        .rd_lat(d0_rd_lat),
        .s_axi_awid(d0_awid),
        .s_axi_awaddr(d0_awaddr),
        .s_axi_awlen(d0_awlen),
        .s_axi_awsize(d0_awsize),
        .s_axi_awburst(d0_awburst),
        .s_axi_awvalid(d0_awvalid),
        .s_axi_awready(d0_awready),
        .s_axi_wdata(d0_wdata),
        .s_axi_wstrb(d0_wstrb),
        .s_axi_wlast(d0_wlast),
        .s_axi_wvalid(d0_wvalid),
        .s_axi_wready(d0_wready),
        .s_axi_bid(d0_bid),
        .s_axi_bresp(d0_bresp),
        .s_axi_bvalid(d0_mem_bvalid),
        .s_axi_bready(d0_bready),
        .s_axi_arid(d0_arid),
        .s_axi_araddr(d0_araddr),
        .s_axi_arlen(d0_arlen),
        .s_axi_arsize(d0_arsize),
        .s_axi_arburst(d0_arburst),
        .s_axi_arvalid(d0_arvalid),
        .s_axi_arready(d0_arready),
        .s_axi_rid(d0_rid),
        .s_axi_rdata(d0_rdata),
        .s_axi_rresp(d0_rresp),
        .s_axi_rlast(d0_rlast),
        .s_axi_rvalid(d0_rvalid),
        .s_axi_rready(d0_rready),
        .aw_count(d0_aw_count),
        .last_awaddr(d0_last_awaddr),
        .stale_read_seen(d0_stale_rd)
    );

    // =========================================================================
    // DUT1: AXI_CH=2, Multi-Segment (CH_SEG_CNT=2, SEG_CNT=4), WRITE_FIFO_DEPTH=16
    // =========================================================================
    reg         d1_rst = 1'b1;
    wire        d1_s_rst_out, d1_m_rst_out;
    reg  [63:0] d1_s_tdata  = 64'd0;
    reg  [7:0]  d1_s_tkeep  = 8'd0;
    reg         d1_s_tvalid = 1'b0;
    wire        d1_s_tready;
    reg         d1_s_tlast  = 1'b0;
    reg  [2:0]  d1_s_tid    = 3'd0;
    reg  [2:0]  d1_s_tdest  = 3'd0;
    reg  [1:0]  d1_s_tuser  = 2'd0;

    wire [63:0] d1_m_tdata;
    wire [7:0]  d1_m_tkeep;
    wire        d1_m_tvalid;
    reg         d1_m_tready = 1'b0;
    wire        d1_m_tlast;
    wire [2:0]  d1_m_tid;
    wire [2:0]  d1_m_tdest;
    wire [1:0]  d1_m_tuser;

    wire [15:0]  d1_awid, d1_awlen, d1_arid, d1_arlen, d1_bid, d1_rid, d1_wstrb;
    wire [21:0]  d1_awaddr, d1_araddr;
    wire [5:0]   d1_awsize, d1_awprot, d1_arsize, d1_arprot;
    wire [3:0]   d1_awburst, d1_arburst, d1_bresp, d1_rresp;
    wire [1:0]   d1_awlock, d1_arlock, d1_awvalid, d1_awready, d1_wlast, d1_wvalid, d1_wready;
    wire [1:0]   d1_bvalid, d1_bready, d1_arvalid, d1_arready, d1_rlast, d1_rvalid, d1_rready;
    wire [7:0]   d1_awcache, d1_arcache;
    wire [127:0] d1_wdata, d1_rdata;

    reg  [21:0]  d1_cfg_base   = {11'h400, 11'h000};
    reg  [10:0]  d1_cfg_mask   = 11'h3ff; // 1 KB per channel
    reg          d1_cfg_enable = 1'b0;
    reg          d1_cfg_reset  = 1'b0;

    wire [23:0]  d1_sts_occ;
    wire [1:0]   d1_sts_empty, d1_sts_full, d1_sts_reset, d1_sts_active;
    wire         d1_sts_perr;

    reg          d1_stall_axi = 1'b0;
    wire [31:0]  d1_aw_cnt0, d1_aw_cnt1;
    wire [10:0]  d1_last_aw0, d1_last_aw1;
    wire         d1_stale0, d1_stale1;

    axi_vfifo #(
        .AXI_CH(2),
        .AXI_DATA_WIDTH(64),
        .AXI_ADDR_WIDTH(11),
        .AXI_STRB_WIDTH(8),
        .AXI_ID_WIDTH(8),
        .AXI_MAX_BURST_LEN(16),
        .AXIS_DATA_WIDTH(64),
        .AXIS_KEEP_ENABLE(1),
        .AXIS_KEEP_WIDTH(8),
        .AXIS_LAST_ENABLE(1),
        .AXIS_ID_ENABLE(1),
        .AXIS_ID_WIDTH(3),
        .AXIS_DEST_ENABLE(1),
        .AXIS_DEST_WIDTH(3),
        .AXIS_USER_ENABLE(1),
        .AXIS_USER_WIDTH(2),
        .LEN_WIDTH(11),
        .MAX_SEG_WIDTH(32),
        .WRITE_FIFO_DEPTH(16),
        .WRITE_MAX_BURST_LEN(4),
        .READ_FIFO_DEPTH(32),
        .READ_MAX_BURST_LEN(4)
    ) dut1 (
        .clk(c_clk),
        .rst(d1_rst),
        .s_axis_clk(s_clk),
        .s_axis_rst(d1_rst),
        .s_axis_rst_out(d1_s_rst_out),
        .s_axis_tdata(d1_s_tdata),
        .s_axis_tkeep(d1_s_tkeep),
        .s_axis_tvalid(d1_s_tvalid),
        .s_axis_tready(d1_s_tready),
        .s_axis_tlast(d1_s_tlast),
        .s_axis_tid(d1_s_tid),
        .s_axis_tdest(d1_s_tdest),
        .s_axis_tuser(d1_s_tuser),
        .m_axis_clk(m_clk),
        .m_axis_rst(d1_rst),
        .m_axis_rst_out(d1_m_rst_out),
        .m_axis_tdata(d1_m_tdata),
        .m_axis_tkeep(d1_m_tkeep),
        .m_axis_tvalid(d1_m_tvalid),
        .m_axis_tready(d1_m_tready),
        .m_axis_tlast(d1_m_tlast),
        .m_axis_tid(d1_m_tid),
        .m_axis_tdest(d1_m_tdest),
        .m_axis_tuser(d1_m_tuser),
        .m_axi_clk({s_clk, a_clk}),
        .m_axi_rst({d1_rst, d1_rst}),
        .m_axi_awid(d1_awid),
        .m_axi_awaddr(d1_awaddr),
        .m_axi_awlen(d1_awlen),
        .m_axi_awsize(d1_awsize),
        .m_axi_awburst(d1_awburst),
        .m_axi_awlock(d1_awlock),
        .m_axi_awcache(d1_awcache),
        .m_axi_awprot(d1_awprot),
        .m_axi_awvalid(d1_awvalid),
        .m_axi_awready(d1_awready),
        .m_axi_wdata(d1_wdata),
        .m_axi_wstrb(d1_wstrb),
        .m_axi_wlast(d1_wlast),
        .m_axi_wvalid(d1_wvalid),
        .m_axi_wready(d1_wready),
        .m_axi_bid(d1_bid),
        .m_axi_bresp(d1_bresp),
        .m_axi_bvalid(d1_bvalid),
        .m_axi_bready(d1_bready),
        .m_axi_arid(d1_arid),
        .m_axi_araddr(d1_araddr),
        .m_axi_arlen(d1_arlen),
        .m_axi_arsize(d1_arsize),
        .m_axi_arburst(d1_arburst),
        .m_axi_arlock(d1_arlock),
        .m_axi_arcache(d1_arcache),
        .m_axi_arprot(d1_arprot),
        .m_axi_arvalid(d1_arvalid),
        .m_axi_arready(d1_arready),
        .m_axi_rid(d1_rid),
        .m_axi_rdata(d1_rdata),
        .m_axi_rresp(d1_rresp),
        .m_axi_rlast(d1_rlast),
        .m_axi_rvalid(d1_rvalid),
        .m_axi_rready(d1_rready),
        .cfg_fifo_base_addr(d1_cfg_base),
        .cfg_fifo_size_mask(d1_cfg_mask),
        .cfg_enable(d1_cfg_enable),
        .cfg_reset(d1_cfg_reset),
        .sts_fifo_occupancy(d1_sts_occ),
        .sts_fifo_empty(d1_sts_empty),
        .sts_fifo_full(d1_sts_full),
        .sts_reset(d1_sts_reset),
        .sts_active(d1_sts_active),
        .sts_hdr_parity_err(d1_sts_perr)
    );

    axi_commit_mem_model #(.ADDR_WIDTH(11), .DATA_WIDTH(64), .STRB_WIDTH(8), .ID_WIDTH(8), .MEM_WORDS(256)) mem1_ch0 (
        .clk(a_clk), .rst(d1_rst), .b_mode(2'd0), .stall_aw_w(d1_stall_axi), .stall_ar(1'b0), .rd_lat(4'd2),
        .s_axi_awid(d1_awid[7:0]), .s_axi_awaddr(d1_awaddr[10:0]), .s_axi_awlen(d1_awlen[7:0]),
        .s_axi_awsize(d1_awsize[2:0]), .s_axi_awburst(d1_awburst[1:0]), .s_axi_awvalid(d1_awvalid[0]), .s_axi_awready(d1_awready[0]),
        .s_axi_wdata(d1_wdata[63:0]), .s_axi_wstrb(d1_wstrb[7:0]), .s_axi_wlast(d1_wlast[0]), .s_axi_wvalid(d1_wvalid[0]), .s_axi_wready(d1_wready[0]),
        .s_axi_bid(d1_bid[7:0]), .s_axi_bresp(d1_bresp[1:0]), .s_axi_bvalid(d1_bvalid[0]), .s_axi_bready(d1_bready[0]),
        .s_axi_arid(d1_arid[7:0]), .s_axi_araddr(d1_araddr[10:0]), .s_axi_arlen(d1_arlen[7:0]),
        .s_axi_arsize(d1_arsize[2:0]), .s_axi_arburst(d1_arburst[1:0]), .s_axi_arvalid(d1_arvalid[0]), .s_axi_arready(d1_arready[0]),
        .s_axi_rid(d1_rid[7:0]), .s_axi_rdata(d1_rdata[63:0]), .s_axi_rresp(d1_rresp[1:0]), .s_axi_rlast(d1_rlast[0]), .s_axi_rvalid(d1_rvalid[0]), .s_axi_rready(d1_rready[0]),
        .aw_count(d1_aw_cnt0), .last_awaddr(d1_last_aw0), .stale_read_seen(d1_stale0)
    );

    axi_commit_mem_model #(.ADDR_WIDTH(11), .DATA_WIDTH(64), .STRB_WIDTH(8), .ID_WIDTH(8), .MEM_WORDS(256)) mem1_ch1 (
        .clk(s_clk), .rst(d1_rst), .b_mode(2'd0), .stall_aw_w(d1_stall_axi), .stall_ar(1'b0), .rd_lat(4'd1),
        .s_axi_awid(d1_awid[15:8]), .s_axi_awaddr(d1_awaddr[21:11]), .s_axi_awlen(d1_awlen[15:8]),
        .s_axi_awsize(d1_awsize[5:3]), .s_axi_awburst(d1_awburst[3:2]), .s_axi_awvalid(d1_awvalid[1]), .s_axi_awready(d1_awready[1]),
        .s_axi_wdata(d1_wdata[127:64]), .s_axi_wstrb(d1_wstrb[15:8]), .s_axi_wlast(d1_wlast[1]), .s_axi_wvalid(d1_wvalid[1]), .s_axi_wready(d1_wready[1]),
        .s_axi_bid(d1_bid[15:8]), .s_axi_bresp(d1_bresp[3:2]), .s_axi_bvalid(d1_bvalid[1]), .s_axi_bready(d1_bready[1]),
        .s_axi_arid(d1_arid[15:8]), .s_axi_araddr(d1_araddr[21:11]), .s_axi_arlen(d1_arlen[15:8]),
        .s_axi_arsize(d1_arsize[5:3]), .s_axi_arburst(d1_arburst[3:2]), .s_axi_arvalid(d1_arvalid[1]), .s_axi_arready(d1_arready[1]),
        .s_axi_rid(d1_rid[15:8]), .s_axi_rdata(d1_rdata[127:64]), .s_axi_rresp(d1_rresp[3:2]), .s_axi_rlast(d1_rlast[1]), .s_axi_rvalid(d1_rvalid[1]), .s_axi_rready(d1_rready[1]),
        .aw_count(d1_aw_cnt1), .last_awaddr(d1_last_aw1), .stale_read_seen(d1_stale1)
    );

    // =========================================================================
    // Scoreboards & Monitors (sampled cleanly on posedge m_clk)
    // =========================================================================
    localparam MAX_PKTS = 64;
    localparam MAX_PKT_BYTES = 256;

    reg [7:0] exp0_data [0:MAX_PKTS-1][0:MAX_PKT_BYTES-1];
    integer   exp0_len  [0:MAX_PKTS-1];
    reg [2:0] exp0_id   [0:MAX_PKTS-1];
    reg [2:0] exp0_dest [0:MAX_PKTS-1];
    reg [1:0] exp0_user [0:MAX_PKTS-1];
    integer   exp0_wr = 0, exp0_rd = 0;

    reg [7:0] cur0_buf [0:MAX_PKT_BYTES-1];
    integer   cur0_len = 0;
    reg       mon0_en  = 1'b0;

    always @(posedge m_clk) begin
        if (!d0_rst && mon0_en && d0_m_tvalid && d0_m_tready) begin : rx0_blk
            integer k;
            for (k = 0; k < 4; k = k + 1) begin
                if (d0_m_tkeep[k]) begin
                    cur0_buf[cur0_len] = d0_m_tdata[k*8 +: 8];
                    cur0_len = cur0_len + 1;
                end
            end
            if (d0_m_tlast) begin
                if (exp0_rd >= exp0_wr) begin
                    $display("FAIL: DUT0 unexpected extra/leaked frame on m_axis (len=%0d)", cur0_len);
                    $finish(1);
                end
                if (cur0_len != exp0_len[exp0_rd]) begin
                    $display("FAIL: DUT0 pkt %0d len=%0d expected=%0d", exp0_rd, cur0_len, exp0_len[exp0_rd]);
                    $finish(1);
                end
                if (d0_m_tid !== exp0_id[exp0_rd] || d0_m_tdest !== exp0_dest[exp0_rd] || d0_m_tuser !== exp0_user[exp0_rd]) begin
                    $display("FAIL: DUT0 pkt %0d meta id=%h/%h dest=%h/%h user=%h/%h",
                             exp0_rd, d0_m_tid, exp0_id[exp0_rd], d0_m_tdest, exp0_dest[exp0_rd], d0_m_tuser, exp0_user[exp0_rd]);
                    $finish(1);
                end
                for (k = 0; k < cur0_len; k = k + 1) begin
                    if (cur0_buf[k] !== exp0_data[exp0_rd][k]) begin
                        $display("FAIL: DUT0 pkt %0d byte[%0d]=%02x expected=%02x", exp0_rd, k, cur0_buf[k], exp0_data[exp0_rd][k]);
                        $finish(1);
                    end
                end
                cur0_len = 0;
                exp0_rd  = exp0_rd + 1;
            end
        end
    end

    reg [7:0] exp1_data [0:MAX_PKTS-1][0:MAX_PKT_BYTES-1];
    integer   exp1_len  [0:MAX_PKTS-1];
    reg [2:0] exp1_id   [0:MAX_PKTS-1];
    reg [2:0] exp1_dest [0:MAX_PKTS-1];
    reg [1:0] exp1_user [0:MAX_PKTS-1];
    integer   exp1_wr = 0, exp1_rd = 0;

    reg [7:0] cur1_buf [0:MAX_PKT_BYTES-1];
    integer   cur1_len = 0;
    reg       mon1_en  = 1'b0;

    always @(posedge m_clk) begin
        if (!d1_rst && mon1_en && d1_m_tvalid && d1_m_tready) begin : rx1_blk
            integer k;
            for (k = 0; k < 8; k = k + 1) begin
                if (d1_m_tkeep[k]) begin
                    cur1_buf[cur1_len] = d1_m_tdata[k*8 +: 8];
                    cur1_len = cur1_len + 1;
                end
            end
            if (d1_m_tlast) begin
                if (exp1_rd >= exp1_wr) begin
                    $display("FAIL: DUT1 unexpected extra frame on m_axis");
                    $finish(1);
                end
                if (cur1_len != exp1_len[exp1_rd]) begin
                    $display("FAIL: DUT1 pkt %0d len=%0d expected=%0d", exp1_rd, cur1_len, exp1_len[exp1_rd]);
                    $finish(1);
                end
                if (d1_m_tid !== exp1_id[exp1_rd] || d1_m_tdest !== exp1_dest[exp1_rd] || d1_m_tuser !== exp1_user[exp1_rd]) begin
                    $display("FAIL: DUT1 pkt %0d meta mismatch", exp1_rd);
                    $finish(1);
                end
                for (k = 0; k < cur1_len; k = k + 1) begin
                    if (cur1_buf[k] !== exp1_data[exp1_rd][k]) begin
                        $display("FAIL: DUT1 pkt %0d byte[%0d]=%02x expected=%02x", exp1_rd, k, cur1_buf[k], exp1_data[exp1_rd][k]);
                        $finish(1);
                    end
                end
                cur1_len = 0;
                exp1_rd  = exp1_rd + 1;
            end
        end
    end

    // Parity error guard
    always @(negedge c_clk) begin
        if (!d0_rst && mon0_en && d0_sts_perr) begin
            $display("FAIL: DUT0 asserted sts_hdr_parity_err at t=%0t", $time);
            $finish(1);
        end
        if (!d1_rst && mon1_en && d1_sts_perr) begin
            $display("FAIL: DUT1 asserted sts_hdr_parity_err at t=%0t", $time);
            $finish(1);
        end
    end

    // Helper tasks
    reg s0_hs = 1'b0;
    reg s1_hs = 1'b0;
    always @(posedge s_clk) begin
        s0_hs <= !d0_rst && d0_s_tvalid && d0_s_tready;
        s1_hs <= !d1_rst && d1_s_tvalid && d1_s_tready;
    end

    reg [31:0] prng;
    function [31:0] next_rng(input [31:0] cur);
        begin
            next_rng = {cur[30:0], cur[31] ^ cur[21] ^ cur[1] ^ cur[0]};
        end
    endfunction

    task send_dut0_pkt(
        input integer plen,
        input [2:0]   pid,
        input [2:0]   pdest,
        input [1:0]   puser,
        input         record_sb
    );
        integer pos, lane;
        reg [31:0] wdata;
        reg [3:0]  wkeep;
        reg [7:0]  bval;
        begin
            if (record_sb) begin
                exp0_len[exp0_wr]  = plen;
                exp0_id[exp0_wr]   = pid;
                exp0_dest[exp0_wr] = pdest;
                exp0_user[exp0_wr] = puser;
            end
            pos = 0;
            @(negedge s_clk);
            while (pos < plen) begin
                wdata = 32'd0;
                wkeep = 4'd0;
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    if (pos + lane < plen) begin
                        prng = next_rng(prng);
                        bval = prng[7:0] ^ (pos + lane + 8'h35);
                        wdata[lane*8 +: 8] = bval;
                        wkeep[lane] = 1'b1;
                        if (record_sb)
                            exp0_data[exp0_wr][pos + lane] = bval;
                    end
                end
                d0_s_tdata  = wdata;
                d0_s_tkeep  = wkeep;
                d0_s_tlast  = ((pos + 4) >= plen);
                d0_s_tid    = pid;
                d0_s_tdest  = pdest;
                d0_s_tuser  = puser;
                d0_s_tvalid = 1'b1;
                @(negedge s_clk);
                while (!s0_hs) @(negedge s_clk);
                pos = pos + 4;
            end
            d0_s_tvalid = 1'b0;
            d0_s_tlast  = 1'b0;
            if (record_sb)
                exp0_wr = exp0_wr + 1;
        end
    endtask

    task send_dut1_pkt(
        input integer plen,
        input [2:0]   pid,
        input [2:0]   pdest,
        input [1:0]   puser
    );
        integer pos, lane;
        reg [63:0] wdata;
        reg [7:0]  wkeep;
        reg [7:0]  bval;
        begin
            exp1_len[exp1_wr]  = plen;
            exp1_id[exp1_wr]   = pid;
            exp1_dest[exp1_wr] = pdest;
            exp1_user[exp1_wr] = puser;
            pos = 0;
            @(negedge s_clk);
            while (pos < plen) begin
                wdata = 64'd0;
                wkeep = 8'd0;
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if (pos + lane < plen) begin
                        prng = next_rng(prng);
                        bval = prng[15:8] ^ (pos + lane + 8'h5A);
                        wdata[lane*8 +: 8] = bval;
                        wkeep[lane] = 1'b1;
                        exp1_data[exp1_wr][pos + lane] = bval;
                    end
                end
                d1_s_tdata  = wdata;
                d1_s_tkeep  = wkeep;
                d1_s_tlast  = ((pos + 8) >= plen);
                d1_s_tid    = pid;
                d1_s_tdest  = pdest;
                d1_s_tuser  = puser;
                d1_s_tvalid = 1'b1;
                @(negedge s_clk);
                while (!s1_hs) @(negedge s_clk);
                pos = pos + 8;
            end
            d1_s_tvalid = 1'b0;
            d1_s_tlast  = 1'b0;
            exp1_wr = exp1_wr + 1;
        end
    endtask

    integer wc, pkt_i, flen;
    integer pre_flush_aw_cnt;
    reg     saw_occ_nonzero;
    reg     saw_reset_high;

    initial begin
        prng = (SEED == 0) ? 32'h1357_9BDF : (SEED ^ 32'hA5A5_5A5A);

        // =====================================================================
        // Reset & Post-Reset Cleanliness Check
        // =====================================================================
        d0_rst = 1'b1;
        d1_rst = 1'b1;
        repeat (10) @(negedge a_clk);
        if (^{d0_sts_occ, d0_sts_empty, d0_sts_full, d0_sts_reset, d0_sts_active, d0_sts_perr} === 1'bx) begin
            $display("FAIL: DUT0 X/Z on status during reset");
            $finish(1);
        end
        if (d0_sts_occ !== 13'd0 || d0_sts_reset !== 1'b1 || d0_sts_active !== 1'b0) begin
            $display("FAIL: DUT0 bad reset status occ=%0d rst=%b act=%b", d0_sts_occ, d0_sts_reset, d0_sts_active);
            $finish(1);
        end

        @(negedge c_clk);
        d0_rst = 1'b0;
        d1_rst = 1'b0;
        d0_cfg_enable = 1'b1;

        // Probe BVALID=1 while BREADY=0 right after reset before any burst starts
        d0_probe_bvalid_when_unready = 1'b1;
        wc = 0;
        while ((!d0_sts_active || d0_s_rst_out || d0_m_rst_out) && wc < 120) begin
            @(negedge c_clk);
            wc = wc + 1;
        end
        repeat (6) @(negedge a_clk);
        d0_probe_bvalid_when_unready = 1'b0;

        if (!d0_sts_active || d0_sts_reset) begin
            $display("FAIL: DUT0 failed to exit reset and become active");
            $finish(1);
        end
        if (^{d0_sts_occ, d0_sts_empty} === 1'bx || d0_sts_occ !== 13'd0 || d0_sts_empty !== 1'b1) begin
            $display("FAIL: DUT0 status corrupted after unready BVALID probe: empty=%b occ=%h", d0_sts_empty, d0_sts_occ);
            $finish(1);
        end

        // =====================================================================
        // Test 1A: Write-Commit Ordering & Fast B-Responses (lengths 1..97B)
        // =====================================================================
        mon0_en     = 1'b1;
        d0_m_tready = 1'b1;
        d0_b_mode   = 2'd0;
        send_dut0_pkt(1,  8'h11, 8'hA1, 4'h1, 1'b1);
        send_dut0_pkt(7,  8'h12, 8'hA2, 4'h2, 1'b1);
        send_dut0_pkt(8,  8'h13, 8'hA3, 4'h3, 1'b1);
        send_dut0_pkt(9,  8'h14, 8'hA4, 4'h4, 1'b1);
        send_dut0_pkt(15, 8'h15, 8'hA5, 4'h5, 1'b1);
        send_dut0_pkt(33, 8'h16, 8'hA6, 4'h6, 1'b1);
        send_dut0_pkt(64, 8'h17, 8'hA7, 4'h7, 1'b1);
        send_dut0_pkt(97, 8'h18, 8'hA8, 4'h8, 1'b1);

        wc = 0;
        while (exp0_rd < exp0_wr && wc < 4000) begin
            @(negedge c_clk);
            wc = wc + 1;
        end
        if (exp0_rd != exp0_wr || d0_stale_rd) begin
            $display("FAIL: Test 1A incomplete (rx=%0d/%0d stale_rd=%b)", exp0_rd, exp0_wr, d0_stale_rd);
            $finish(1);
        end

        // =====================================================================
        // Test 1B: >32 Outstanding Write Bursts Under High B-Channel Latency
        // (16 x 80B frames = >40 AXI bursts of 4 beats = >1280B buffered!)
        // =====================================================================
        d0_b_mode   = 2'd1; // holds BVALID until >=35 bursts queued (or idle timeout if backpressured)
        d0_m_tready = 1'b0; // hold egress briefly so occupancy builds up
        saw_occ_nonzero = 1'b0;
        for (pkt_i = 0; pkt_i < 16; pkt_i = pkt_i + 1) begin
            send_dut0_pkt(72 + (pkt_i % 13), 8'h40 + pkt_i[7:0], 8'h80 + pkt_i[7:0], pkt_i[3:0], 1'b1);
            if (d0_sts_occ > 13'd0)
                saw_occ_nonzero = 1'b1;
        end
        repeat (20) @(negedge c_clk);
        if (d0_sts_occ > 13'd0)
            saw_occ_nonzero = 1'b1;
        if (!saw_occ_nonzero) begin
            $display("FAIL: Test 1B sts_fifo_occupancy never reflected buffered data");
            $finish(1);
        end

        d0_m_tready = 1'b1;
        wc = 0;
        while (exp0_rd < exp0_wr && wc < 8000) begin
            @(negedge c_clk);
            wc = wc + 1;
        end
        if (exp0_rd != exp0_wr || d0_stale_rd) begin
            $display("FAIL: Test 1B >32 burst stress failed (rx=%0d/%0d stale_rd=%b)", exp0_rd, exp0_wr, d0_stale_rd);
            $finish(1);
        end
        d0_b_mode = 2'd0;

        // Wait for full drain
        wc = 0;
        while ((!d0_sts_empty || d0_sts_occ != 13'd0) && wc < 300) begin
            @(negedge c_clk);
            wc = wc + 1;
        end
        if (!d0_sts_empty || d0_sts_occ != 13'd0) begin
            $display("FAIL: Test 1B did not return to empty=1 occ=0 (empty=%b occ=%0d)", d0_sts_empty, d0_sts_occ);
            $finish(1);
        end

        // =====================================================================
        // Test 2: End-to-End sts_fifo_empty Across Every Pipeline Stage
        // =====================================================================
        // 2a: Stalled first inside ingress encoder (mid-frame beat buffered in seg_mem),
        //     then inside channel write_fifo before AXI write burst
        d0_stall_aw_w = 1'b1;
        d0_m_tready   = 1'b0;
        exp0_len[exp0_wr]  = 8;
        exp0_id[exp0_wr]   = 3'd3;
        exp0_dest[exp0_wr] = 3'd5;
        exp0_user[exp0_wr] = 2'd1;
        exp0_data[exp0_wr][0] = 8'hA1; exp0_data[exp0_wr][1] = 8'hB2;
        exp0_data[exp0_wr][2] = 8'hC3; exp0_data[exp0_wr][3] = 8'hD4;
        exp0_data[exp0_wr][4] = 8'hE5; exp0_data[exp0_wr][5] = 8'hF6;
        exp0_data[exp0_wr][6] = 8'h17; exp0_data[exp0_wr][7] = 8'h28;
        @(negedge s_clk);
        d0_s_tdata  = 32'hD4C3_B2A1;
        d0_s_tkeep  = 4'hF;
        d0_s_tlast  = 1'b0;
        d0_s_tid    = 3'd3;
        d0_s_tdest  = 3'd5;
        d0_s_tuser  = 2'd1;
        d0_s_tvalid = 1'b1;
        @(negedge s_clk);
        while (!s0_hs) @(negedge s_clk);
        d0_s_tvalid = 1'b0;

        repeat (16) @(negedge c_clk);
        if (d0_sts_empty !== 1'b0) begin
            $display("FAIL: Test 2a-enc sts_fifo_empty=1 while beat buffered in ingress encoder");
            $finish(1);
        end

        @(negedge s_clk);
        d0_s_tdata  = 32'h2817_F6E5;
        d0_s_tkeep  = 4'hF;
        d0_s_tlast  = 1'b1;
        d0_s_tvalid = 1'b1;
        @(negedge s_clk);
        while (!s0_hs) @(negedge s_clk);
        d0_s_tvalid = 1'b0;
        d0_s_tlast  = 1'b0;
        exp0_wr = exp0_wr + 1;

        repeat (16) @(negedge c_clk);
        if (d0_sts_empty !== 1'b0) begin
            $display("FAIL: Test 2a sts_fifo_empty=1 while packet buffered in ingress/write_fifo");
            $finish(1);
        end

        // 2b: Allow AW+W, hold BVALID=0 (uncommitted AXI write burst)
        d0_b_mode     = 2'd2; // hold BVALID=0
        d0_stall_aw_w = 1'b0;
        wc = 0;
        while (d0_aw_count == 0 && wc < 800) begin
            @(negedge c_clk);
            wc = wc + 1;
        end
        repeat (20) @(negedge a_clk);
        if (d0_sts_empty !== 1'b0) begin
            $display("FAIL: Test 2b sts_fifo_empty=1 while AXI write burst uncommitted");
            $finish(1);
        end

        // 2c: Release BVALID, let DRAM read drain completely into decoder while m_axis_tready=0
        d0_b_mode = 2'd0;
        wc = 0;
        while (!d0_m_tvalid && wc < 1500) begin
            @(negedge c_clk);
            wc = wc + 1;
        end
        if (!d0_m_tvalid) begin
            $display("FAIL: Test 2c timeout waiting for decoder m_axis_tvalid");
            $finish(1);
        end
        // Let ring pointers settle completely while frame sits stalled in decoder
        repeat (35) @(negedge c_clk);
        if (d0_sts_empty !== 1'b0) begin
            $display("FAIL: Test 2c sts_fifo_empty=1 while frame still stalled in egress decoder");
            $finish(1);
        end

        // 2d: Drain m_axis and verify sts_fifo_empty asserts 1
        d0_m_tready = 1'b1;
        wc = 0;
        while (exp0_rd < exp0_wr && wc < 300) begin
            @(negedge c_clk);
            wc = wc + 1;
        end
        wc = 0;
        while (!d0_sts_empty && wc < 200) begin
            @(negedge c_clk);
            wc = wc + 1;
        end
        if (!d0_sts_empty || d0_sts_occ != 13'd0) begin
            $display("FAIL: Test 2d sts_fifo_empty failed to assert after full drain");
            $finish(1);
        end

        // =====================================================================
        // Test 3: Single-Cycle cfg_reset Pulse Across Async Clocks + Ring Reconfig
        // (c_clk=6ns pulse vs a_clk=14ns, while bursts are in flight!)
        // =====================================================================
        mon0_en     = 1'b0; // pre-flush packets intentionally discarded
        d0_m_tready = 1'b0;
        d0_rd_lat   = 4'd6;
        // Inject 4 frames into ring 0x000..0x7FF while m_axis_tready=0
        send_dut0_pkt(60, 8'hE1, 8'hF1, 4'hE, 1'b0);
        send_dut0_pkt(60, 8'hE2, 8'hF2, 4'hE, 1'b0);
        send_dut0_pkt(60, 8'hE3, 8'hF3, 4'hE, 1'b0);
        repeat (15) @(negedge a_clk);

        // Reconfigure base address and test 1-c_clk-cycle cfg_reset pulses across all 3 c_clk/a_clk beat phases
        begin : cfg_rst_phase_sweep
            integer ph;
            for (ph = 0; ph < 3; ph = ph + 1) begin
                repeat (ph + 1) @(posedge a_clk);
                @(negedge c_clk);
                d0_cfg_base  = 12'h800;
                d0_cfg_mask  = 12'h7ff;
                d0_cfg_reset = 1'b1; // 1 c_clk cycle (6ns) while cfg_enable stays 1'b1!
                @(negedge c_clk);
                d0_cfg_reset = 1'b0;

                saw_reset_high = 1'b0;
                wc = 0;
                while (wc < 120) begin
                    if (d0_sts_reset)
                        saw_reset_high = 1'b1;
                    @(negedge c_clk);
                    wc = wc + 1;
                    if (saw_reset_high && !d0_sts_reset && d0_sts_active && !d0_s_rst_out && !d0_m_rst_out)
                        wc = 500;
                end
                if (!saw_reset_high || d0_sts_reset || !d0_sts_active) begin
                    $display("FAIL: Test 3 1-cycle cfg_reset handshake failed on phase %0d (saw_rst=%b sts_rst=%b act=%b)",
                             ph, saw_reset_high, d0_sts_reset, d0_sts_active);
                    $finish(1);
                end
            end
        end

        // Enable scoreboard & m_axis_tready: verify ZERO pre-flush fragments leak!
        cur0_len     = 0;
        d0_rd_lat    = 4'd1;
        mon0_en      = 1'b1;
        d0_m_tready  = 1'b1;
        repeat (30) @(negedge m_clk);

        pre_flush_aw_cnt = d0_aw_count;
        send_dut0_pkt(25, 8'h71, 8'hC1, 4'h3, 1'b1);
        send_dut0_pkt(48, 8'h72, 8'hC2, 4'h4, 1'b1);
        send_dut0_pkt(85, 8'h73, 8'hC3, 4'h5, 1'b1);

        wc = 0;
        while (exp0_rd < exp0_wr && wc < 3000) begin
            @(negedge c_clk);
            wc = wc + 1;
        end
        if (exp0_rd != exp0_wr || d0_aw_count <= pre_flush_aw_cnt) begin
            $display("FAIL: Test 3 post-flush frames failed (rx=%0d/%0d)", exp0_rd, exp0_wr);
            $finish(1);
        end
        if (d0_last_awaddr < 12'h800) begin
            $display("FAIL: Test 3 updated cfg_fifo_base_addr not latched (last_awaddr=%03x < 0x800)", d0_last_awaddr);
            $finish(1);
        end

        // =====================================================================
        // Test 4: DUT1 2-Channel (AXI_CH=2, CH_SEG_CNT=2, WRITE_FIFO_DEPTH=16)
        // Sustained AXI Backpressure & Variable-Length Frame Stress
        // =====================================================================
        @(negedge c_clk);
        d1_cfg_enable = 1'b1;
        wc = 0;
        while ((d1_sts_active !== 2'b11 || d1_s_rst_out || d1_m_rst_out) && wc < 150) begin
            @(negedge c_clk);
            wc = wc + 1;
        end
        if (d1_sts_active !== 2'b11) begin
            $display("FAIL: DUT1 failed to activate both channels");
            $finish(1);
        end

        mon1_en     = 1'b1;
        d1_m_tready = 1'b1;
        fork
            begin
                for (pkt_i = 0; pkt_i < 24; pkt_i = pkt_i + 1) begin
                    prng = next_rng(prng);
                    flen = 1 + (prng[7:0] % 140);
                    send_dut1_pkt(flen, 8'hA0 + pkt_i[7:0], 8'h50 + pkt_i[7:0], pkt_i[3:0]);
                end
            end
            begin
                // Periodically stall AXI AW/W on both channels for 25 a_clk cycles
                // to exercise WRITE_FIFO_DEPTH=16 segment watermark flow control!
                repeat (8) begin
                    d1_stall_axi = 1'b1;
                    repeat (22) @(negedge a_clk);
                    d1_stall_axi = 1'b0;
                    repeat (14) @(negedge a_clk);
                end
                d1_stall_axi = 1'b0;
            end
        join

        wc = 0;
        while (exp1_rd < exp1_wr && wc < 8000) begin
            @(negedge c_clk);
            wc = wc + 1;
        end
        if (exp1_rd != exp1_wr || d1_stale0 || d1_stale1) begin
            $display("FAIL: Test 4 2-channel stress failed (rx=%0d/%0d stale=%b/%b)",
                     exp1_rd, exp1_wr, d1_stale0, d1_stale1);
            $finish(1);
        end

        wc = 0;
        while (d1_sts_empty !== 2'b11 && wc < 300) begin
            @(negedge c_clk);
            wc = wc + 1;
        end
        if (d1_sts_empty !== 2'b11) begin
            $display("FAIL: Test 4 DUT1 sts_fifo_empty=%b after full drain", d1_sts_empty);
            $finish(1);
        end

        $display("PASS seed=%0d", SEED);
        $finish(0);
    end
endmodule
