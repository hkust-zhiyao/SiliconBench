// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "axi/typedef.svh"
`include "idma/typedef.svh"

module idma_nd_legalizer_top #(
    parameter int unsigned DataWidth       = 32'd32,
    parameter int unsigned AddrWidth       = 32'd24,
    parameter int unsigned UserWidth       = 32'd1,
    parameter int unsigned AxiIdWidth      = 32'd2,
    parameter int unsigned TFLenWidth      = 32'd24,
    parameter int unsigned NumDim          = 32'd3,
    parameter int unsigned RepWidth        = 32'd12,
    parameter int unsigned StrideWidth     = 32'd24,
    parameter bit          CombinedShifter = 1'b0,
    parameter int unsigned StrbWidth       = DataWidth / 8,
    parameter int unsigned OffsetWidth     = $clog2(StrbWidth),
    parameter type addr_t                  = logic [AddrWidth-1:0],
    parameter type data_t                  = logic [DataWidth-1:0],
    parameter type strb_t                  = logic [StrbWidth-1:0],
    parameter type user_t                  = logic [UserWidth-1:0],
    parameter type id_t                    = logic [AxiIdWidth-1:0],
    parameter type tf_len_t                = logic [TFLenWidth-1:0],
    parameter type offset_t                = logic [OffsetWidth-1:0],
    parameter type reps_t                  = logic [RepWidth-1:0],
    parameter type strides_t               = logic [StrideWidth-1:0]
) (
    input  logic                        clk_i,
    input  logic                        rst_ni,

    input  logic                        req_valid_i,
    output logic                        req_ready_o,
    input  tf_len_t                     req_length_i,
    input  addr_t                       req_src_addr_i,
    input  addr_t                       req_dst_addr_i,
    input  addr_t                       req_scale_addr_i,
    input  id_t                         req_axi_id_i,
    input  logic                        req_decouple_aw_i,
    input  logic                        req_decouple_rw_i,
    input  logic [2:0]                  req_src_max_llen_i,
    input  logic [2:0]                  req_dst_max_llen_i,
    input  logic                        req_src_reduce_len_i,
    input  logic                        req_dst_reduce_len_i,
    input  reps_t    [NumDim-2:0]       req_reps_i,
    input  strides_t [NumDim-2:0]       req_src_strides_i,
    input  strides_t [NumDim-2:0]       req_dst_strides_i,
    input  strides_t [NumDim-2:0]       req_scale_strides_i,

    output logic                        rsp_valid_o,
    input  logic                        rsp_ready_i,
    output axi_pkg::resp_t              rsp_cause_o,
    output idma_pkg::err_type_t         rsp_err_type_o,
    output addr_t                       rsp_burst_addr_o,
    output logic                        rsp_error_o,
    output logic                        rsp_last_o,

    input  logic                        burst_rsp_valid_i,
    output logic                        burst_rsp_ready_o,
    input  axi_pkg::resp_t              burst_rsp_cause_i,
    input  idma_pkg::err_type_t         burst_rsp_err_type_i,
    input  addr_t                       burst_rsp_burst_addr_i,
    input  logic                        burst_rsp_error_i,
    input  logic                        burst_rsp_last_i,

    output logic                        r_valid_o,
    input  logic                        r_ready_i,
    output addr_t                       r_ar_addr_o,
    output axi_pkg::len_t               r_ar_len_o,
    output axi_pkg::size_t              r_ar_size_o,
    output id_t                         r_ar_id_o,
    output offset_t                     r_dp_offset_o,
    output offset_t                     r_dp_tailer_o,
    output offset_t                     r_dp_shift_o,
    output logic                        r_dp_decouple_aw_o,
    output logic                        r_dp_is_single_o,

    output logic                        w_valid_o,
    input  logic                        w_ready_i,
    output addr_t                       w_aw_addr_o,
    output axi_pkg::len_t               w_aw_len_o,
    output axi_pkg::size_t              w_aw_size_o,
    output id_t                         w_aw_id_o,
    output offset_t                     w_dp_offset_o,
    output offset_t                     w_dp_tailer_o,
    output offset_t                     w_dp_shift_o,
    output axi_pkg::len_t               w_dp_num_beats_o,
    output logic                        w_dp_is_single_o,
    output logic                        w_last_o,
    output logic                        w_super_last_o,
    output logic                        w_decouple_aw_o,

    input  logic                        flush_i,
    input  logic                        kill_i,
    output logic                        nd_busy_o,
    output logic                        r_busy_o,
    output logic                        w_busy_o,
    output addr_t                       burst_scale_addr_o
);

    `AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, addr_t, id_t, user_t)
    `AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, addr_t, id_t, user_t)

    `IDMA_TYPEDEF_OPTIONS_T(options_t, id_t)
    `IDMA_TYPEDEF_REQ_T(idma_req_t, tf_len_t, addr_t, options_t, user_t)
    `IDMA_TYPEDEF_ERR_PAYLOAD_T(err_payload_t, addr_t)
    `IDMA_TYPEDEF_RSP_T(idma_rsp_t, err_payload_t)
    `IDMA_TYPEDEF_D_REQ_T(idma_d_req_t, reps_t, strides_t)
    `IDMA_TYPEDEF_ND_REQ_T(idma_nd_req_t, idma_req_t, idma_d_req_t)

    typedef struct packed {
        axi_ar_chan_t ar_chan;
    } axi_read_meta_channel_t;

    typedef struct packed {
        axi_read_meta_channel_t axi;
    } read_meta_channel_t;

    typedef struct packed {
        axi_aw_chan_t aw_chan;
    } axi_write_meta_channel_t;

    typedef struct packed {
        axi_write_meta_channel_t axi;
    } write_meta_channel_t;

    typedef struct packed {
        idma_pkg::protocol_e  src_protocol;
        idma_pkg::multihead_t src_head;
        offset_t              offset;
        offset_t              tailer;
        offset_t              shift;
        logic                 decouple_aw;
        logic                 is_single;
    } r_dp_req_t;

    typedef struct packed {
        idma_pkg::protocol_e        dst_protocol;
        idma_pkg::multihead_t       dst_head;
        offset_t                    offset;
        offset_t                    tailer;
        offset_t                    shift;
        axi_pkg::len_t              num_beats;
        logic                       is_single;
        idma_pkg::compute_options_t compute;
    } w_dp_req_t;

    typedef struct packed {
        r_dp_req_t          r_dp_req;
        read_meta_channel_t ar_req;
    } idma_r_req_t;

    typedef struct packed {
        w_dp_req_t           w_dp_req;
        write_meta_channel_t aw_req;
        logic                last;
        logic                super_last;
        logic                decouple_aw;
    } idma_w_req_t;

    typedef struct packed {
        idma_pkg::protocol_e        src_protocol;
        idma_pkg::protocol_e        dst_protocol;
        idma_pkg::multihead_t       src_head;
        idma_pkg::multihead_t       dst_head;
        offset_t                    read_shift;
        offset_t                    write_shift;
        logic                       decouple_rw;
        logic                       decouple_aw;
        logic [2:0]                 src_max_llen;
        logic [2:0]                 dst_max_llen;
        logic                       src_reduce_len;
        logic                       dst_reduce_len;
        id_t                        axi_id;
        idma_pkg::axi_options_t     src_axi_opt;
        idma_pkg::axi_options_t     dst_axi_opt;
        logic                       super_last;
        idma_pkg::compute_options_t compute;
    } idma_mut_tf_opt_t;

    typedef struct packed {
        tf_len_t length;
        addr_t   addr;
        logic    valid;
        addr_t   base_addr;
        user_t   user;
    } idma_mut_tf_t;

    localparam logic [NumDim-1:0][31:0] RepWidths = '{default: RepWidth};

    idma_nd_req_t nd_req;
    idma_rsp_t    nd_rsp, burst_rsp;
    idma_req_t    burst_req;
    logic         burst_req_valid, burst_req_ready;
    idma_r_req_t  r_req;
    idma_w_req_t  w_req;

    always_comb begin
        nd_req                            = '0;
        nd_req.burst_req.length           = req_length_i;
        nd_req.burst_req.src_addr         = req_src_addr_i;
        nd_req.burst_req.dst_addr         = req_dst_addr_i;
        nd_req.burst_req.scale_addr       = req_scale_addr_i;
        nd_req.burst_req.opt.axi_id       = req_axi_id_i;
        nd_req.burst_req.opt.src_protocol = idma_pkg::AXI;
        nd_req.burst_req.opt.dst_protocol = idma_pkg::AXI;
        nd_req.burst_req.opt.src.burst    = axi_pkg::BURST_INCR;
        nd_req.burst_req.opt.dst.burst    = axi_pkg::BURST_INCR;
        nd_req.burst_req.opt.beo.decouple_aw    = req_decouple_aw_i;
        nd_req.burst_req.opt.beo.decouple_rw    = req_decouple_rw_i;
        nd_req.burst_req.opt.beo.src_max_llen   = req_src_max_llen_i;
        nd_req.burst_req.opt.beo.dst_max_llen   = req_dst_max_llen_i;
        nd_req.burst_req.opt.beo.src_reduce_len = req_src_reduce_len_i;
        nd_req.burst_req.opt.beo.dst_reduce_len = req_dst_reduce_len_i;
        for (int d = 0; d < NumDim - 1; d++) begin
            nd_req.d_req[d].reps          = req_reps_i[d];
            nd_req.d_req[d].src_strides   = req_src_strides_i[d];
            nd_req.d_req[d].dst_strides   = req_dst_strides_i[d];
            nd_req.d_req[d].scale_strides = req_scale_strides_i[d];
        end
    end

    assign burst_rsp.last           = burst_rsp_last_i;
    assign burst_rsp.error          = burst_rsp_error_i;
    assign burst_rsp.pld.cause      = burst_rsp_cause_i;
    assign burst_rsp.pld.err_type   = burst_rsp_err_type_i;
    assign burst_rsp.pld.burst_addr = burst_rsp_burst_addr_i;

    idma_nd_midend #(
        .NumDim       ( NumDim        ),
        .addr_t       ( addr_t        ),
        .idma_req_t   ( idma_req_t    ),
        .idma_rsp_t   ( idma_rsp_t    ),
        .idma_nd_req_t( idma_nd_req_t ),
        .RepWidths    ( RepWidths     )
    ) i_idma_nd_midend (
        .clk_i            ( clk_i             ),
        .rst_ni           ( rst_ni            ),
        .nd_req_i         ( nd_req            ),
        .nd_req_valid_i   ( req_valid_i       ),
        .nd_req_ready_o   ( req_ready_o       ),
        .nd_rsp_o         ( nd_rsp            ),
        .nd_rsp_valid_o   ( rsp_valid_o       ),
        .nd_rsp_ready_i   ( rsp_ready_i       ),
        .burst_req_o      ( burst_req         ),
        .burst_req_valid_o( burst_req_valid   ),
        .burst_req_ready_i( burst_req_ready   ),
        .burst_rsp_i      ( burst_rsp         ),
        .burst_rsp_valid_i( burst_rsp_valid_i ),
        .burst_rsp_ready_o( burst_rsp_ready_o ),
        .busy_o           ( nd_busy_o         )
    );

    assign burst_scale_addr_o = burst_req.scale_addr;

    idma_legalizer #(
        .CombinedShifter  ( CombinedShifter   ),
        .DataWidth        ( DataWidth         ),
        .AddrWidth        ( AddrWidth         ),
        .BurstLen         ( 4'd8              ),
        .idma_req_t       ( idma_req_t        ),
        .idma_r_req_t     ( idma_r_req_t      ),
        .idma_w_req_t     ( idma_w_req_t      ),
        .idma_mut_tf_t    ( idma_mut_tf_t     ),
        .idma_mut_tf_opt_t( idma_mut_tf_opt_t )
    ) i_idma_legalizer (
        .clk_i    ( clk_i           ),
        .rst_ni   ( rst_ni          ),
        .req_i    ( burst_req       ),
        .valid_i  ( burst_req_valid ),
        .ready_o  ( burst_req_ready ),
        .r_req_o  ( r_req           ),
        .r_valid_o( r_valid_o       ),
        .r_ready_i( r_ready_i       ),
        .w_req_o  ( w_req           ),
        .w_valid_o( w_valid_o       ),
        .w_ready_i( w_ready_i       ),
        .flush_i  ( flush_i         ),
        .kill_i   ( kill_i          ),
        .r_busy_o ( r_busy_o        ),
        .w_busy_o ( w_busy_o        )
    );

    assign rsp_cause_o      = nd_rsp.pld.cause;
    assign rsp_err_type_o   = nd_rsp.pld.err_type;
    assign rsp_burst_addr_o = nd_rsp.pld.burst_addr;
    assign rsp_error_o      = nd_rsp.error;
    assign rsp_last_o       = nd_rsp.last;

    assign r_ar_addr_o        = r_req.ar_req.axi.ar_chan.addr;
    assign r_ar_len_o         = r_req.ar_req.axi.ar_chan.len;
    assign r_ar_size_o        = r_req.ar_req.axi.ar_chan.size;
    assign r_ar_id_o          = r_req.ar_req.axi.ar_chan.id;
    assign r_dp_offset_o      = r_req.r_dp_req.offset;
    assign r_dp_tailer_o      = r_req.r_dp_req.tailer;
    assign r_dp_shift_o       = r_req.r_dp_req.shift;
    assign r_dp_decouple_aw_o = r_req.r_dp_req.decouple_aw;
    assign r_dp_is_single_o   = r_req.r_dp_req.is_single;

    assign w_aw_addr_o      = w_req.aw_req.axi.aw_chan.addr;
    assign w_aw_len_o       = w_req.aw_req.axi.aw_chan.len;
    assign w_aw_size_o      = w_req.aw_req.axi.aw_chan.size;
    assign w_aw_id_o        = w_req.aw_req.axi.aw_chan.id;
    assign w_dp_offset_o    = w_req.w_dp_req.offset;
    assign w_dp_tailer_o    = w_req.w_dp_req.tailer;
    assign w_dp_shift_o     = w_req.w_dp_req.shift;
    assign w_dp_num_beats_o = w_req.w_dp_req.num_beats;
    assign w_dp_is_single_o = w_req.w_dp_req.is_single;
    assign w_last_o         = w_req.last;
    assign w_super_last_o   = w_req.super_last;
    assign w_decouple_aw_o  = w_req.decouple_aw;

endmodule
