/*

Copyright (c) 2021 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * AXI4 lite crossbar (write)
 */
module axil_crossbar_wr #
(
    parameter S_COUNT = 4,
    parameter M_COUNT = 4,
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32,
    parameter STRB_WIDTH = (DATA_WIDTH/8),
    parameter S_ACCEPT = {S_COUNT{32'd16}},
    parameter M_REGIONS = 1,
    parameter M_BASE_ADDR = 0,
    parameter M_ADDR_WIDTH = {M_COUNT{{M_REGIONS{32'd24}}}},
    parameter M_CONNECT = {M_COUNT{{S_COUNT{1'b1}}}},
    parameter M_ISSUE = {M_COUNT{32'd16}},
    parameter M_SECURE = {M_COUNT{1'b0}},
    parameter S_AW_REG_TYPE = {S_COUNT{2'd0}},
    parameter S_W_REG_TYPE = {S_COUNT{2'd0}},
    parameter S_B_REG_TYPE = {S_COUNT{2'd1}},
    parameter M_AW_REG_TYPE = {M_COUNT{2'd1}},
    parameter M_W_REG_TYPE = {M_COUNT{2'd2}},
    parameter M_B_REG_TYPE = {M_COUNT{2'd0}}
)
(
    input  wire                             clk,
    input  wire                             rst,

    /*
     * AXI lite slave interfaces
     */
    input  wire [S_COUNT*ADDR_WIDTH-1:0]    s_axil_awaddr,
    input  wire [S_COUNT*3-1:0]             s_axil_awprot,
    input  wire [S_COUNT-1:0]               s_axil_awvalid,
    output wire [S_COUNT-1:0]               s_axil_awready,
    input  wire [S_COUNT*DATA_WIDTH-1:0]    s_axil_wdata,
    input  wire [S_COUNT*STRB_WIDTH-1:0]    s_axil_wstrb,
    input  wire [S_COUNT-1:0]               s_axil_wvalid,
    output wire [S_COUNT-1:0]               s_axil_wready,
    output wire [S_COUNT*2-1:0]             s_axil_bresp,
    output wire [S_COUNT-1:0]               s_axil_bvalid,
    input  wire [S_COUNT-1:0]               s_axil_bready,

    /*
     * AXI lite master interfaces
     */
    output wire [M_COUNT*ADDR_WIDTH-1:0]    m_axil_awaddr,
    output wire [M_COUNT*3-1:0]             m_axil_awprot,
    output wire [M_COUNT-1:0]               m_axil_awvalid,
    input  wire [M_COUNT-1:0]               m_axil_awready,
    output wire [M_COUNT*DATA_WIDTH-1:0]    m_axil_wdata,
    output wire [M_COUNT*STRB_WIDTH-1:0]    m_axil_wstrb,
    output wire [M_COUNT-1:0]               m_axil_wvalid,
    input  wire [M_COUNT-1:0]               m_axil_wready,
    input  wire [M_COUNT*2-1:0]             m_axil_bresp,
    input  wire [M_COUNT-1:0]               m_axil_bvalid,
    output wire [M_COUNT-1:0]               m_axil_bready
);

localparam CL_S_COUNT = S_COUNT > 1 ? $clog2(S_COUNT) : 1;
localparam CL_M_COUNT = M_COUNT > 1 ? $clog2(M_COUNT) : 1;

wire [S_COUNT*ADDR_WIDTH-1:0]    int_s_axil_awaddr;
wire [S_COUNT*3-1:0]             int_s_axil_awprot;
wire [S_COUNT-1:0]               int_s_axil_awvalid;
wire [S_COUNT-1:0]               int_s_axil_awready;

wire [S_COUNT*M_COUNT-1:0]       int_axil_awvalid;
wire [M_COUNT*S_COUNT-1:0]       int_axil_awready;

wire [S_COUNT*DATA_WIDTH-1:0]    int_s_axil_wdata;
wire [S_COUNT*STRB_WIDTH-1:0]    int_s_axil_wstrb;
wire [S_COUNT-1:0]               int_s_axil_wvalid;
wire [S_COUNT-1:0]               int_s_axil_wready;

wire [S_COUNT*M_COUNT-1:0]       int_axil_wvalid;
wire [M_COUNT*S_COUNT-1:0]       int_axil_wready;

wire [M_COUNT*2-1:0]             int_m_axil_bresp;
wire [M_COUNT-1:0]               int_m_axil_bvalid;
wire [M_COUNT-1:0]               int_m_axil_bready;

wire [M_COUNT*S_COUNT-1:0]       int_axil_bvalid;
wire [S_COUNT*M_COUNT-1:0]       int_axil_bready;

generate

    genvar m, n;

    for (m = 0; m < S_COUNT; m = m + 1) begin : s_ifaces
        localparam FIFO_ADDR_WIDTH = $clog2(S_ACCEPT[m*32 +: 32]) + 1;

        reg [FIFO_ADDR_WIDTH:0] fifo_wr_ptr_reg;
        reg [FIFO_ADDR_WIDTH:0] fifo_rd_ptr_reg;

        (* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
        reg [CL_M_COUNT-1:0] fifo_select[(2**FIFO_ADDR_WIDTH)-1:0];
        (* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
        reg fifo_decerr[(2**FIFO_ADDR_WIDTH)-1:0];

        wire [CL_M_COUNT-1:0] fifo_wr_select;
        wire fifo_wr_decerr;
        wire fifo_wr_en;

        reg [CL_M_COUNT-1:0] fifo_rd_select_reg;
        reg fifo_rd_decerr_reg;
        reg fifo_rd_valid_reg;
        wire fifo_rd_en;
        reg fifo_half_full_reg;

        always @(posedge clk) begin
            if (rst) begin
                fifo_wr_ptr_reg    <= {(FIFO_ADDR_WIDTH+1){1'b0}};
                fifo_rd_ptr_reg    <= {(FIFO_ADDR_WIDTH+1){1'b0}};
                fifo_rd_select_reg <= {CL_M_COUNT{1'b0}};
                fifo_rd_decerr_reg <= 1'b0;
                fifo_rd_valid_reg  <= 1'b0;
                fifo_half_full_reg <= 1'b0;
            end else begin
                if (fifo_wr_en) begin
                    fifo_select[fifo_wr_ptr_reg[FIFO_ADDR_WIDTH-1:0]] <= fifo_wr_select;
                    fifo_decerr[fifo_wr_ptr_reg[FIFO_ADDR_WIDTH-1:0]] <= fifo_wr_decerr;
                    fifo_wr_ptr_reg <= fifo_wr_ptr_reg + 1'b1;
                end

                fifo_rd_valid_reg <= fifo_rd_valid_reg && !fifo_rd_en;

                if ((fifo_rd_ptr_reg != fifo_wr_ptr_reg) && (!fifo_rd_valid_reg || fifo_rd_en)) begin
                    fifo_rd_select_reg <= fifo_select[fifo_rd_ptr_reg[FIFO_ADDR_WIDTH-1:0]];
                    fifo_rd_decerr_reg <= fifo_decerr[fifo_rd_ptr_reg[FIFO_ADDR_WIDTH-1:0]];
                    fifo_rd_valid_reg  <= 1'b1;
                    fifo_rd_ptr_reg    <= fifo_rd_ptr_reg + 1'b1;
                end

                fifo_half_full_reg <= $unsigned(fifo_wr_ptr_reg - fifo_rd_ptr_reg) >= 2**(FIFO_ADDR_WIDTH-1);
            end
        end

        wire [CL_M_COUNT-1:0] a_select;
        wire m_axil_avalid_int;
        wire m_axil_aready_int;

        wire [CL_M_COUNT-1:0] m_wc_select;
        wire m_wc_decerr;
        wire m_wc_valid;
        wire m_wc_ready;

        wire [CL_M_COUNT-1:0] m_rc_select;
        wire m_rc_decerr;
        wire m_rc_valid;
        wire m_rc_ready;

        axil_crossbar_addr #(
            .S(m),
            .S_COUNT(S_COUNT),
            .M_COUNT(M_COUNT),
            .ADDR_WIDTH(ADDR_WIDTH),
            .M_REGIONS(M_REGIONS),
            .M_BASE_ADDR(M_BASE_ADDR),
            .M_ADDR_WIDTH(M_ADDR_WIDTH),
            .M_CONNECT(M_CONNECT),
            .M_SECURE(M_SECURE),
            .WC_OUTPUT(1),
            .CL_M_COUNT(CL_M_COUNT)
        )
        addr_inst (
            .clk(clk),
            .rst(rst),
            .s_axil_aaddr(int_s_axil_awaddr[m*ADDR_WIDTH +: ADDR_WIDTH]),
            .s_axil_aprot(int_s_axil_awprot[m*3 +: 3]),
            .s_axil_avalid(int_s_axil_awvalid[m]),
            .s_axil_aready(int_s_axil_awready[m]),
            .m_select(a_select),
            .m_axil_avalid(m_axil_avalid_int),
            .m_axil_aready(m_axil_aready_int),
            .m_wc_select(m_wc_select),
            .m_wc_decerr(m_wc_decerr),
            .m_wc_valid(m_wc_valid),
            .m_wc_ready(m_wc_ready),
            .m_rc_select(m_rc_select),
            .m_rc_decerr(m_rc_decerr),
            .m_rc_valid(m_rc_valid),
            .m_rc_ready(m_rc_ready)
        );

        reg [CL_M_COUNT-1:0] w_select_reg, w_select_next;
        reg w_drop_reg, w_drop_next;
        reg w_select_valid_reg, w_select_valid_next;

        assign m_wc_ready = !w_select_valid_reg;

        // Present AW to target M only after its companion W-command slot is active (!m_wc_valid)
        wire aw_paired_valid = m_axil_avalid_int && !m_wc_valid;
        assign int_axil_awvalid[m*M_COUNT +: M_COUNT] = aw_paired_valid ? ({{(M_COUNT-1){1'b0}}, 1'b1} << a_select) : {M_COUNT{1'b0}};
        assign m_axil_aready_int = !m_wc_valid && int_axil_awready[a_select*S_COUNT+m];

        always @* begin
            w_select_next = w_select_reg;
            w_drop_next = w_drop_reg && !(int_s_axil_wvalid[m] && int_s_axil_wready[m]);
            w_select_valid_next = w_select_valid_reg && !(int_s_axil_wvalid[m] && int_s_axil_wready[m]);

            if (m_wc_valid && !w_select_valid_reg) begin
                w_select_next = m_wc_select;
                w_drop_next = m_wc_decerr;
                w_select_valid_next = 1'b1;
            end
        end

        always @(posedge clk) begin
            if (rst) begin
                w_select_reg       <= {CL_M_COUNT{1'b0}};
                w_drop_reg         <= 1'b0;
                w_select_valid_reg <= 1'b0;
            end else begin
                w_select_reg       <= w_select_next;
                w_drop_reg         <= w_drop_next;
                w_select_valid_reg <= w_select_valid_next;
            end
        end

        assign int_axil_wvalid[m*M_COUNT +: M_COUNT] = (int_s_axil_wvalid[m] && w_select_valid_reg && !w_drop_reg)
                                                       ? ({{(M_COUNT-1){1'b0}}, 1'b1} << w_select_reg)
                                                       : {M_COUNT{1'b0}};
        assign int_s_axil_wready[m] = w_select_valid_reg && (w_drop_reg || int_axil_wready[w_select_reg*S_COUNT+m]);

        assign fifo_wr_select = m_rc_select;
        assign fifo_wr_decerr = m_rc_decerr;
        assign fifo_wr_en = m_rc_valid && !fifo_half_full_reg;
        assign m_rc_ready = !fifo_half_full_reg;

        wire [CL_M_COUNT-1:0] b_select = M_COUNT > 1 ? fifo_rd_select_reg : {CL_M_COUNT{1'b0}};
        wire b_decerr = fifo_rd_decerr_reg;
        wire b_valid  = fifo_rd_valid_reg;

        wire [1:0] m_axil_bresp_mux  = !b_valid ? 2'b00 : (b_decerr ? 2'b11 : int_m_axil_bresp[b_select*2 +: 2]);
        wire       m_axil_bvalid_mux = b_valid && (b_decerr ? 1'b1 : int_axil_bvalid[b_select*S_COUNT+m]);
        wire       m_axil_bready_mux;

        assign int_axil_bready[m*M_COUNT +: M_COUNT] = (b_valid && !b_decerr && m_axil_bready_mux)
                                                       ? ({{(M_COUNT-1){1'b0}}, 1'b1} << b_select)
                                                       : {M_COUNT{1'b0}};

        assign fifo_rd_en = m_axil_bvalid_mux && m_axil_bready_mux && b_valid;

        axil_register_wr #(
            .DATA_WIDTH(DATA_WIDTH),
            .ADDR_WIDTH(ADDR_WIDTH),
            .STRB_WIDTH(STRB_WIDTH),
            .AW_REG_TYPE(S_AW_REG_TYPE[m*2 +: 2]),
            .W_REG_TYPE(S_W_REG_TYPE[m*2 +: 2]),
            .B_REG_TYPE(S_B_REG_TYPE[m*2 +: 2])
        )
        reg_inst (
            .clk(clk),
            .rst(rst),
            .s_axil_awaddr(s_axil_awaddr[m*ADDR_WIDTH +: ADDR_WIDTH]),
            .s_axil_awprot(s_axil_awprot[m*3 +: 3]),
            .s_axil_awvalid(s_axil_awvalid[m]),
            .s_axil_awready(s_axil_awready[m]),
            .s_axil_wdata(s_axil_wdata[m*DATA_WIDTH +: DATA_WIDTH]),
            .s_axil_wstrb(s_axil_wstrb[m*STRB_WIDTH +: STRB_WIDTH]),
            .s_axil_wvalid(s_axil_wvalid[m]),
            .s_axil_wready(s_axil_wready[m]),
            .s_axil_bresp(s_axil_bresp[m*2 +: 2]),
            .s_axil_bvalid(s_axil_bvalid[m]),
            .s_axil_bready(s_axil_bready[m]),
            .m_axil_awaddr(int_s_axil_awaddr[m*ADDR_WIDTH +: ADDR_WIDTH]),
            .m_axil_awprot(int_s_axil_awprot[m*3 +: 3]),
            .m_axil_awvalid(int_s_axil_awvalid[m]),
            .m_axil_awready(int_s_axil_awready[m]),
            .m_axil_wdata(int_s_axil_wdata[m*DATA_WIDTH +: DATA_WIDTH]),
            .m_axil_wstrb(int_s_axil_wstrb[m*STRB_WIDTH +: STRB_WIDTH]),
            .m_axil_wvalid(int_s_axil_wvalid[m]),
            .m_axil_wready(int_s_axil_wready[m]),
            .m_axil_bresp(m_axil_bresp_mux),
            .m_axil_bvalid(m_axil_bvalid_mux),
            .m_axil_bready(m_axil_bready_mux)
        );
    end // s_ifaces

    for (n = 0; n < M_COUNT; n = n + 1) begin : m_ifaces
        localparam FIFO_ADDR_WIDTH = $clog2(M_ISSUE[n*32 +: 32]) + 1;

        reg [FIFO_ADDR_WIDTH:0] fifo_wr_ptr_reg;
        reg [FIFO_ADDR_WIDTH:0] fifo_rd_ptr_reg;

        (* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
        reg [CL_S_COUNT-1:0] fifo_select[(2**FIFO_ADDR_WIDTH)-1:0];
        wire [CL_S_COUNT-1:0] fifo_wr_select;
        wire fifo_wr_en;
        wire fifo_rd_en;
        reg fifo_half_full_reg;

        wire fifo_empty = (fifo_rd_ptr_reg == fifo_wr_ptr_reg);

        always @(posedge clk) begin
            if (rst) begin
                fifo_wr_ptr_reg    <= {(FIFO_ADDR_WIDTH+1){1'b0}};
                fifo_rd_ptr_reg    <= {(FIFO_ADDR_WIDTH+1){1'b0}};
                fifo_half_full_reg <= 1'b0;
            end else begin
                if (fifo_wr_en) begin
                    fifo_select[fifo_wr_ptr_reg[FIFO_ADDR_WIDTH-1:0]] <= fifo_wr_select;
                    fifo_wr_ptr_reg <= fifo_wr_ptr_reg + 1'b1;
                end
                if (fifo_rd_en) begin
                    fifo_rd_ptr_reg <= fifo_rd_ptr_reg + 1'b1;
                end
                fifo_half_full_reg <= $unsigned(fifo_wr_ptr_reg - fifo_rd_ptr_reg) >= 2**(FIFO_ADDR_WIDTH-1);
            end
        end

        wire [S_COUNT-1:0] a_request;
        wire [S_COUNT-1:0] a_acknowledge;
        wire [S_COUNT-1:0] a_grant;
        wire a_grant_valid;
        wire [CL_S_COUNT-1:0] a_grant_encoded;

        if (S_COUNT > 1) begin : gen_arb
            arbiter #(
                .PORTS(S_COUNT),
                .ARB_TYPE_ROUND_ROBIN(1),
                .ARB_BLOCK(1),
                .ARB_BLOCK_ACK(1),
                .ARB_LSB_HIGH_PRIORITY(1)
            )
            a_arb_inst (
                .clk(clk),
                .rst(rst),
                .request(a_request),
                .acknowledge(a_acknowledge),
                .grant(a_grant),
                .grant_valid(a_grant_valid),
                .grant_encoded(a_grant_encoded)
            );
        end else begin : gen_single_s
            reg grant_1_reg;
            always @(posedge clk) begin
                if (rst) begin
                    grant_1_reg <= 1'b0;
                end else if (grant_1_reg && !a_acknowledge[0]) begin
                    grant_1_reg <= 1'b1;
                end else begin
                    grant_1_reg <= a_request[0];
                end
            end
            assign a_grant         = grant_1_reg;
            assign a_grant_valid   = grant_1_reg;
            assign a_grant_encoded = 1'b0;
        end

        // Coupled AW+W completion tracker for granted slave
        reg aw_done_reg;
        reg w_done_reg;
        reg fifo_pushed_reg;

        wire s_axil_awready_mux;
        wire s_axil_wready_mux;

        wire [ADDR_WIDTH-1:0] s_axil_awaddr_mux  = int_s_axil_awaddr[a_grant_encoded*ADDR_WIDTH +: ADDR_WIDTH];
        wire [2:0]            s_axil_awprot_mux  = int_s_axil_awprot[a_grant_encoded*3 +: 3];
        wire                  s_axil_awvalid_mux = a_grant_valid && !aw_done_reg && int_axil_awvalid[a_grant_encoded*M_COUNT+n];

        wire [DATA_WIDTH-1:0] s_axil_wdata_mux   = int_s_axil_wdata[a_grant_encoded*DATA_WIDTH +: DATA_WIDTH];
        wire [STRB_WIDTH-1:0] s_axil_wstrb_mux   = int_s_axil_wstrb[a_grant_encoded*STRB_WIDTH +: STRB_WIDTH];
        wire                  s_axil_wvalid_mux  = a_grant_valid && !w_done_reg  && int_axil_wvalid[a_grant_encoded*M_COUNT+n];

        wire aw_fire = s_axil_awvalid_mux && s_axil_awready_mux;
        wire w_fire  = s_axil_wvalid_mux  && s_axil_wready_mux;
        wire both_done_now = (aw_done_reg || aw_fire) && (w_done_reg || w_fire);

        assign int_axil_awready[n*S_COUNT +: S_COUNT] = aw_fire ? ({{(S_COUNT-1){1'b0}}, 1'b1} << a_grant_encoded) : {S_COUNT{1'b0}};
        assign int_axil_wready[n*S_COUNT +: S_COUNT]  = w_fire  ? ({{(S_COUNT-1){1'b0}}, 1'b1} << a_grant_encoded) : {S_COUNT{1'b0}};

        for (m = 0; m < S_COUNT; m = m + 1) begin : gen_req
            // Arbitrate only when BOTH AW and W are ready at slave interface m
            assign a_request[m] = int_axil_awvalid[m*M_COUNT+n] && int_axil_wvalid[m*M_COUNT+n]
                                  && !a_grant[m] && !fifo_half_full_reg;
            assign a_acknowledge[m] = a_grant[m] && both_done_now;
        end

        assign fifo_wr_select = a_grant_encoded;
        assign fifo_wr_en     = a_grant_valid && !fifo_pushed_reg && (aw_fire || w_fire);

        always @(posedge clk) begin
            if (rst) begin
                aw_done_reg     <= 1'b0;
                w_done_reg      <= 1'b0;
                fifo_pushed_reg <= 1'b0;
            end else if (!a_grant_valid || both_done_now) begin
                aw_done_reg     <= 1'b0;
                w_done_reg      <= 1'b0;
                fifo_pushed_reg <= 1'b0;
            end else begin
                if (aw_fire) aw_done_reg <= 1'b1;
                if (w_fire)  w_done_reg  <= 1'b1;
                if (aw_fire || w_fire) fifo_pushed_reg <= 1'b1;
            end
        end

        wire [CL_S_COUNT-1:0] b_select = (S_COUNT > 1 && !fifo_empty) ? fifo_select[fifo_rd_ptr_reg[FIFO_ADDR_WIDTH-1:0]] : {CL_S_COUNT{1'b0}};

        assign int_axil_bvalid[n*S_COUNT +: S_COUNT] = (!fifo_empty && int_m_axil_bvalid[n])
                                                       ? ({{(S_COUNT-1){1'b0}}, 1'b1} << b_select)
                                                       : {S_COUNT{1'b0}};
        assign int_m_axil_bready[n] = !fifo_empty && int_axil_bready[b_select*M_COUNT+n];
        assign fifo_rd_en = !fifo_empty && int_m_axil_bvalid[n] && int_m_axil_bready[n];

        axil_register_wr #(
            .DATA_WIDTH(DATA_WIDTH),
            .ADDR_WIDTH(ADDR_WIDTH),
            .STRB_WIDTH(STRB_WIDTH),
            .AW_REG_TYPE(M_AW_REG_TYPE[n*2 +: 2]),
            .W_REG_TYPE(M_W_REG_TYPE[n*2 +: 2]),
            .B_REG_TYPE(M_B_REG_TYPE[n*2 +: 2])
        )
        reg_inst (
            .clk(clk),
            .rst(rst),
            .s_axil_awaddr(s_axil_awaddr_mux),
            .s_axil_awprot(s_axil_awprot_mux),
            .s_axil_awvalid(s_axil_awvalid_mux),
            .s_axil_awready(s_axil_awready_mux),
            .s_axil_wdata(s_axil_wdata_mux),
            .s_axil_wstrb(s_axil_wstrb_mux),
            .s_axil_wvalid(s_axil_wvalid_mux),
            .s_axil_wready(s_axil_wready_mux),
            .s_axil_bresp(int_m_axil_bresp[n*2 +: 2]),
            .s_axil_bvalid(int_m_axil_bvalid[n]),
            .s_axil_bready(int_m_axil_bready[n]),
            .m_axil_awaddr(m_axil_awaddr[n*ADDR_WIDTH +: ADDR_WIDTH]),
            .m_axil_awprot(m_axil_awprot[n*3 +: 3]),
            .m_axil_awvalid(m_axil_awvalid[n]),
            .m_axil_awready(m_axil_awready[n]),
            .m_axil_wdata(m_axil_wdata[n*DATA_WIDTH +: DATA_WIDTH]),
            .m_axil_wstrb(m_axil_wstrb[n*STRB_WIDTH +: STRB_WIDTH]),
            .m_axil_wvalid(m_axil_wvalid[n]),
            .m_axil_wready(m_axil_wready[n]),
            .m_axil_bresp(m_axil_bresp[n*2 +: 2]),
            .m_axil_bvalid(m_axil_bvalid[n]),
            .m_axil_bready(m_axil_bready[n])
        );
    end // m_ifaces

endgenerate

endmodule

`resetall
