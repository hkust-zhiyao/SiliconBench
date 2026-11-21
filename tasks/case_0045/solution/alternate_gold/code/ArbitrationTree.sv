// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51.

`include "parameters.v"

module ArbitrationTree 
#(
    parameter ADDR_WIDTH  = 12,
    parameter ID_WIDTH    = 20,
    parameter N_MASTER    = 16,
    parameter DATA_WIDTH  = 32,
    parameter MAX_COUNT   = 2**N_MASTER-1,
    parameter BE_WIDTH    = DATA_WIDTH/8
) 
(
    input  logic                                 clk,
    input  logic                                 rst_n,
    input  logic                                 TCDM_arb_policy_i,

    // ---------------- REQ_SIDE --------------------------
    input  logic [N_MASTER-1:0]                  data_req_i,
    input  logic [N_MASTER-1:0][ADDR_WIDTH-1:0]  data_add_i,
    input  logic [N_MASTER-1:0]                  data_wen_i,
    input  logic [N_MASTER-1:0][DATA_WIDTH-1:0]  data_wdata_i,
    input  logic [N_MASTER-1:0][BE_WIDTH-1:0]    data_be_i,
    input  logic [N_MASTER-1:0][ID_WIDTH-1:0]    data_ID_i,
  `ifdef GNT_BASED_FC
    output logic [N_MASTER-1:0]                  data_gnt_o,
  `else
    output logic [N_MASTER-1:0]                  data_stall_o,
  `endif
    // Outputs
    output logic                                 data_req_o,
    output logic [ADDR_WIDTH-1:0]                data_add_o,
    output logic                                 data_wen_o,
    output logic [DATA_WIDTH-1:0]                data_wdata_o,
    output logic [BE_WIDTH-1:0]                  data_be_o,
    output logic [ID_WIDTH-1:0]                  data_ID_o,
  `ifdef GNT_BASED_FC
    input  logic                                 data_gnt_i
  `else
    input  logic                                 data_stall_i
  `endif
);

    localparam LOG_MASTER         = $clog2(N_MASTER);
    localparam N_WIRE             =  N_MASTER - 2;

    logic [LOG_MASTER-1:0]        s_RR_FLAG;
    logic [LOG_MASTER-1:0]        s_ID;
    logic [N_MASTER-1:0][LOG_MASTER-1:0]    ID_int;

    logic                         gnt_ok;
  `ifdef GNT_BASED_FC
    assign gnt_ok = data_gnt_i;
  `else
    assign gnt_ok = ~data_stall_i;
  `endif

    // Alternate gold: store one-hot mask of locked requester and compute node priorities explicitly
    logic [N_MASTER-1:0]          held_mask_q, gated_req;
    logic                         is_held;
    assign is_held   = |(held_mask_q & data_req_i);
    assign gated_req = is_held ? (held_mask_q & data_req_i) : data_req_i;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        held_mask_q <= '0;
      end else if (data_req_o && !gnt_ok) begin
        held_mask_q <= (N_MASTER'(1) << s_ID);
      end else begin
        held_mask_q <= '0;
      end
    end

    logic [N_MASTER-2:0] rr_tree_q;
    integer lv, nd;
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        rr_tree_q <= '0;
      end else if (data_req_o && gnt_ok) begin
        for (lv = 0; lv < LOG_MASTER; lv = lv + 1) begin
          for (nd = 0; nd < (1 << lv); nd = nd + 1) begin
            if ((s_ID >> (LOG_MASTER - lv)) == nd) begin
              rr_tree_q[(1 << lv) - 1 + nd] <= ~s_ID[LOG_MASTER - lv - 1];
            end
          end
        end
      end
    end

    genvar j,k;

    generate
      if(N_MASTER == 2)
        begin : INCR
                    FanInPrimitive_Req 
                    #(
                        .ADDR_WIDTH     ( ADDR_WIDTH      ), 
                        .ID_WIDTH       ( ID_WIDTH        ),
                        .DATA_WIDTH     ( DATA_WIDTH      ),
                        .BE_WIDTH       ( BE_WIDTH        ),
                        .N_MASTER       ( N_MASTER        )
                    ) 
                    i_FanInPrimitive_Req
                    (
                        .PRIO_FLAG      ( TCDM_arb_policy_i ? rr_tree_q[0] : s_RR_FLAG[0] ),
                        .data_wdata0_i  ( data_wdata_i[0] ),
                        .data_wdata1_i  ( data_wdata_i[1] ),
                        .data_add0_i    ( data_add_i[0]   ),
                        .data_add1_i    ( data_add_i[1]   ),
                        .data_req0_i    ( gated_req[0]    ),
                        .data_req1_i    ( gated_req[1]    ),
                        .data_wen0_i    ( data_wen_i[0]   ),
                        .data_wen1_i    ( data_wen_i[1]   ),
                        .data_ID0_i     ( data_ID_i[0]    ),
                        .data_ID1_i     ( data_ID_i[1]    ),
                        .ID0_i          ( 1'b0            ),
                        .ID1_i          ( 1'b1            ),
                        .data_be0_i     ( data_be_i[0]    ),
                        .data_be1_i     ( data_be_i[1]    ),
                `ifdef GNT_BASED_FC
                        .data_gnt0_o    ( data_gnt_o[0]   ),
                        .data_gnt1_o    ( data_gnt_o[1]   ),
                `else
                        .data_stall0_o  ( data_stall_o[0] ),
                        .data_stall1_o  ( data_stall_o[1] ),
                `endif
                        .data_wdata_o   ( data_wdata_o    ),
                        .data_add_o     ( data_add_o      ),
                        .data_req_o     ( data_req_o      ),
                        .data_wen_o     ( data_wen_o      ),
                        .data_ID_o      ( data_ID_o       ),
                        .ID_o           ( s_ID            ),
                        .data_be_o      ( data_be_o       ),
                `ifdef GNT_BASED_FC
                        .data_gnt_i     ( data_gnt_i      )
                `else
                        .data_stall_i   ( data_stall_i    )
                `endif
                        );
        end
      else
        begin : BINARY_TREE
            logic [N_WIRE-1:0][DATA_WIDTH-1:0]     data_wdata_LEVEL;
            logic [N_WIRE-1:0][ADDR_WIDTH-1:0]     data_add_LEVEL;
            logic [N_WIRE-1:0]                     data_req_LEVEL;
            logic [N_WIRE-1:0]                     data_wen_LEVEL;
            logic [N_WIRE-1:0][ID_WIDTH-1:0]       data_ID_LEVEL;
            logic [N_WIRE-1:0][LOG_MASTER-1:0]     ID_LEVEL;
            logic [N_WIRE-1:0][BE_WIDTH-1:0]       data_be_LEVEL;
        `ifdef GNT_BASED_FC
            logic [N_WIRE-1:0]                     data_gnt_LEVEL;
        `else
            logic [N_WIRE-1:0]                     data_stall_LEVEL;
        `endif

               for(j=0; j < LOG_MASTER; j++)
                begin : STAGE
                  for(k=0; k<2**j; k=k+1)
                    begin : INCR_VERT

                      if (j == 0 )
                      begin : LAST_NODE
                          FanInPrimitive_Req 
                          #(
                              .ADDR_WIDTH     ( ADDR_WIDTH              ), 
                              .ID_WIDTH       ( ID_WIDTH                ),
                              .DATA_WIDTH     ( DATA_WIDTH              ),
                              .BE_WIDTH       ( BE_WIDTH                ),
                              .N_MASTER       ( N_MASTER                )
                          ) 
                          i_FanInPrimitive_Req
                          (
                              .PRIO_FLAG      ( TCDM_arb_policy_i ? rr_tree_q[(1<<j)-1+k] : s_RR_FLAG[LOG_MASTER-j-1] ),
                              .data_wdata0_i  ( data_wdata_LEVEL[2*k]   ),
                              .data_wdata1_i  ( data_wdata_LEVEL[2*k+1] ),
                              .data_add0_i    ( data_add_LEVEL[2*k]     ),
                              .data_add1_i    ( data_add_LEVEL[2*k+1]   ),
                              .data_req0_i    ( data_req_LEVEL[2*k]     ),
                              .data_req1_i    ( data_req_LEVEL[2*k+1]   ),
                              .data_wen0_i    ( data_wen_LEVEL[2*k]     ),
                              .data_wen1_i    ( data_wen_LEVEL[2*k+1]   ),
                              .data_ID0_i     ( data_ID_LEVEL[2*k]      ),
                              .data_ID1_i     ( data_ID_LEVEL[2*k+1]    ),
                              .ID0_i          ( ID_LEVEL[2*k]           ),
                              .ID1_i          ( ID_LEVEL[2*k+1]         ),
                              .data_be0_i     ( data_be_LEVEL[2*k]      ),
                              .data_be1_i     ( data_be_LEVEL[2*k+1]    ),
                          `ifdef GNT_BASED_FC
                              .data_gnt0_o    ( data_gnt_LEVEL[2*k]     ),
                              .data_gnt1_o    ( data_gnt_LEVEL[2*k+1]   ),
                          `else
                              .data_stall0_o  ( data_stall_LEVEL[2*k]   ),
                              .data_stall1_o  ( data_stall_LEVEL[2*k+1] ),
                          `endif
                              .data_wdata_o   ( data_wdata_o            ),
                              .data_add_o     ( data_add_o              ),
                              .data_req_o     ( data_req_o              ),
                              .data_wen_o     ( data_wen_o              ),
                              .data_ID_o      ( data_ID_o               ),
                              .ID_o           ( s_ID                    ),
                              .data_be_o      ( data_be_o               ),
                          `ifdef GNT_BASED_FC
                              .data_gnt_i     ( data_gnt_i              )
                          `else
                              .data_stall_i   ( data_stall_i            )
                          `endif
                          );
                      end 
                      else if ( j < LOG_MASTER - 1)
                              begin : MIDDLE_NODES
                                  FanInPrimitive_Req 
                                  #(
                                      .ADDR_WIDTH     ( ADDR_WIDTH                              ), 
                                      .ID_WIDTH       ( ID_WIDTH                                ),
                                      .DATA_WIDTH     ( DATA_WIDTH                              ),
                                      .BE_WIDTH       ( BE_WIDTH                                ),
                                      .N_MASTER       ( N_MASTER                                )
                                  ) 
                                  i_FanInPrimitive_Req
                                  (
                                      .PRIO_FLAG(TCDM_arb_policy_i ? rr_tree_q[(1<<j)-1+k] : s_RR_FLAG[LOG_MASTER-j-1]),
                                      .data_wdata0_i  ( data_wdata_LEVEL[((2**j)*2-2) + 2*k]    ),
                                      .data_wdata1_i  ( data_wdata_LEVEL[((2**j)*2-2) + 2*k +1] ),
                                      .data_add0_i    ( data_add_LEVEL[((2**j)*2-2) + 2*k]      ),
                                      .data_add1_i    ( data_add_LEVEL[((2**j)*2-2) + 2*k+1]    ),
                                      .data_req0_i    ( data_req_LEVEL[((2**j)*2-2) + 2*k]      ),
                                      .data_req1_i    ( data_req_LEVEL[((2**j)*2-2) + 2*k+1]    ),
                                      .data_wen0_i    ( data_wen_LEVEL[((2**j)*2-2) + 2*k]      ),
                                      .data_wen1_i    ( data_wen_LEVEL[((2**j)*2-2) + 2*k+1]    ),
                                      .data_ID0_i     ( data_ID_LEVEL[((2**j)*2-2) + 2*k]       ),
                                      .data_ID1_i     ( data_ID_LEVEL[((2**j)*2-2) + 2*k+1]     ),
                                      .ID0_i          ( ID_LEVEL[((2**j)*2-2) + 2*k]            ),
                                      .ID1_i          ( ID_LEVEL[((2**j)*2-2) + 2*k+1]          ),                                     
                                      .data_be0_i     ( data_be_LEVEL[((2**j)*2-2) + 2*k]       ),
                                      .data_be1_i     ( data_be_LEVEL[((2**j)*2-2) + 2*k+1]     ),
                              `ifdef GNT_BASED_FC
                                      .data_gnt0_o    ( data_gnt_LEVEL[((2**j)*2-2) + 2*k]      ),
                                      .data_gnt1_o    ( data_gnt_LEVEL[((2**j)*2-2) + 2*k+1]    ),
                              `else
                                      .data_stall0_o  ( data_stall_LEVEL[((2**j)*2-2) + 2*k]    ),
                                      .data_stall1_o  ( data_stall_LEVEL[((2**j)*2-2) + 2*k+1]  ),
                              `endif
                                      .data_wdata_o   ( data_wdata_LEVEL[((2**(j-1))*2-2) + k]  ),
                                      .data_add_o     ( data_add_LEVEL[((2**(j-1))*2-2) + k]    ),
                                      .data_req_o     ( data_req_LEVEL[((2**(j-1))*2-2) + k]    ),
                                      .data_wen_o     ( data_wen_LEVEL[((2**(j-1))*2-2) + k]    ),
                                      .data_ID_o      ( data_ID_LEVEL[((2**(j-1))*2-2) + k]     ),
                                      .ID_o           ( ID_LEVEL[((2**(j-1))*2-2) + k]          ),
                                      .data_be_o      ( data_be_LEVEL[((2**(j-1))*2-2) + k]     ),
                              `ifdef GNT_BASED_FC
                                      .data_gnt_i     ( data_gnt_LEVEL[((2**(j-1))*2-2) + k]    )
                              `else
                                      .data_stall_i   ( data_stall_LEVEL[((2**(j-1))*2-2) + k]  )
                              `endif
                                  );
                              end
                           else
                              begin : LEAF_NODES
                                  assign ID_int[2*k]   = 2*k;
                                  assign ID_int[2*k+1] = 2*k+1;
                                  
                                  FanInPrimitive_Req 
                                  #(
                                      .ADDR_WIDTH     ( ADDR_WIDTH      ), 
                                      .ID_WIDTH       ( ID_WIDTH        ),
                                      .DATA_WIDTH     ( DATA_WIDTH      ),
                                      .BE_WIDTH       ( BE_WIDTH        ),
                                      .N_MASTER       ( N_MASTER        )
                                  ) 
                                  i_FanInPrimitive_Req
                                  (
                                      .PRIO_FLAG(TCDM_arb_policy_i ? rr_tree_q[(1<<j)-1+k] : s_RR_FLAG[LOG_MASTER-j-1]),
                                      .data_wdata0_i  ( data_wdata_i[2*k]  ),
                                      .data_wdata1_i  ( data_wdata_i[2*k+1]),
                                      .data_add0_i    ( data_add_i[2*k]    ),
                                      .data_add1_i    ( data_add_i[2*k+1]  ),
                                      .data_req0_i    ( gated_req[2*k]     ),
                                      .data_req1_i    ( gated_req[2*k+1]   ),
                                      .data_wen0_i    ( data_wen_i[2*k]    ),
                                      .data_wen1_i    ( data_wen_i[2*k+1]  ),
                                      .data_ID0_i     ( data_ID_i[2*k]     ),
                                      .data_ID1_i     ( data_ID_i[2*k+1]   ),
                                      .ID0_i          ( ID_int[2*k]        ),
                                      .ID1_i          ( ID_int[2*k+1]      ),
                                      .data_be0_i     ( data_be_i[2*k]     ),
                                      .data_be1_i     ( data_be_i[2*k+1]   ),
                              `ifdef GNT_BASED_FC
                                      .data_gnt0_o    ( data_gnt_o[2*k]    ),
                                      .data_gnt1_o    ( data_gnt_o[2*k+1]  ),
                              `else
                                      .data_stall0_o  ( data_stall_o[2*k]  ),
                                      .data_stall1_o  ( data_stall_o[2*k+1]),
                              `endif
                                      .data_wdata_o   ( data_wdata_LEVEL[((2**(j-1))*2-2) + k] ),
                                      .data_add_o     ( data_add_LEVEL[((2**(j-1))*2-2) + k]   ),
                                      .data_req_o     ( data_req_LEVEL[((2**(j-1))*2-2) + k]   ),
                                      .data_wen_o     ( data_wen_LEVEL[((2**(j-1))*2-2) + k]   ),
                                      .data_ID_o      ( data_ID_LEVEL[((2**(j-1))*2-2) + k]    ),
                                      .ID_o           ( ID_LEVEL[((2**(j-1))*2-2) + k]         ),
                                      .data_be_o      ( data_be_LEVEL[((2**(j-1))*2-2) + k]    ),
                              `ifdef GNT_BASED_FC
                                      .data_gnt_i     ( data_gnt_LEVEL[((2**(j-1))*2-2) + k]   )
                              `else
                                      .data_stall_i   ( data_stall_LEVEL[((2**(j-1))*2-2) + k] )
                              `endif
                                  );
                              end
                    end
                end
    end
    endgenerate

    priority_Flag_Req #( .WIDTH(LOG_MASTER), .MAX_COUNT(MAX_COUNT) )  PRIORITY_ENC_REQ
    (
        .clk               ( clk                     ),
        .rst_n             ( rst_n                   ),
        .TCDM_arb_policy_i ( TCDM_arb_policy_i       ),
        .PRIO_FLAG_o       ( s_RR_FLAG               ), 
        .data_req_i        ( data_req_o              ),
        .ID_i              ( s_ID                    ),
      `ifdef GNT_BASED_FC
        .data_gnt_i        ( data_gnt_i              )
      `else
        .data_stall_i      ( data_stall_i            )
      `endif
    );

endmodule
