// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Thomas Benz <tbenz@iis.ee.ethz.ch>
// - Tobias Senti <tsenti@ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"
`include "idma/guard.svh"

module idma_legalizer #(
    parameter bit          CombinedShifter = 1'b0,
    parameter int unsigned DataWidth       = 32'd32,
    parameter int unsigned AddrWidth       = 32'd24,
    parameter int unsigned BurstLen        = 4'd8,
    parameter type idma_req_t              = logic,
    parameter type idma_r_req_t            = logic,
    parameter type idma_w_req_t            = logic,
    parameter type idma_mut_tf_t           = logic,
    parameter type idma_mut_tf_opt_t       = logic
)(
    input  logic clk_i,
    input  logic rst_ni,

    input  idma_req_t req_i,
    input  logic valid_i,
    output logic ready_o,

    output idma_r_req_t r_req_o,
    output logic r_valid_o,
    input  logic r_ready_i,

    output idma_w_req_t w_req_o,
    output logic w_valid_o,
    input  logic w_ready_i,

    input  logic flush_i,
    input  logic kill_i,

    output logic r_busy_o,
    output logic w_busy_o
);
    localparam int unsigned StrbWidth     = DataWidth / 8;
    localparam int unsigned OffsetWidth   = $clog2(StrbWidth);
    localparam int unsigned PageSize      = (256 * StrbWidth > 4096) ? 4096 : (256 * StrbWidth);
    localparam int unsigned PageAddrWidth = $clog2(PageSize);

    typedef logic [  OffsetWidth-1:0] offset_t;
    typedef logic [    AddrWidth-1:0] addr_t;
    typedef logic [PageAddrWidth-1:0] page_addr_t;
    typedef logic [  PageAddrWidth:0] page_len_t;

    idma_mut_tf_t     r_tf_d,   r_tf_q;
    idma_mut_tf_t     w_tf_d,   w_tf_q;
    idma_mut_tf_opt_t opt_tf_d, opt_tf_q;
    idma_mut_tf_opt_t opt_w_q;

    logic r_tf_ena;
    logic w_tf_ena;

    page_len_t r_page_num_bytes_to_pb;
    page_len_t r_num_bytes_to_pb;
    page_len_t w_page_num_bytes_to_pb;
    page_len_t w_num_bytes_to_pb;
    page_len_t c_num_bytes_to_pb;

    page_len_t r_num_bytes_possible;
    page_len_t r_num_bytes;
    offset_t   r_addr_offset;
    logic      r_done;

    page_len_t w_num_bytes_possible;
    page_len_t w_num_bytes;
    offset_t   w_addr_offset;
    logic      w_done;

    idma_legalizer_page_splitter #(
        .BurstLen      ( BurstLen      ),
        .OffsetWidth   ( OffsetWidth   ),
        .PageAddrWidth ( PageAddrWidth ),
        .addr_t        ( addr_t        ),
        .page_len_t    ( page_len_t    ),
        .page_addr_t   ( page_addr_t   )
    ) i_read_page_splitter (
        .not_bursting_i    ( 1'b0 ),
        .reduce_len_i      ( opt_tf_q.src_reduce_len ),
        .max_llen_i        ( opt_tf_q.src_max_llen   ),
        .addr_i            ( r_tf_q.addr             ),
        .num_bytes_to_pb_o ( r_page_num_bytes_to_pb  )
    );
    assign r_num_bytes_to_pb = r_page_num_bytes_to_pb;

    idma_legalizer_page_splitter #(
        .BurstLen      ( BurstLen      ),
        .OffsetWidth   ( OffsetWidth   ),
        .PageAddrWidth ( PageAddrWidth ),
        .addr_t        ( addr_t        ),
        .page_len_t    ( page_len_t    ),
        .page_addr_t   ( page_addr_t   )
    ) i_write_page_splitter (
        .not_bursting_i    ( 1'b0 ),
        .reduce_len_i      ( opt_w_q.dst_reduce_len ),
        .max_llen_i        ( opt_w_q.dst_max_llen   ),
        .addr_i            ( w_tf_q.addr             ),
        .num_bytes_to_pb_o ( w_page_num_bytes_to_pb  )
    );
    assign w_num_bytes_to_pb = w_page_num_bytes_to_pb;

    assign c_num_bytes_to_pb = (r_num_bytes_to_pb > w_num_bytes_to_pb) ?
                                r_num_bytes_to_pb : w_num_bytes_to_pb;

    always_comb begin : proc_num_bytes_possible
        r_num_bytes_possible = c_num_bytes_to_pb;
        w_num_bytes_possible = c_num_bytes_to_pb;
        if (opt_tf_q.decouple_rw) begin
            r_num_bytes_possible = r_num_bytes_to_pb;
            w_num_bytes_possible = w_num_bytes_to_pb;
        end
    end

    assign r_addr_offset = r_tf_q.addr[OffsetWidth-1:0];
    assign w_addr_offset = w_tf_q.addr[OffsetWidth-1:0];

    typedef struct packed {
        idma_mut_tf_t     r_tf;
        idma_mut_tf_t     w_tf;
        idma_mut_tf_opt_t opt;
    } load_t;

    function automatic load_t load(idma_req_t req);
        load_t l;
        l = '0;
        l.r_tf = '{
            length: req.length,
            addr:   req.src_addr,
            valid:   1'b1,
            base_addr: req.src_addr,
            default: '0
        };
        l.w_tf = '{
            length: req.length,
            addr:   req.dst_addr,
            valid:   1'b1,
            base_addr: req.dst_addr,
            user: req.user,
            default: '0
        };
        l.opt = '{
            src_protocol:   req.opt.src_protocol,
            dst_protocol:   req.opt.dst_protocol,
            src_head:       req.opt.src_head,
            dst_head:       req.opt.dst_head,
            read_shift:     '0,
            write_shift:    '0,
            decouple_rw:    req.opt.beo.decouple_rw,
            decouple_aw:    req.opt.beo.decouple_aw,
            src_max_llen:   req.opt.beo.src_max_llen,
            dst_max_llen:   req.opt.beo.dst_max_llen,
            src_reduce_len: req.opt.beo.src_reduce_len,
            dst_reduce_len: req.opt.beo.dst_reduce_len,
            axi_id:         req.opt.axi_id,
            src_axi_opt:    req.opt.src,
            dst_axi_opt:    req.opt.dst,
            super_last:     req.opt.last,
            compute:        req.opt.compute
        };
        if (CombinedShifter) begin
            l.opt.read_shift  = req.src_addr[OffsetWidth-1:0] -
                                req.dst_addr[OffsetWidth-1:0];
            l.opt.write_shift = '0;
        end else begin
            l.opt.read_shift  =   req.src_addr[OffsetWidth-1:0];
            l.opt.write_shift = - req.dst_addr[OffsetWidth-1:0];
        end
        return l;
    endfunction

    load_t ld_in;
    assign ld_in = load(req_i);

    always_comb begin : proc_read_write_transaction
        r_tf_d   = r_tf_q;
        w_tf_d   = w_tf_q;
        opt_tf_d = opt_tf_q;

        r_done = 1'b0;
        w_done = 1'b0;

        if (r_tf_q.length > r_num_bytes_possible) begin
            r_num_bytes   = r_num_bytes_possible;
            r_tf_d.length = r_tf_q.length - r_num_bytes_possible;
            r_tf_d.addr   = r_tf_q.addr + r_num_bytes;
        end else begin
            r_num_bytes  = r_tf_q.length[PageAddrWidth:0];
            r_tf_d.valid = 1'b0;
            r_done       = 1'b1;
        end

        if (w_tf_q.length > w_num_bytes_possible) begin
            w_num_bytes   = w_num_bytes_possible;
            w_tf_d.length = w_tf_q.length - w_num_bytes_possible;
            w_tf_d.addr   = w_tf_q.addr + w_num_bytes;
        end else begin
            w_num_bytes  = w_tf_q.length[PageAddrWidth:0];
            w_tf_d.valid = 1'b0;
            w_done       = 1'b1;
        end

        if (kill_i) begin
            r_tf_d = '0;
            w_tf_d = '0;
            r_done = 1'b1;
            w_done = 1'b1;
        end

        if (ready_o & valid_i) begin
            r_tf_d   = ld_in.r_tf;
            opt_tf_d = ld_in.opt;
            w_tf_d   = ld_in.w_tf;
        end
    end

    always_comb begin
        r_req_o.ar_req.axi.ar_chan = '{
            id:     opt_tf_q.axi_id,
            addr:   { r_tf_q.addr[AddrWidth-1:OffsetWidth], {{OffsetWidth}{1'b0}} },
            len:    ((r_num_bytes + r_addr_offset - 'd1) >> OffsetWidth),
            size:   axi_pkg::size_t'(OffsetWidth),
            burst:  opt_tf_q.src_axi_opt.burst,
            lock:   opt_tf_q.src_axi_opt.lock,
            cache:  opt_tf_q.src_axi_opt.cache,
            prot:   opt_tf_q.src_axi_opt.prot,
            qos:    opt_tf_q.src_axi_opt.qos,
            region: opt_tf_q.src_axi_opt.region,
            user:   '0
        };
    end

    assign r_req_o.r_dp_req = '{
        src_protocol: opt_tf_q.src_protocol,
        src_head:     opt_tf_q.src_head,
        offset:       r_addr_offset,
        tailer:       OffsetWidth'(r_num_bytes + r_addr_offset),
        shift:        opt_tf_q.read_shift,
        decouple_aw:  opt_tf_q.decouple_aw,
        is_single:    r_num_bytes <= StrbWidth
    };

    always_comb begin
        w_req_o.aw_req.axi.aw_chan = '{
            id:     opt_w_q.axi_id,
            addr:   { w_tf_q.addr[AddrWidth-1:OffsetWidth], {{OffsetWidth}{1'b0}} },
            len:    ((w_num_bytes + w_addr_offset - 'd1) >> OffsetWidth),
            size:   axi_pkg::size_t'(OffsetWidth),
            burst:  opt_w_q.dst_axi_opt.burst,
            lock:   opt_w_q.dst_axi_opt.lock,
            cache:  opt_w_q.dst_axi_opt.cache,
            prot:   opt_w_q.dst_axi_opt.prot,
            qos:    opt_w_q.dst_axi_opt.qos,
            region: opt_w_q.dst_axi_opt.region,
            user:   w_tf_q.user,
            atop:   '0
        };
        w_req_o.w_dp_req = '{
            dst_protocol: opt_w_q.dst_protocol,
            dst_head:     opt_w_q.dst_head,
            offset:       w_addr_offset,
            tailer:       OffsetWidth'(w_num_bytes + w_addr_offset),
            shift:        opt_w_q.write_shift,
            num_beats:    w_req_o.aw_req.axi.aw_chan.len,
            is_single:    w_req_o.aw_req.axi.aw_chan.len == '0,
            compute:      opt_w_q.compute
        };
    end

    assign w_req_o.last        = w_done;
    assign w_req_o.super_last  = opt_w_q.super_last;
    assign w_req_o.decouple_aw = opt_w_q.decouple_aw;

    assign r_busy_o = r_tf_q.valid;
    assign w_busy_o = w_tf_q.valid;

    always_comb begin : proc_legalizer_flow_control
        if (opt_tf_q.decouple_rw) begin
            r_tf_ena  = (r_ready_i & !flush_i) | kill_i;
            w_tf_ena  = (w_ready_i & !flush_i) | kill_i;
            r_valid_o = r_tf_q.valid & r_ready_i & !flush_i;
            w_valid_o = w_tf_q.valid & w_ready_i & !flush_i;
        end else begin
            r_tf_ena  = (r_ready_i & !flush_i) | kill_i;
            w_tf_ena  = (r_ready_i & w_ready_i & !flush_i) | kill_i;
            r_valid_o = r_tf_q.valid & w_ready_i & r_ready_i & !flush_i;
            w_valid_o = w_tf_q.valid & r_ready_i & w_ready_i & !flush_i;
        end
    end

    assign ready_o = r_done & w_done & r_ready_i & w_ready_i & !flush_i;
    assign opt_w_q = opt_tf_q;

    `FF (opt_tf_q, opt_tf_d,           '0, clk_i, rst_ni)
    `FFL(r_tf_q,   r_tf_d,   r_tf_ena, '0, clk_i, rst_ni)
    `FFL(w_tf_q,   w_tf_d,   w_tf_ena, '0, clk_i, rst_ni)

endmodule
