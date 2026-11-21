// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module axi_llc_hit_miss #(
  parameter axi_llc_pkg::llc_cfg_t     Cfg       = axi_llc_pkg::llc_cfg_t'{default: '0},
  parameter axi_llc_pkg::llc_axi_cfg_t AxiCfg    = axi_llc_pkg::llc_axi_cfg_t'{default: '0},
  parameter type                       desc_t    = logic,
  parameter type                       lock_t    = logic,
  parameter type                       cnt_t     = logic,
  parameter type                       way_ind_t = logic,
  parameter bit                        PrintSramCfg = 0,
  parameter int unsigned               AxiIdLookupBits = 32'd0
) (
  input  logic     clk_i,
  input  logic     rst_ni,
  input  logic     test_i,
  input  desc_t    desc_i,
  input  logic     valid_i,
  output logic     ready_o,
  output desc_t    desc_o,
  output logic     miss_valid_o,
  input  logic     miss_ready_i,
  output logic     hit_valid_o,
  input  logic     hit_ready_i,
  input  way_ind_t spm_lock_i,
  input  way_ind_t flushed_i,
  input  lock_t    w_unlock_i,
  input  logic     w_unlock_req_i,
  output logic     w_unlock_gnt_o,
  input  lock_t    r_unlock_i,
  input  logic     r_unlock_req_i,
  output logic     r_unlock_gnt_o,
  input  cnt_t     cnt_down_i,
  output way_ind_t bist_res_o,
  output logic     bist_valid_o
);
  `include "common_cells/registers.svh"
  localparam int unsigned IndexBase = Cfg.ByteOffsetLength + Cfg.BlockOffsetLength;
  localparam int unsigned TagBase   = Cfg.ByteOffsetLength + Cfg.BlockOffsetLength +
                                      Cfg.IndexLength;
  typedef logic [Cfg.IndexLength-1:0] index_t;
  typedef logic [Cfg.TagLength-1:0]   tag_t;

  typedef struct packed {
    axi_llc_pkg::tag_mode_e mode;
    way_ind_t               indicator;
    index_t                 index;
    tag_t                   tag;
    logic                   dirty;
  } store_req_t;

  typedef struct packed {
    way_ind_t indicator;
    logic     hit;
    logic     evict;
    tag_t     evict_tag;
  } store_res_t;

  store_req_t store_req;
  logic       store_req_valid;
  logic       store_req_ready;

  store_res_t store_res;
  logic       store_res_valid;
  logic       store_res_ready;

  lock_t lock;
  logic  lock_req, locked;
  cnt_t  cnt_up;
  logic  cnt_stall;
  logic  to_miss;

  logic  busy_d,        busy_q,        load_busy;
  logic  init_d,        init_q,        load_init;
  desc_t desc_d,        desc_q;
  logic  load_desc;
  logic  no_way_err_d,  no_way_err_q;

  way_ind_t avail_cache_ways;
  assign avail_cache_ways = ~(flushed_i | spm_lock_i);

  always_comb begin
    init_d          = init_q;
    load_init       = 1'b0;
    busy_d          = busy_q;
    load_busy       = 1'b0;
    desc_d          = desc_q;
    no_way_err_d    = no_way_err_q;
    desc_o          = desc_q;
    load_desc       = 1'b0;
    ready_o         = 1'b0;
    miss_valid_o    = 1'b0;
    hit_valid_o     = 1'b0;
    store_req       = store_req_t'{mode: axi_llc_pkg::Bist, default: '0};
    store_req_valid = 1'b0;
    store_res_ready = 1'b0;

    if (init_q) begin
      if (busy_q) begin
        if (desc_q.spm || no_way_err_q) begin
          if (no_way_err_q) begin
            desc_o.way_ind = way_ind_t'(1);
            desc_o.x_resp  = axi_pkg::RESP_SLVERR;
            desc_o.evict   = 1'b0;
            desc_o.refill  = 1'b0;
          end else if (|(desc_q.way_ind & (~spm_lock_i))) begin
            desc_o.x_resp  = axi_pkg::RESP_SLVERR;
          end

          if (!(locked | cnt_stall)) begin
            if (!to_miss) begin
              hit_valid_o = 1'b1;
              if (hit_ready_i) begin
                busy_d    = 1'b0;
                load_busy = 1'b1;
              end
            end else begin
              miss_valid_o = 1'b1;
              if (miss_ready_i) begin
                busy_d    = 1'b0;
                load_busy = 1'b1;
              end
            end
          end
        end else begin
          if (store_res_valid) begin
            if (desc_q.flush) begin
              desc_o.evict     = store_res.evict;
              desc_o.evict_tag = store_res.evict_tag;
              if (!locked) begin
                miss_valid_o = 1'b1;
                if (miss_ready_i) begin
                  store_res_ready = 1'b1;
                  busy_d          = 1'b0;
                  load_busy       = 1'b1;
                end
              end
            end else begin
              desc_o.way_ind   = store_res.indicator;
              desc_o.evict     = store_res.evict;
              desc_o.evict_tag = store_res.evict_tag;
              desc_o.refill    = store_res.hit ? 1'b0 : 1'b1;
              if (!(locked || cnt_stall)) begin
                hit_valid_o  = ~to_miss &  store_res.hit;
                miss_valid_o =  to_miss | ~store_res.hit;
                if ((hit_valid_o && hit_ready_i) || (miss_valid_o && miss_ready_i)) begin
                  store_res_ready = 1'b1;
                  if (valid_i) begin
                    if (desc_i.spm) begin
                      ready_o      = 1'b1;
                      desc_d       = desc_i;
                      no_way_err_d = 1'b0;
                      load_desc    = 1'b1;
                    end else if (!desc_i.flush && (avail_cache_ways == '0)) begin
                      ready_o      = 1'b1;
                      desc_d       = desc_i;
                      no_way_err_d = 1'b1;
                      load_desc    = 1'b1;
                    end else begin
                      store_req = store_req_t'{
                        mode:      desc_i.flush ? axi_llc_pkg::Flush : axi_llc_pkg::Lookup,
                        indicator: desc_i.flush ? desc_i.way_ind     : avail_cache_ways,
                        index:     desc_i.a_x_addr[IndexBase+:Cfg.IndexLength],
                        tag:       desc_i.flush ? tag_t'(0)          : desc_i.a_x_addr[TagBase+:Cfg.TagLength],
                        dirty:     desc_i.rw,
                        default:   '0
                      };
                      store_req_valid = 1'b1;
                      if (store_req_ready) begin
                        ready_o      = 1'b1;
                        desc_d       = desc_i;
                        no_way_err_d = 1'b0;
                        load_desc    = 1'b1;
                      end else begin
                        busy_d    = 1'b0;
                        load_busy = 1'b1;
                      end
                    end
                  end else begin
                    busy_d    = 1'b0;
                    load_busy = 1'b1;
                  end
                end
              end
            end
          end
        end
      end else begin
        if (valid_i) begin
          if (desc_i.spm) begin
            ready_o      = 1'b1;
            busy_d       = 1'b1;
            load_busy    = 1'b1;
            desc_d       = desc_i;
            no_way_err_d = 1'b0;
            load_desc    = 1'b1;
          end else if (!desc_i.flush && (avail_cache_ways == '0)) begin
            ready_o      = 1'b1;
            busy_d       = 1'b1;
            load_busy    = 1'b1;
            desc_d       = desc_i;
            no_way_err_d = 1'b1;
            load_desc    = 1'b1;
          end else begin
            store_req = store_req_t'{
              mode:      desc_i.flush ? axi_llc_pkg::Flush : axi_llc_pkg::Lookup,
              indicator: desc_i.flush ? desc_i.way_ind     : avail_cache_ways,
              index:     desc_i.a_x_addr[IndexBase+:Cfg.IndexLength],
              tag:       desc_i.flush ? tag_t'(0)          : desc_i.a_x_addr[TagBase+:Cfg.TagLength],
              dirty:     desc_i.rw,
              default:   '0
            };
            store_req_valid = 1'b1;
            if (store_req_ready) begin
              ready_o      = 1'b1;
              busy_d       = 1'b1;
              load_busy    = 1'b1;
              desc_d       = desc_i;
              no_way_err_d = 1'b0;
              load_desc    = 1'b1;
            end
          end
        end
      end
    end else begin
      store_req = store_req_t'{
        mode:      axi_llc_pkg::Bist,
        indicator: {Cfg.SetAssociativity{1'b1}},
        default:   '0
      };
      store_req_valid = 1'b1;
      if (store_req_ready) begin
        init_d    = 1'b1;
        load_init = 1'b1;
      end
    end
  end

  axi_llc_tag_store #(
    .Cfg          ( Cfg                      ),
    .way_ind_t    ( way_ind_t                ),
    .store_req_t  ( store_req_t              ),
    .store_res_t  ( store_res_t              ),
    .PrintSramCfg ( PrintSramCfg             )
  ) i_tag_store (
    .clk_i,
    .rst_ni,
    .test_i,
    .spm_lock_i   ( spm_lock_i | flushed_i   ),
    .flushed_i    ( flushed_i                ),
    .req_i        ( store_req                ),
    .valid_i      ( store_req_valid          ),
    .ready_o      ( store_req_ready          ),
    .res_o        ( store_res                ),
    .valid_o      ( store_res_valid          ),
    .ready_i      ( store_res_ready          ),
    .bist_res_o   ( bist_res_o               ),
    .bist_valid_o ( bist_valid_o             )
  );

  assign cnt_up.id    = desc_o.a_x_id;
  assign cnt_up.rw    = desc_o.rw;
  assign cnt_up.valid = ~desc_o.flush & miss_valid_o & miss_ready_i;

  axi_llc_miss_counters #(
    .Cfg             ( Cfg             ),
    .AxiIdLookupBits ( AxiIdLookupBits ),
    .cnt_t           ( cnt_t           )
  ) i_miss_counters (
    .clk_i      (      clk_i ),
    .rst_ni     (     rst_ni ),
    .cnt_up_i   (     cnt_up ),
    .cnt_down_i ( cnt_down_i ),
    .to_miss_o  (    to_miss ),
    .stall_o    (  cnt_stall )
  );

  assign lock = '{
    index:   desc_o.a_x_addr[(Cfg.ByteOffsetLength + Cfg.BlockOffsetLength)+:Cfg.IndexLength],
    way_ind: desc_o.way_ind
  };
  assign lock_req = ~desc_o.flush & ((miss_valid_o & miss_ready_i) | (hit_valid_o & hit_ready_i));

  axi_llc_lock_box_bloom #(
    .Cfg       ( Cfg    ),
    .lock_t    ( lock_t )
  ) i_lock_box_bloom (
    .clk_i          ( clk_i      ),
    .rst_ni         ( rst_ni     ),
    .test_i         ( test_i     ),
    .lock_i         ( lock       ),
    .lock_req_i     ( lock_req   ),
    .locked_o       ( locked     ),
    .w_unlock_i,
    .w_unlock_req_i,
    .w_unlock_gnt_o,
    .r_unlock_i,
    .r_unlock_req_i,
    .r_unlock_gnt_o
  );

  `FFLARN(busy_q,       busy_d,       load_busy, '0, clk_i, rst_ni)
  `FFLARN(init_q,       init_d,       load_init, '0, clk_i, rst_ni)
  `FFLARN(desc_q,       desc_d,       load_desc, '0, clk_i, rst_ni)
  `FFLARN(no_way_err_q, no_way_err_d, load_desc, '0, clk_i, rst_ni)
endmodule
