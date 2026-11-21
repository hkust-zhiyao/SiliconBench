`timescale 1ns / 1ps

// Clocked AXI4 Slave Memory Responder + Burst Protocol Monitor
module axi_mem_slave #(
    parameter ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 128,
    parameter STRB_WIDTH = DATA_WIDTH / 8,
    parameter ID_WIDTH   = 6,
    parameter AWUSER_W   = 4,
    parameter WUSER_W    = 4,
    parameter BUSER_W    = 4,
    parameter ARUSER_W   = 4,
    parameter RUSER_W    = 4,
    parameter MEM_BYTES  = 16384
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire [31:0]           stall_seed,

    input  wire [ID_WIDTH-1:0]   awid,
    input  wire [ADDR_WIDTH-1:0] awaddr,
    input  wire [7:0]            awlen,
    input  wire [2:0]            awsize,
    input  wire [1:0]            awburst,
    input  wire                  awlock,
    input  wire [3:0]            awcache,
    input  wire [2:0]            awprot,
    input  wire [3:0]            awqos,
    input  wire [3:0]            awregion,
    input  wire [AWUSER_W-1:0]   awuser,
    input  wire                  awvalid,
    output reg                   awready,

    input  wire [DATA_WIDTH-1:0] wdata,
    input  wire [STRB_WIDTH-1:0] wstrb,
    input  wire                  wlast,
    input  wire [WUSER_W-1:0]    wuser,
    input  wire                  wvalid,
    output reg                   wready,

    output reg  [ID_WIDTH-1:0]   bid,
    output reg  [1:0]            bresp,
    output reg  [BUSER_W-1:0]    buser,
    output reg                   bvalid,
    input  wire                  bready,

    input  wire [ID_WIDTH-1:0]   arid,
    input  wire [ADDR_WIDTH-1:0] araddr,
    input  wire [7:0]            arlen,
    input  wire [2:0]            arsize,
    input  wire [1:0]            arburst,
    input  wire                  arlock,
    input  wire [3:0]            arcache,
    input  wire [2:0]            arprot,
    input  wire [3:0]            arqos,
    input  wire [3:0]            arregion,
    input  wire [ARUSER_W-1:0]   aruser,
    input  wire                  arvalid,
    output reg                   arready,

    output reg  [ID_WIDTH-1:0]   rid,
    output reg  [DATA_WIDTH-1:0] rdata,
    output reg  [1:0]            rresp,
    output reg                   rlast,
    output reg  [RUSER_W-1:0]    ruser,
    output reg                   rvalid,
    input  wire                  rready,

    output integer               err_cnt,
    output integer               aw_cmd_cnt,
    output integer               ar_cmd_cnt,
    output reg  [ADDR_WIDTH-1:0] last_awaddr,
    output reg  [7:0]            last_awlen,
    output reg  [2:0]            last_awsize,
    output reg  [1:0]            last_awburst,
    output reg  [ID_WIDTH-1:0]   last_awid,
    output reg  [AWUSER_W-1:0]   last_awuser,
    output reg  [WUSER_W-1:0]    last_wuser,
    output reg  [ADDR_WIDTH-1:0] last_araddr,
    output reg  [7:0]            last_arlen,
    output reg  [2:0]            last_arsize,
    output reg  [1:0]            last_arburst,
    output reg  [ID_WIDTH-1:0]   last_arid,
    output reg  [ARUSER_W-1:0]   last_aruser
);
    reg [7:0] mem [0:MEM_BYTES-1];
    localparam integer BUS_LSB = $clog2(STRB_WIDTH);

    function [ADDR_WIDTH-1:0] wrap_mask_fn;
        input [2:0] sz;
        input [7:0] len;
        reg [ADDR_WIDTH-1:0] bstep;
        begin
            bstep = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << sz);
            case (len)
                8'd1:    wrap_mask_fn = (bstep << 1) - 1'b1;
                8'd3:    wrap_mask_fn = (bstep << 2) - 1'b1;
                8'd7:    wrap_mask_fn = (bstep << 3) - 1'b1;
                default: wrap_mask_fn = (bstep << 4) - 1'b1;
            endcase
        end
    endfunction

    function [ADDR_WIDTH-1:0] next_addr_fn;
        input [ADDR_WIDTH-1:0] cur;
        input [ADDR_WIDTH-1:0] orig;
        input [2:0] sz;
        input [1:0] btype;
        input [7:0] len;
        reg [ADDR_WIDTH-1:0] bstep, amask, wm, inc_a;
        begin
            bstep = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << sz);
            amask = ~(bstep - 1'b1);
            wm    = wrap_mask_fn(sz, len);
            inc_a = (cur + bstep) & amask;
            case (btype)
                2'b00:   next_addr_fn = orig;
                2'b10:   next_addr_fn = (cur & ~wm) | (inc_a & wm);
                default: next_addr_fn = inc_a;
            endcase
        end
    endfunction

    // Programmable error windows:
    // 0x3800..0x380F -> SLVERR (2'b10), user=0xA
    // 0x3810..0x381F -> DECERR (2'b11), user=0xD
    // 0x3820..0x382F -> EXOKAY (2'b01), user=0x5
    function [1:0] addr_resp_fn;
        input [ADDR_WIDTH-1:0] a;
        begin
            if ((a & 16'hFFF0) == 16'h3800)      addr_resp_fn = 2'b10;
            else if ((a & 16'hFFF0) == 16'h3810) addr_resp_fn = 2'b11;
            else if ((a & 16'hFFF0) == 16'h3820) addr_resp_fn = 2'b01;
            else                                 addr_resp_fn = 2'b00;
        end
    endfunction

    function [7:0] addr_user_fn;
        input [ADDR_WIDTH-1:0] a;
        begin
            if ((a & 16'hFFF0) == 16'h3800)      addr_user_fn = 8'h12;
            else if ((a & 16'hFFF0) == 16'h3810) addr_user_fn = 8'h1D;
            else if ((a & 16'hFFF0) == 16'h3820) addr_user_fn = 8'h09;
            else                                 addr_user_fn = 8'h03;
        end
    endfunction

    reg [31:0] lfsr;
    reg        wr_active;
    reg [ID_WIDTH-1:0]   wr_id;
    reg [ADDR_WIDTH-1:0] wr_addr, wr_orig;
    reg [7:0]            wr_rem, wr_orig_len;
    reg [2:0]            wr_size;
    reg [1:0]            wr_burst;
    reg [1:0]            wr_max_resp;
    reg [BUSER_W-1:0]    wr_buser;

    reg        rd_active;
    reg [ID_WIDTH-1:0]   rd_id;
    reg [ADDR_WIDTH-1:0] rd_addr, rd_orig;
    reg [7:0]            rd_rem, rd_orig_len;
    reg [2:0]            rd_size;
    reg [1:0]            rd_burst;

    // AXI4 stability tracking
    reg                  prev_aw_stall, prev_w_stall, prev_ar_stall;
    reg [ADDR_WIDTH-1:0] hold_awaddr, hold_araddr;
    reg [7:0]            hold_awlen, hold_arlen;
    reg [DATA_WIDTH-1:0] hold_wdata;
    reg [STRB_WIDTH-1:0] hold_wstrb;
    reg                  hold_wlast;

    integer b;
    reg [ADDR_WIDTH-1:0] base_aligned;
    reg [1:0] beat_r;
    reg [7:0] beat_u;
    reg [DATA_WIDTH-1:0] rd_word;

    initial begin
        for (b = 0; b < MEM_BYTES; b = b + 1) mem[b] = 8'h00;
        err_cnt = 0;
        aw_cmd_cnt = 0;
        ar_cmd_cnt = 0;
    end

    always @(posedge clk) begin
        if (rst) begin
            lfsr <= stall_seed ^ 32'hA5A5_5A5A;
            awready <= 1'b0;
            wready  <= 1'b0;
            bvalid  <= 1'b0;
            bid     <= {ID_WIDTH{1'b0}};
            bresp   <= 2'd0;
            buser   <= {BUSER_W{1'b0}};
            arready <= 1'b0;
            rvalid  <= 1'b0;
            rid     <= {ID_WIDTH{1'b0}};
            rdata   <= {DATA_WIDTH{1'b0}};
            rresp   <= 2'd0;
            rlast   <= 1'b0;
            ruser   <= {RUSER_W{1'b0}};
            wr_active <= 1'b0;
            rd_active <= 1'b0;
            prev_aw_stall <= 1'b0;
            prev_w_stall  <= 1'b0;
            prev_ar_stall <= 1'b0;
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

            // AXI4 channel stability assertions
            if (prev_aw_stall && (!awvalid || awaddr !== hold_awaddr || awlen !== hold_awlen)) begin
                $display("FAIL: m_axi_aw stability violation!");
                err_cnt <= err_cnt + 1;
            end
            if (prev_w_stall && (!wvalid || wdata !== hold_wdata || wstrb !== hold_wstrb || wlast !== hold_wlast)) begin
                $display("FAIL: m_axi_w stability violation!");
                err_cnt <= err_cnt + 1;
            end
            if (prev_ar_stall && (!arvalid || araddr !== hold_araddr || arlen !== hold_arlen)) begin
                $display("FAIL: m_axi_ar stability violation!");
                err_cnt <= err_cnt + 1;
            end
            prev_aw_stall <= awvalid && !awready;
            hold_awaddr   <= awaddr;
            hold_awlen    <= awlen;
            prev_w_stall  <= wvalid && !wready;
            hold_wdata    <= wdata;
            hold_wstrb    <= wstrb;
            hold_wlast    <= wlast;
            prev_ar_stall <= arvalid && !arready;
            hold_araddr   <= araddr;
            hold_arlen    <= arlen;

            // Write channel FSM
            if (bvalid && bready) bvalid <= 1'b0;

            awready <= !wr_active && !bvalid && lfsr[0];
            wready  <= wr_active && lfsr[1];

            if (awvalid && awready) begin
                awready      <= 1'b0;
                wr_active    <= 1'b1;
                wr_id        <= awid;
                wr_addr      <= awaddr;
                wr_orig      <= awaddr;
                wr_rem       <= awlen;
                wr_orig_len  <= awlen;
                wr_size      <= awsize;
                wr_burst     <= awburst;
                wr_max_resp  <= addr_resp_fn(awaddr);
                beat_u        = addr_user_fn(awaddr);
                wr_buser     <= beat_u[BUSER_W-1:0];
                aw_cmd_cnt   <= aw_cmd_cnt + 1;
                last_awaddr  <= awaddr;
                last_awlen   <= awlen;
                last_awsize  <= awsize;
                last_awburst <= awburst;
                last_awid    <= awid;
                last_awuser  <= awuser;
                if ((1 << awsize) > STRB_WIDTH) begin
                    $display("FAIL: m_axi_awsize=%0d exceeds M_STRB_WIDTH=%0d", awsize, STRB_WIDTH);
                    err_cnt <= err_cnt + 1;
                end
            end

            if (wr_active && wvalid && wready) begin
                base_aligned = (wr_addr >> BUS_LSB) << BUS_LSB;
                for (b = 0; b < STRB_WIDTH; b = b + 1) begin
                    if (wstrb[b] && (base_aligned + b < MEM_BYTES)) begin
                        mem[base_aligned + b] <= wdata[b*8 +: 8];
                    end
                end
                last_wuser <= wuser;
                beat_r = addr_resp_fn(wr_addr);
                beat_u = addr_user_fn(wr_addr);
                if (beat_r > wr_max_resp) begin
                    wr_max_resp <= beat_r;
                    wr_buser    <= beat_u[BUSER_W-1:0];
                end
                if (wr_rem == 8'd0) begin
                    if (!wlast) begin
                        $display("FAIL: missing m_axi_wlast on final beat! awaddr=0x%0h awlen=%0d", wr_orig, wr_orig_len);
                        err_cnt <= err_cnt + 1;
                    end
                    wr_active <= 1'b0;
                    wready    <= 1'b0;
                    bvalid    <= 1'b1;
                    bid       <= wr_id;
                    bresp     <= (beat_r > wr_max_resp) ? beat_r : wr_max_resp;
                    buser     <= (beat_r > wr_max_resp) ? beat_u[BUSER_W-1:0] : wr_buser;
                end else begin
                    if (wlast) begin
                        $display("FAIL: premature m_axi_wlast with %0d beats remaining! awaddr=0x%0h awlen=%0d", wr_rem, wr_orig, wr_orig_len);
                        err_cnt <= err_cnt + 1;
                    end
                    wr_rem  <= wr_rem - 8'd1;
                    wr_addr <= next_addr_fn(wr_addr, wr_orig, wr_size, wr_burst, wr_orig_len);
                end
            end

            // Read channel FSM
            if (rvalid && rready) rvalid <= 1'b0;

            arready <= !rd_active && !rvalid && lfsr[2];

            if (arvalid && arready) begin
                arready      <= 1'b0;
                rd_active    <= 1'b1;
                rd_id        <= arid;
                rd_addr      <= araddr;
                rd_orig      <= araddr;
                rd_rem       <= arlen;
                rd_orig_len  <= arlen;
                rd_size      <= arsize;
                rd_burst     <= arburst;
                ar_cmd_cnt   <= ar_cmd_cnt + 1;
                last_araddr  <= araddr;
                last_arlen   <= arlen;
                last_arsize  <= arsize;
                last_arburst <= arburst;
                last_arid    <= arid;
                last_aruser  <= aruser;
                if ((1 << arsize) > STRB_WIDTH) begin
                    $display("FAIL: m_axi_arsize=%0d exceeds M_STRB_WIDTH=%0d", arsize, STRB_WIDTH);
                    err_cnt <= err_cnt + 1;
                end
            end

            if (rd_active && (!rvalid || rready) && lfsr[3]) begin
                base_aligned = (rd_addr >> BUS_LSB) << BUS_LSB;
                rd_word = {DATA_WIDTH{1'b0}};
                for (b = 0; b < STRB_WIDTH; b = b + 1) begin
                    if (base_aligned + b < MEM_BYTES)
                        rd_word[b*8 +: 8] = mem[base_aligned + b];
                end
                beat_u = addr_user_fn(rd_addr);
                rid   <= rd_id;
                rdata <= rd_word;
                rresp <= addr_resp_fn(rd_addr);
                ruser <= beat_u[RUSER_W-1:0];
                rvalid <= 1'b1;
                if (rd_rem == 8'd0) begin
                    rlast     <= 1'b1;
                    rd_active <= 1'b0;
                end else begin
                    rlast   <= 1'b0;
                    rd_rem  <= rd_rem - 8'd1;
                    rd_addr <= next_addr_fn(rd_addr, rd_orig, rd_size, rd_burst, rd_orig_len);
                end
            end
        end
    end
endmodule


// Self-contained per-instance AXI4 Adapter Verification Harness
module adapter_harness #(
    parameter S_DATA_WIDTH = 32,
    parameter M_DATA_WIDTH = 128,
    parameter ID_WIDTH     = 6,
    parameter AWUSER_EN    = 1,
    parameter AWUSER_W     = 3,
    parameter WUSER_EN     = 1,
    parameter WUSER_W      = 4,
    parameter BUSER_EN     = 1,
    parameter BUSER_W      = 3,
    parameter ARUSER_EN    = 1,
    parameter ARUSER_W     = 3,
    parameter RUSER_EN     = 1,
    parameter RUSER_W      = 4,
    parameter CONV_BURST   = 1,
    parameter CONV_NARROW  = 0,
    parameter FWD_ID       = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] stall_seed,
    output integer     total_errs
);
    localparam ADDR_WIDTH   = 16;
    localparam S_STRB_WIDTH = S_DATA_WIDTH / 8;
    localparam M_STRB_WIDTH = M_DATA_WIDTH / 8;
    localparam S_LSB        = $clog2(S_STRB_WIDTH);
    localparam M_LSB        = $clog2(M_STRB_WIDTH);
    localparam MEM_BYTES    = 16384;

    reg  [ID_WIDTH-1:0]     s_awid    = 0;
    reg  [ADDR_WIDTH-1:0]   s_awaddr  = 0;
    reg  [7:0]              s_awlen   = 0;
    reg  [2:0]              s_awsize  = 0;
    reg  [1:0]              s_awburst = 0;
    reg                     s_awlock  = 0;
    reg  [3:0]              s_awcache = 0;
    reg  [2:0]              s_awprot  = 0;
    reg  [3:0]              s_awqos   = 0;
    reg  [3:0]              s_awregion= 0;
    reg  [AWUSER_W-1:0]     s_awuser  = 0;
    reg                     s_awvalid = 0;
    wire                    s_awready;

    reg  [S_DATA_WIDTH-1:0] s_wdata   = 0;
    reg  [S_STRB_WIDTH-1:0] s_wstrb   = 0;
    reg                     s_wlast   = 0;
    reg  [WUSER_W-1:0]      s_wuser   = 0;
    reg                     s_wvalid  = 0;
    wire                    s_wready;

    wire [ID_WIDTH-1:0]     s_bid;
    wire [1:0]              s_bresp;
    wire [BUSER_W-1:0]      s_buser;
    wire                    s_bvalid;
    reg                     s_bready  = 0;

    reg  [ID_WIDTH-1:0]     s_arid    = 0;
    reg  [ADDR_WIDTH-1:0]   s_araddr  = 0;
    reg  [7:0]              s_arlen   = 0;
    reg  [2:0]              s_arsize  = 0;
    reg  [2:0]              s_arprot  = 0;
    reg  [1:0]              s_arburst = 0;
    reg                     s_arlock  = 0;
    reg  [3:0]              s_arcache = 0;
    reg  [3:0]              s_arqos   = 0;
    reg  [3:0]              s_arregion= 0;
    reg  [ARUSER_W-1:0]     s_aruser  = 0;
    reg                     s_arvalid = 0;
    wire                    s_arready;

    wire [ID_WIDTH-1:0]     s_rid;
    wire [S_DATA_WIDTH-1:0] s_rdata;
    wire [1:0]              s_rresp;
    wire                    s_rlast;
    wire [RUSER_W-1:0]      s_ruser;
    wire                    s_rvalid;
    reg                     s_rready  = 0;

    wire [ID_WIDTH-1:0]     m_awid, m_bid, m_arid, m_rid;
    wire [ADDR_WIDTH-1:0]   m_awaddr, m_araddr;
    wire [7:0]              m_awlen, m_arlen;
    wire [2:0]              m_awsize, m_arsize, m_awprot, m_arprot;
    wire [1:0]              m_awburst, m_arburst, m_bresp, m_rresp;
    wire                    m_awlock, m_arlock, m_awvalid, m_awready, m_wlast, m_wvalid, m_wready;
    wire                    m_bvalid, m_bready, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
    wire [3:0]              m_awcache, m_awqos, m_awregion, m_arcache, m_arqos, m_arregion;
    wire [AWUSER_W-1:0]     m_awuser;
    wire [M_DATA_WIDTH-1:0] m_wdata, m_rdata;
    wire [M_STRB_WIDTH-1:0] m_wstrb;
    wire [WUSER_W-1:0]      m_wuser;
    wire [BUSER_W-1:0]      m_buser;
    wire [ARUSER_W-1:0]     m_aruser;
    wire [RUSER_W-1:0]      m_ruser;

    integer mem_errs, aw_cmd_cnt, ar_cmd_cnt, local_errs;
    wire [ADDR_WIDTH-1:0] last_awaddr, last_araddr;
    wire [7:0]            last_awlen, last_arlen;
    wire [2:0]            last_awsize, last_arsize;
    wire [1:0]            last_awburst, last_arburst;
    wire [ID_WIDTH-1:0]   last_awid, last_arid;
    wire [AWUSER_W-1:0]   last_awuser;
    wire [WUSER_W-1:0]    last_wuser;
    wire [ARUSER_W-1:0]   last_aruser;

    reg [7:0] ref_mem [0:MEM_BYTES-1];
    integer init_i;
    initial begin
        local_errs = 0;
        for (init_i = 0; init_i < MEM_BYTES; init_i = init_i + 1)
            ref_mem[init_i] = 8'h00;
    end

    always @* total_errs = local_errs + mem_errs;

    axi_adapter #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .S_DATA_WIDTH(S_DATA_WIDTH),
        .M_DATA_WIDTH(M_DATA_WIDTH),
        .ID_WIDTH(ID_WIDTH),
        .AWUSER_ENABLE(AWUSER_EN),
        .AWUSER_WIDTH(AWUSER_W),
        .WUSER_ENABLE(WUSER_EN),
        .WUSER_WIDTH(WUSER_W),
        .BUSER_ENABLE(BUSER_EN),
        .BUSER_WIDTH(BUSER_W),
        .ARUSER_ENABLE(ARUSER_EN),
        .ARUSER_WIDTH(ARUSER_W),
        .RUSER_ENABLE(RUSER_EN),
        .RUSER_WIDTH(RUSER_W),
        .CONVERT_BURST(CONV_BURST),
        .CONVERT_NARROW_BURST(CONV_NARROW),
        .FORWARD_ID(FWD_ID)
    ) dut (
        .clk(clk), .rst(rst),
        .s_axi_awid(s_awid), .s_axi_awaddr(s_awaddr), .s_axi_awlen(s_awlen), .s_axi_awsize(s_awsize),
        .s_axi_awburst(s_awburst), .s_axi_awlock(s_awlock), .s_axi_awcache(s_awcache), .s_axi_awprot(s_awprot),
        .s_axi_awqos(s_awqos), .s_axi_awregion(s_awregion), .s_axi_awuser(s_awuser),
        .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
        .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wlast(s_wlast), .s_axi_wuser(s_wuser),
        .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),
        .s_axi_bid(s_bid), .s_axi_bresp(s_bresp), .s_axi_buser(s_buser),
        .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
        .s_axi_arid(s_arid), .s_axi_araddr(s_araddr), .s_axi_arlen(s_arlen), .s_axi_arsize(s_arsize),
        .s_axi_arburst(s_arburst), .s_axi_arlock(s_arlock), .s_axi_arcache(s_arcache), .s_axi_arprot(s_arprot),
        .s_axi_arqos(s_arqos), .s_axi_arregion(s_arregion), .s_axi_aruser(s_aruser),
        .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
        .s_axi_rid(s_rid), .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rlast(s_rlast),
        .s_axi_ruser(s_ruser), .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),

        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize),
        .m_axi_awburst(m_awburst), .m_axi_awlock(m_awlock), .m_axi_awcache(m_awcache), .m_axi_awprot(m_awprot),
        .m_axi_awqos(m_awqos), .m_axi_awregion(m_awregion), .m_axi_awuser(m_awuser),
        .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast), .m_axi_wuser(m_wuser),
        .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_buser(m_buser),
        .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize),
        .m_axi_arburst(m_arburst), .m_axi_arlock(m_arlock), .m_axi_arcache(m_arcache), .m_axi_arprot(m_arprot),
        .m_axi_arqos(m_arqos), .m_axi_arregion(m_arregion), .m_axi_aruser(m_aruser),
        .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
        .m_axi_ruser(m_ruser), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready)
    );

    axi_mem_slave #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(M_DATA_WIDTH), .ID_WIDTH(ID_WIDTH),
        .AWUSER_W(AWUSER_W), .WUSER_W(WUSER_W), .BUSER_W(BUSER_W),
        .ARUSER_W(ARUSER_W), .RUSER_W(RUSER_W), .MEM_BYTES(MEM_BYTES)
    ) u_mem (
        .clk(clk), .rst(rst), .stall_seed(stall_seed),
        .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize), .awburst(m_awburst),
        .awlock(m_awlock), .awcache(m_awcache), .awprot(m_awprot), .awqos(m_awqos), .awregion(m_awregion),
        .awuser(m_awuser), .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wuser(m_wuser), .wvalid(m_wvalid), .wready(m_wready),
        .bid(m_bid), .bresp(m_bresp), .buser(m_buser), .bvalid(m_bvalid), .bready(m_bready),
        .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize), .arburst(m_arburst),
        .arlock(m_arlock), .arcache(m_arcache), .arprot(m_arprot), .arqos(m_arqos), .arregion(m_arregion),
        .aruser(m_aruser), .arvalid(m_arvalid), .arready(m_arready),
        .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast), .ruser(m_ruser),
        .rvalid(m_rvalid), .rready(m_rready),
        .err_cnt(mem_errs), .aw_cmd_cnt(aw_cmd_cnt), .ar_cmd_cnt(ar_cmd_cnt),
        .last_awaddr(last_awaddr), .last_awlen(last_awlen), .last_awsize(last_awsize), .last_awburst(last_awburst),
        .last_awid(last_awid), .last_awuser(last_awuser), .last_wuser(last_wuser),
        .last_araddr(last_araddr), .last_arlen(last_arlen), .last_arsize(last_arsize), .last_arburst(last_arburst),
        .last_arid(last_arid), .last_aruser(last_aruser)
    );

    function [ADDR_WIDTH-1:0] step_s;
        input [ADDR_WIDTH-1:0] cur, orig;
        input [2:0] sz;
        input [1:0] btype;
        input [7:0] len;
        reg [ADDR_WIDTH-1:0] bstep, amask, wm, inc_a;
        begin
            bstep = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << sz);
            amask = ~(bstep - 1'b1);
            case (len)
                8'd1:    wm = (bstep << 1) - 1'b1;
                8'd3:    wm = (bstep << 2) - 1'b1;
                8'd7:    wm = (bstep << 3) - 1'b1;
                default: wm = (bstep << 4) - 1'b1;
            endcase
            inc_a = (cur + bstep) & amask;
            case (btype)
                2'b00:   step_s = orig;
                2'b10:   step_s = (cur & ~wm) | (inc_a & wm);
                default: step_s = inc_a;
            endcase
        end
    endfunction

    // Drive write burst on @(negedge clk) (zero Verilator race!) and update ref_mem
    task automatic do_write(
        input [ID_WIDTH-1:0]   id,
        input [ADDR_WIDTH-1:0] addr,
        input [7:0]            len,
        input [2:0]            sz,
        input [1:0]            btype,
        input [3:0]            cache,
        input [AWUSER_W-1:0]   awu,
        input [WUSER_W-1:0]    wu,
        input [31:0]           pseed,
        output [1:0]           got_bresp,
        output [BUSER_W-1:0]   got_buser
    );
        integer beat, k, bstep, lane_lo, lane_hi, word_base;
        reg [ADDR_WIDTH-1:0] cur_a, aligned_a;
        reg [S_DATA_WIDTH-1:0] wd;
        reg [S_STRB_WIDTH-1:0] ws;
        reg [31:0] ps;
        begin
            ps = pseed;
            @(negedge clk);
            s_awid    = id;
            s_awaddr  = addr;
            s_awlen   = len;
            s_awsize  = sz;
            s_awburst = btype;
            s_awcache = cache;
            s_awuser  = awu;
            s_awvalid = 1'b1;
            while (!s_awready) @(negedge clk);
            @(negedge clk);
            s_awvalid = 1'b0;

            cur_a = addr;
            bstep = (1 << sz);
            for (beat = 0; beat <= len; beat = beat + 1) begin
                word_base = (cur_a >> S_LSB) << S_LSB;
                aligned_a = (cur_a >> sz) << sz;
                lane_lo   = cur_a - word_base;
                lane_hi   = aligned_a + bstep - 1 - word_base;
                wd = {S_DATA_WIDTH{1'b0}};
                ws = {S_STRB_WIDTH{1'b0}};
                for (k = 0; k < S_STRB_WIDTH; k = k + 1) begin
                    ps = {ps[30:0], ps[31] ^ ps[21] ^ ps[1] ^ ps[0]} + 32'h1357_2468;
                    wd[k*8 +: 8] = ps[7:0];
                    if (k >= lane_lo && k <= lane_hi) begin
                        // Exercise sparse strobe holes on beat>0 when len>=3
                        if (!(len >= 8'd3 && beat == 1 && k == lane_lo && (lane_hi > lane_lo))) begin
                            ws[k] = 1'b1;
                            ref_mem[word_base + k] = ps[7:0];
                        end
                    end
                end
                s_wdata  = wd;
                s_wstrb  = ws;
                s_wlast  = (beat == len);
                s_wuser  = wu;
                s_wvalid = 1'b1;
                // Inject periodic master-side backpressure / gaps
                while (!s_wready) @(negedge clk);
                @(negedge clk);
                s_wvalid = 1'b0;
                s_wlast  = 1'b0;
                if ((ps[1:0] == 2'b11) && (beat < len)) @(negedge clk);
                cur_a = step_s(cur_a, addr, sz, btype, len);
            end

            // Wait for B response with periodic bready stall
            @(negedge clk);
            s_bready = 1'b1;
            while (!s_bvalid) @(negedge clk);
            if (s_bid !== id) begin
                $display("FAIL(%0d->%0d): BID mismatch got=%0h exp=%0h", S_DATA_WIDTH, M_DATA_WIDTH, s_bid, id);
                local_errs = local_errs + 1;
            end
            if (!BUSER_EN && (s_buser !== {BUSER_W{1'b0}})) begin
                $display("FAIL(%0d->%0d): disabled s_buser nonzero=%0h", S_DATA_WIDTH, M_DATA_WIDTH, s_buser);
                local_errs = local_errs + 1;
            end
            if (!FWD_ID && (last_awid !== {ID_WIDTH{1'b0}})) begin
                $display("FAIL(%0d->%0d): FORWARD_ID=0 leaked m_awid=%0h", S_DATA_WIDTH, M_DATA_WIDTH, last_awid);
                local_errs = local_errs + 1;
            end
            if (!AWUSER_EN && (last_awuser !== {AWUSER_W{1'b0}})) begin
                $display("FAIL(%0d->%0d): disabled m_awuser nonzero=%0h", S_DATA_WIDTH, M_DATA_WIDTH, last_awuser);
                local_errs = local_errs + 1;
            end
            if (!WUSER_EN && (last_wuser !== {WUSER_W{1'b0}})) begin
                $display("FAIL(%0d->%0d): disabled m_wuser nonzero=%0h", S_DATA_WIDTH, M_DATA_WIDTH, last_wuser);
                local_errs = local_errs + 1;
            end
            got_bresp = s_bresp;
            got_buser = s_buser;
            @(negedge clk);
            s_bready = 1'b0;

            // Verify byte-for-byte backing memory consistency across +/- 64B neighborhood
            for (k = ((addr >= 64) ? (addr - 64) : 0); k < ((addr + 1536 < MEM_BYTES) ? (addr + 1536) : MEM_BYTES); k = k + 1) begin
                if (u_mem.mem[k] !== ref_mem[k]) begin
                    $display("FAIL(%0d->%0d): mem[0x%0h] mismatch after write(addr=0x%0h len=%0d sz=%0d b=%0d): got=0x%02h exp=0x%02h",
                             S_DATA_WIDTH, M_DATA_WIDTH, k, addr, len, sz, btype, u_mem.mem[k], ref_mem[k]);
                    local_errs = local_errs + 1;
                    k = MEM_BYTES; // report first byte error per burst
                end
            end
        end
    endtask

    // Drive read burst on @(negedge clk) and check every addressed byte lane + framing
    task automatic do_read(
        input [ID_WIDTH-1:0]   id,
        input [ADDR_WIDTH-1:0] addr,
        input [7:0]            len,
        input [2:0]            sz,
        input [1:0]            btype,
        input [3:0]            cache,
        input [ARUSER_W-1:0]   aru,
        output [1:0]           first_rresp
    );
        integer beat, k, bstep, lane_lo, lane_hi, word_base;
        reg [ADDR_WIDTH-1:0] cur_a, aligned_a;
        begin
            @(negedge clk);
            s_arid    = id;
            s_araddr  = addr;
            s_arlen   = len;
            s_arsize  = sz;
            s_arburst = btype;
            s_arcache = cache;
            s_aruser  = aru;
            s_arvalid = 1'b1;
            while (!s_arready) @(negedge clk);
            @(negedge clk);
            s_arvalid = 1'b0;

            cur_a = addr;
            bstep = (1 << sz);
            first_rresp = 2'd0;
            for (beat = 0; beat <= len; beat = beat + 1) begin
                // Toggle s_rready to stress output skid/FIFO buffering
                if ((beat & 1) == 1) begin
                    s_rready = 1'b0;
                    @(negedge clk);
                end
                s_rready = 1'b1;
                while (!s_rvalid) @(negedge clk);

                if (s_rid !== id) begin
                    $display("FAIL(%0d->%0d): RID mismatch got=%0h exp=%0h", S_DATA_WIDTH, M_DATA_WIDTH, s_rid, id);
                    local_errs = local_errs + 1;
                end
                if (s_rlast !== (beat == len)) begin
                    $display("FAIL(%0d->%0d): RLAST mismatch at beat=%0d/%0d got=%0b", S_DATA_WIDTH, M_DATA_WIDTH, beat, len, s_rlast);
                    local_errs = local_errs + 1;
                end
                if (!RUSER_EN && (s_ruser !== {RUSER_W{1'b0}})) begin
                    $display("FAIL(%0d->%0d): disabled s_ruser nonzero=%0h", S_DATA_WIDTH, M_DATA_WIDTH, s_ruser);
                    local_errs = local_errs + 1;
                end
                if (beat == 0) first_rresp = s_rresp;

                word_base = (cur_a >> S_LSB) << S_LSB;
                aligned_a = (cur_a >> sz) << sz;
                lane_lo   = cur_a - word_base;
                lane_hi   = aligned_a + bstep - 1 - word_base;
                for (k = lane_lo; k <= lane_hi; k = k + 1) begin
                    if (s_rdata[k*8 +: 8] !== ref_mem[word_base + k]) begin
                        $display("FAIL(%0d->%0d): RDATA byte mismatch addr=0x%0h beat=%0d lane=%0d got=0x%02h exp=0x%02h",
                                 S_DATA_WIDTH, M_DATA_WIDTH, addr, beat, k, s_rdata[k*8 +: 8], ref_mem[word_base + k]);
                        local_errs = local_errs + 1;
                    end
                end

                @(negedge clk);
                cur_a = step_s(cur_a, addr, sz, btype, len);
            end
            s_rready = 1'b0;

            if (!FWD_ID && (last_arid !== {ID_WIDTH{1'b0}})) begin
                $display("FAIL(%0d->%0d): FORWARD_ID=0 leaked m_arid=%0h", S_DATA_WIDTH, M_DATA_WIDTH, last_arid);
                local_errs = local_errs + 1;
            end
            if (!ARUSER_EN && (last_aruser !== {ARUSER_W{1'b0}})) begin
                $display("FAIL(%0d->%0d): disabled m_aruser nonzero=%0h", S_DATA_WIDTH, M_DATA_WIDTH, last_aruser);
                local_errs = local_errs + 1;
            end
        end
    endtask
endmodule


module tb #(
    parameter integer SEED = 101
);
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    integer rng_seed;
    wire [31:0] seed_w = SEED;

    integer err_eq, err_up32, err_up64, err_dn128, err_dn256;
    integer tb_errs = 0;

    // 1. Equal-width 64->64 (FORWARD_ID=0, multi-bit USER disabled)
    adapter_harness #(
        .S_DATA_WIDTH(64), .M_DATA_WIDTH(64), .ID_WIDTH(6),
        .AWUSER_EN(0), .AWUSER_W(4), .WUSER_EN(0), .WUSER_W(5), .BUSER_EN(0), .BUSER_W(3),
        .ARUSER_EN(0), .ARUSER_W(4), .RUSER_EN(0), .RUSER_W(6),
        .CONV_BURST(1), .CONV_NARROW(0), .FWD_ID(0)
    ) h_eq (.clk(clk), .rst(rst), .stall_seed(seed_w ^ 32'h1111), .total_errs(err_eq));

    // 2. Upsize 32->128 (FORWARD_ID=1, CONVERT_BURST=1, CONVERT_NARROW_BURST=0)
    adapter_harness #(
        .S_DATA_WIDTH(32), .M_DATA_WIDTH(128), .ID_WIDTH(6),
        .AWUSER_EN(1), .AWUSER_W(3), .WUSER_EN(1), .WUSER_W(4), .BUSER_EN(1), .BUSER_W(3),
        .ARUSER_EN(1), .ARUSER_W(3), .RUSER_EN(1), .RUSER_W(4),
        .CONV_BURST(1), .CONV_NARROW(0), .FWD_ID(1)
    ) h_up32 (.clk(clk), .rst(rst), .stall_seed(seed_w ^ 32'h2222), .total_errs(err_up32));

    // 3. Upsize 64->256 (FORWARD_ID=1, CONVERT_BURST=1, CONVERT_NARROW_BURST=1)
    adapter_harness #(
        .S_DATA_WIDTH(64), .M_DATA_WIDTH(256), .ID_WIDTH(6),
        .AWUSER_EN(1), .AWUSER_W(4), .WUSER_EN(1), .WUSER_W(4), .BUSER_EN(1), .BUSER_W(4),
        .ARUSER_EN(1), .ARUSER_W(4), .RUSER_EN(1), .RUSER_W(4),
        .CONV_BURST(1), .CONV_NARROW(1), .FWD_ID(1)
    ) h_up64 (.clk(clk), .rst(rst), .stall_seed(seed_w ^ 32'h3333), .total_errs(err_up64));

    // 4. Downsize 128->32 (FORWARD_ID=1, multi-bit BUSER_W=5)
    adapter_harness #(
        .S_DATA_WIDTH(128), .M_DATA_WIDTH(32), .ID_WIDTH(6),
        .AWUSER_EN(1), .AWUSER_W(3), .WUSER_EN(1), .WUSER_W(4), .BUSER_EN(1), .BUSER_W(5),
        .ARUSER_EN(1), .ARUSER_W(3), .RUSER_EN(1), .RUSER_W(4),
        .CONV_BURST(1), .CONV_NARROW(1), .FWD_ID(1)
    ) h_dn128 (.clk(clk), .rst(rst), .stall_seed(seed_w ^ 32'h4444), .total_errs(err_dn128));

    // 5. Downsize 256->64 (FORWARD_ID=1)
    adapter_harness #(
        .S_DATA_WIDTH(256), .M_DATA_WIDTH(64), .ID_WIDTH(6),
        .AWUSER_EN(1), .AWUSER_W(4), .WUSER_EN(1), .WUSER_W(4), .BUSER_EN(1), .BUSER_W(4),
        .ARUSER_EN(1), .ARUSER_W(4), .RUSER_EN(1), .RUSER_W(4),
        .CONV_BURST(1), .CONV_NARROW(1), .FWD_ID(1)
    ) h_dn256 (.clk(clk), .rst(rst), .stall_seed(seed_w ^ 32'h5555), .total_errs(err_dn256));

    // Watchdog
    initial begin
        #400000;
        $display("FAIL: global watchdog timeout!");
        $finish;
    end

    reg [1:0]  bresp_out, rresp_out;
    reg [2:0]  bu3;
    reg [3:0]  bu4;
    reg [4:0]  bu5;
    integer    c0, r_iter;
    reg [15:0] r_addr;
    reg [7:0]  r_len;
    reg [2:0]  r_sz;

    initial begin
        rng_seed = SEED;
        repeat (6) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);

        // --- Phase 1: Equal-width 64->64 (FORWARD_ID=0, USER_ENABLE=0) ---
        h_eq.do_write(6'h2A, 16'h0100, 8'd5, 3'd3, 2'b01, 4'b0010, 4'hF, 5'h1F, rng_seed + 1, bresp_out, bu3);
        h_eq.do_read (6'h15, 16'h0100, 8'd5, 3'd3, 2'b01, 4'b0010, 4'hF, rresp_out);
        h_eq.do_write(6'h31, 16'h0124, 8'd3, 3'd2, 2'b10, 4'b0000, 4'hA, 5'h15, rng_seed + 2, bresp_out, bu3);
        h_eq.do_read (6'h07, 16'h0124, 8'd3, 3'd2, 2'b10, 4'b0000, 4'hA, rresp_out);

        // --- Phase 2: Upsize 32->128 (CONVERT_NARROW_BURST=0) ---
        // 2a. Repacked INCR starting at sub-word offset 0x0C spanning 2 wide 16B beats (5x4B: 0x20C..0x21F -> 2 wide words)
        c0 = h_up32.aw_cmd_cnt;
        h_up32.do_write(6'h11, 16'h020C, 8'd4, 3'd2, 2'b01, 4'b0010, 3'h5, 4'h9, rng_seed + 10, bresp_out, bu3);
        if (h_up32.aw_cmd_cnt != c0 + 1 || h_up32.last_awaddr !== 16'h0200 || h_up32.last_awlen !== 8'd1 ||
            h_up32.last_awsize !== 3'd4 || h_up32.last_awburst !== 2'b01) begin
            $display("FAIL(32->128): repacked AW header mismatch addr=0x%0h len=%0d sz=%0d b=%0d",
                     h_up32.last_awaddr, h_up32.last_awlen, h_up32.last_awsize, h_up32.last_awburst);
            tb_errs = tb_errs + 1;
        end
        c0 = h_up32.ar_cmd_cnt;
        h_up32.do_read(6'h12, 16'h020C, 8'd4, 3'd2, 2'b01, 4'b0010, 3'h6, rresp_out);
        if (h_up32.ar_cmd_cnt != c0 + 1 || h_up32.last_araddr !== 16'h0200 || h_up32.last_arlen !== 8'd1 ||
            h_up32.last_arsize !== 3'd4 || h_up32.last_arburst !== 2'b01) begin
            $display("FAIL(32->128): repacked AR header mismatch addr=0x%0h len=%0d sz=%0d b=%0d",
                     h_up32.last_araddr, h_up32.last_arlen, h_up32.last_arsize, h_up32.last_arburst);
            tb_errs = tb_errs + 1;
        end

        // 2b. Non-modifiable cache[1]==0 -> MUST NOT repack!
        h_up32.do_write(6'h13, 16'h0244, 8'd3, 3'd2, 2'b01, 4'b0000, 3'h2, 4'h3, rng_seed + 11, bresp_out, bu3);
        if (h_up32.last_awsize !== 3'd2 || h_up32.last_awlen !== 8'd3 || h_up32.last_awaddr !== 16'h0244) begin
            $display("FAIL(32->128): cache[1]=0 illegally repacked!");
            tb_errs = tb_errs + 1;
        end
        h_up32.do_read(6'h14, 16'h0244, 8'd3, 3'd2, 2'b01, 4'b0000, 3'h2, rresp_out);

        // 2c. Narrow size=1 with CONVERT_NARROW_BURST=0 -> MUST pass through!
        h_up32.do_write(6'h15, 16'h0282, 8'd5, 3'd1, 2'b01, 4'b0010, 3'h4, 4'h7, rng_seed + 12, bresp_out, bu3);
        if (h_up32.last_awsize !== 3'd1 || h_up32.last_awlen !== 8'd5) begin
            $display("FAIL(32->128): narrow burst illegally repacked when CONVERT_NARROW_BURST=0!");
            tb_errs = tb_errs + 1;
        end
        h_up32.do_read(6'h16, 16'h0282, 8'd5, 3'd1, 2'b01, 4'b0010, 3'h4, rresp_out);

        // 2d. FIXED burst (cache[1]=1) -> MUST pass through as FIXED!
        h_up32.do_write(6'h17, 16'h02C8, 8'd3, 3'd2, 2'b00, 4'b0010, 3'h1, 4'h2, rng_seed + 13, bresp_out, bu3);
        if (h_up32.last_awburst !== 2'b00 || h_up32.last_awsize !== 3'd2) begin
            $display("FAIL(32->128): FIXED burst illegally converted!");
            tb_errs = tb_errs + 1;
        end
        h_up32.do_read(6'h18, 16'h02C8, 8'd3, 3'd2, 2'b00, 4'b0010, 3'h1, rresp_out);

        // 2e. WRAP bursts: (i) 16B wrap starting at 0x30C (fits 1 master word -> repacked len=0),
        //                 (ii) 32B wrap starting at 0x340 (aligned to wrap boundary -> repacked len=1),
        //                 (iii) 32B wrap starting at 0x36C (unaligned to wrap boundary -> passthrough WRAP)
        h_up32.do_write(6'h19, 16'h030C, 8'd3, 3'd2, 2'b10, 4'b0010, 3'h3, 4'hA, rng_seed + 14, bresp_out, bu3);
        if (h_up32.last_awburst !== 2'b01 || h_up32.last_awlen !== 8'd0 || h_up32.last_awaddr !== 16'h0300) begin
            $display("FAIL(32->128): single-master-word WRAP repack mismatch: addr=0x%0h len=%0d b=%0d",
                     h_up32.last_awaddr, h_up32.last_awlen, h_up32.last_awburst);
            tb_errs = tb_errs + 1;
        end
        h_up32.do_read(6'h1A, 16'h030C, 8'd3, 3'd2, 2'b10, 4'b0010, 3'h3, rresp_out);

        h_up32.do_write(6'h1B, 16'h0340, 8'd7, 3'd2, 2'b10, 4'b0010, 3'h3, 4'hB, rng_seed + 15, bresp_out, bu3);
        if (h_up32.last_awburst !== 2'b01 || h_up32.last_awlen !== 8'd1 || h_up32.last_awaddr !== 16'h0340) begin
            $display("FAIL(32->128): boundary-aligned WRAP repack mismatch!");
            tb_errs = tb_errs + 1;
        end
        h_up32.do_read(6'h1C, 16'h0340, 8'd7, 3'd2, 2'b10, 4'b0010, 3'h3, rresp_out);

        h_up32.do_write(6'h1D, 16'h036C, 8'd7, 3'd2, 2'b10, 4'b0010, 3'h3, 4'hC, rng_seed + 16, bresp_out, bu3);
        if (h_up32.last_awburst !== 2'b10 || h_up32.last_awlen !== 8'd7) begin
            $display("FAIL(32->128): unaligned multi-word WRAP illegally repacked!");
            tb_errs = tb_errs + 1;
        end
        h_up32.do_read(6'h1E, 16'h036C, 8'd7, 3'd2, 2'b10, 4'b0010, 3'h3, rresp_out);

        // --- Phase 3: Upsize 64->256 with CONVERT_NARROW_BURST=1 & Unaligned Start ---
        h_up64.do_write(6'h21, 16'h0413, 8'd9, 3'd2, 2'b01, 4'b0010, 4'h9, 4'h5, rng_seed + 20, bresp_out, bu4);
        if (h_up64.last_awsize !== 3'd5 || h_up64.last_awaddr !== 16'h0400 || h_up64.last_awlen !== 8'd1) begin
            $display("FAIL(64->256): narrow unaligned repack AW mismatch addr=0x%0h len=%0d sz=%0d",
                     h_up64.last_awaddr, h_up64.last_awlen, h_up64.last_awsize);
            tb_errs = tb_errs + 1;
        end
        h_up64.do_read(6'h22, 16'h0413, 8'd9, 3'd2, 2'b01, 4'b0010, 4'h9, rresp_out);
        h_up64.do_write(6'h23, 16'h0462, 8'd11, 3'd1, 2'b01, 4'b0010, 4'h7, 4'hA, rng_seed + 21, bresp_out, bu4);
        h_up64.do_read (6'h24, 16'h0462, 8'd11, 3'd1, 2'b01, 4'b0010, 4'h7, rresp_out);

        // --- Phase 4: Downsize 128->32 & 256->64 Splitting, WRAP/FIXED, 256-beat Cap, Sticky Errors ---
        // 4a. Unaligned start wide INCR on 128->32: addr=0x0608 (2 master sub-beats in beat0 + 2*4=8 -> len=9)
        c0 = h_dn128.aw_cmd_cnt;
        h_dn128.do_write(6'h28, 16'h0608, 8'd2, 3'd4, 2'b01, 4'b0010, 3'h4, 4'h8, rng_seed + 30, bresp_out, bu5);
        if (h_dn128.aw_cmd_cnt != c0 + 1 || h_dn128.last_awlen !== 8'd9 || h_dn128.last_awsize !== 3'd2) begin
            $display("FAIL(128->32): unaligned start AW split mismatch cnt=%0d len=%0d sz=%0d",
                     h_dn128.aw_cmd_cnt - c0, h_dn128.last_awlen, h_dn128.last_awsize);
            tb_errs = tb_errs + 1;
        end
        h_dn128.do_read(6'h29, 16'h0608, 8'd2, 3'd4, 2'b01, 4'b0010, 3'h4, rresp_out);

        // 4b. Narrow burst (size=1 <= M_BURST_SIZE=2) passthrough WRAP on 128->32
        c0 = h_dn128.aw_cmd_cnt;
        h_dn128.do_write(6'h2A, 16'h0686, 8'd3, 3'd1, 2'b10, 4'b0010, 3'h2, 4'h6, rng_seed + 31, bresp_out, bu5);
        if (h_dn128.aw_cmd_cnt != c0 + 1 || h_dn128.last_awburst !== 2'b10 || h_dn128.last_awsize !== 3'd1) begin
            $display("FAIL(128->32): narrow WRAP passthrough mismatch!");
            tb_errs = tb_errs + 1;
        end
        h_dn128.do_read(6'h2B, 16'h0686, 8'd3, 3'd1, 2'b10, 4'b0010, 3'h2, rresp_out);

        // 4c. Wide FIXED (size=4, len=2 -> 3 child INCR bursts, 1 per slave beat!)
        c0 = h_dn128.aw_cmd_cnt;
        h_dn128.do_write(6'h2C, 16'h0704, 8'd2, 3'd4, 2'b00, 4'b0010, 3'h5, 4'h9, rng_seed + 32, bresp_out, bu5);
        if (h_dn128.aw_cmd_cnt != c0 + 3 || h_dn128.last_awburst !== 2'b01 || h_dn128.last_awlen !== 8'd2) begin
            $display("FAIL(128->32): wide FIXED child split mismatch cmds=%0d len=%0d",
                     h_dn128.aw_cmd_cnt - c0, h_dn128.last_awlen);
            tb_errs = tb_errs + 1;
        end
        c0 = h_dn128.ar_cmd_cnt;
        h_dn128.do_read(6'h2D, 16'h0704, 8'd2, 3'd4, 2'b00, 4'b0010, 3'h5, rresp_out);
        if (h_dn128.ar_cmd_cnt != c0 + 3) begin
            $display("FAIL(128->32): wide FIXED read child split mismatch cmds=%0d", h_dn128.ar_cmd_cnt - c0);
            tb_errs = tb_errs + 1;
        end

        // 4d. Wide WRAP crossing wrap boundary: size=4 (16B), len=3 (64B [0x0800..0x083F]), start=0x0820 -> 2 child INCR bursts of 8 beats!
        c0 = h_dn128.aw_cmd_cnt;
        h_dn128.do_write(6'h2E, 16'h0820, 8'd3, 3'd4, 2'b10, 4'b0010, 3'h6, 4'hB, rng_seed + 33, bresp_out, bu5);
        if (h_dn128.aw_cmd_cnt != c0 + 2 || h_dn128.last_awaddr !== 16'h0800 || h_dn128.last_awlen !== 8'd7) begin
            $display("FAIL(128->32): wide WRAP boundary split mismatch cmds=%0d last_addr=0x%0h last_len=%0d",
                     h_dn128.aw_cmd_cnt - c0, h_dn128.last_awaddr, h_dn128.last_awlen);
            tb_errs = tb_errs + 1;
        end
        c0 = h_dn128.ar_cmd_cnt;
        h_dn128.do_read(6'h2F, 16'h0820, 8'd3, 3'd4, 2'b10, 4'b0010, 3'h6, rresp_out);
        if (h_dn128.ar_cmd_cnt != c0 + 2) begin
            $display("FAIL(128->32): wide WRAP read boundary split mismatch cmds=%0d", h_dn128.ar_cmd_cnt - c0);
            tb_errs = tb_errs + 1;
        end

        // 4e. Long wide INCR > 256 master beats: 70 slave beats * 4 = 280 master beats -> child0=256 (len=255), child1=24 (len=23)!
        c0 = h_dn128.aw_cmd_cnt;
        h_dn128.do_write(6'h30, 16'h1000, 8'd69, 3'd4, 2'b01, 4'b0010, 3'h7, 4'hC, rng_seed + 34, bresp_out, bu5);
        if (h_dn128.aw_cmd_cnt != c0 + 2 || h_dn128.last_awlen !== 8'd23) begin
            $display("FAIL(128->32): 256-beat child split mismatch cmds=%0d last_len=%0d",
                     h_dn128.aw_cmd_cnt - c0, h_dn128.last_awlen);
            tb_errs = tb_errs + 1;
        end
        c0 = h_dn128.ar_cmd_cnt;
        h_dn128.do_read(6'h31, 16'h1000, 8'd69, 3'd4, 2'b01, 4'b0010, 3'h7, rresp_out);
        if (h_dn128.ar_cmd_cnt != c0 + 2 || h_dn128.last_arlen !== 8'd23) begin
            $display("FAIL(128->32): 256-beat read child split mismatch cmds=%0d last_len=%0d",
                     h_dn128.ar_cmd_cnt - c0, h_dn128.last_arlen);
            tb_errs = tb_errs + 1;
        end

        // 4f. Sticky highest-severity BRESP/BUSER & RRESP across split beats!
        // WRAP across 0x3800 (SLVERR, u=0x12) -> 0x3810 (DECERR, u=0x1D) -> 0x3820 (EXOKAY, u=0x09) -> 0x3830 (OKAY, u=0x03)
        // Starting at 0x3810 (len=3, size=4, WRAP): child0 covers 0x3810..0x383F (DECERR then EXOKAY then OKAY), child1 covers 0x3800..0x380F (SLVERR)!
        // Overall highest BRESP must stay DECERR (2'b11) with BUSER=5'h1D (not overwritten by child1's SLVERR 2'b10)!
        h_dn128.do_write(6'h32, 16'h3810, 8'd3, 3'd4, 2'b10, 4'b0010, 3'h1, 4'h2, rng_seed + 35, bresp_out, bu5);
        if (bresp_out !== 2'b11 || bu5 !== 5'h1D) begin
            $display("FAIL(128->32): sticky BRESP/BUSER priority failed (DECERR->SLVERR): bresp=%0b buser=0x%0h", bresp_out, bu5);
            tb_errs = tb_errs + 1;
        end
        // Also test child0=SLVERR (0x3800), child1=DECERR (0x3810) via FIXED/WRAP: start at 0x3830 (child0=0x3830 OKAY, child1=0x3800..0x382F SLVERR+DECERR)
        h_dn128.do_write(6'h33, 16'h3830, 8'd3, 3'd4, 2'b10, 4'b0010, 3'h1, 4'h2, rng_seed + 36, bresp_out, bu5);
        if (bresp_out !== 2'b11 || bu5 !== 5'h1D) begin
            $display("FAIL(128->32): sticky BRESP/BUSER upgrade failed (OKAY->DECERR): bresp=%0b buser=0x%0h", bresp_out, bu5);
            tb_errs = tb_errs + 1;
        end
        // Read across 0x37FC..0x380B (beat0 spans 0x37FC OKAY + 0x3800..0x380F -> wait: 16B slave beat at 0x3800 with 0x3800=SLVERR, or 256->64 spanning 0x3800 SLVERR + 0x3810 DECERR in ONE 32B beat!)
        h_dn256.do_write(6'h34, 16'h3800, 8'd1, 3'd5, 2'b01, 4'b0010, 4'h3, 4'h4, rng_seed + 37, bresp_out, bu4);
        // On 256->64 (32B slave beat = 0x3800..0x381F), sub-beats 0..1 hit 0x3800 (SLVERR) and sub-beats 2..3 hit 0x3810 (DECERR); beat 1 hits 0x3820 (EXOKAY) + 0x3830 (OKAY)!
        h_dn256.do_read(6'h35, 16'h3800, 8'd1, 3'd5, 2'b01, 4'b0010, 4'h3, rresp_out);
        if (rresp_out !== 2'b11) begin
            $display("FAIL(256->64): sticky RRESP across sub-beats failed: got=%0b exp=11", rresp_out);
            tb_errs = tb_errs + 1;
        end
        h_dn256.do_read(6'h36, 16'h3820, 8'd0, 3'd5, 2'b01, 4'b0010, 4'h3, rresp_out);
        if (rresp_out !== 2'b01) begin
            $display("FAIL(256->64): sticky RRESP (EXOKAY followed by OKAY) failed: got=%0b exp=01", rresp_out);
            tb_errs = tb_errs + 1;
        end

        // --- Phase 5: Seed-driven randomized bursts across Upsize 64->256 & Downsize 256->64 ---
        for (r_iter = 0; r_iter < 8; r_iter = r_iter + 1) begin
            r_addr = 16'h2000 + ((($random(rng_seed) & 32'h7F)) << 2) + (r_iter[1:0]);
            r_len  = ($random(rng_seed) & 32'h7);
            r_sz   = (r_iter & 1) ? 3'd3 : 3'd2;
            h_up64.do_write(r_iter[5:0], r_addr, r_len, r_sz, 2'b01, 4'b0010, 4'h5, 4'h6, rng_seed + r_iter, bresp_out, bu4);
            h_up64.do_read (r_iter[5:0], r_addr, r_len, r_sz, 2'b01, 4'b0010, 4'h5, rresp_out);

            r_addr = 16'h2800 + ((($random(rng_seed) & 32'h3F)) << 3);
            r_len  = ($random(rng_seed) & 32'h3);
            h_dn256.do_write(r_iter[5:0], r_addr, r_len, 3'd5, 2'b01, 4'b0010, 4'hA, 4'hB, rng_seed + 100 + r_iter, bresp_out, bu4);
            h_dn256.do_read (r_iter[5:0], r_addr, r_len, 3'd5, 2'b01, 4'b0010, 4'hA, rresp_out);
        end

        repeat (10) @(negedge clk);
        tb_errs = tb_errs + err_eq + err_up32 + err_up64 + err_dn128 + err_dn256;
        if (tb_errs == 0) begin
            $display("PASS seed=%0d", SEED);
        end else begin
            $display("FAIL seed=%0d total_errs=%0d", SEED, tb_errs);
        end
        $finish;
    end
endmodule
