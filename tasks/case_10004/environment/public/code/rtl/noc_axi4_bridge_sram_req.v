// Copyright (c) 2019 Princeton University
// All rights reserved.
// BSD-3-Clause

`include "noc_axi4_bridge_define.vh"
`include "define.tmp.h"

module noc_axi4_bridge_sram_req (
    input  wire                                          MEMCLK,
    input  wire                                          RESET_N,
    input  wire                                          CEA,
    input  wire [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0]  AA,
    input  wire                                          RDWENA,
    input  wire                                          CEB,
    input  wire [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0]  AB,
    input  wire                                          RDWENB,
    input  wire [`MSG_HEADER_WIDTH-1:0]                  BWA,
    input  wire [`MSG_HEADER_WIDTH-1:0]                  DINA,
    output reg  [`MSG_HEADER_WIDTH-1:0]                  DOUTA,
    input  wire [`MSG_HEADER_WIDTH-1:0]                  BWB,
    input  wire [`MSG_HEADER_WIDTH-1:0]                  DINB,
    output reg  [`MSG_HEADER_WIDTH-1:0]                  DOUTB
);

    reg [`MSG_HEADER_WIDTH-1:0] cache [`NOC_AXI4_BRIDGE_IN_FLIGHT_LIMIT-1:0];
    integer k;

    always @(posedge MEMCLK) begin
        if (!RESET_N) begin
            for (k = 0; k < `NOC_AXI4_BRIDGE_IN_FLIGHT_LIMIT; k = k + 1) begin
                cache[k] <= {`MSG_HEADER_WIDTH{1'b0}};
            end
            DOUTA <= {`MSG_HEADER_WIDTH{1'b0}};
            DOUTB <= {`MSG_HEADER_WIDTH{1'b0}};
        end else begin
            if (CEA) begin
                if (RDWENA == 1'b0)
                    cache[AA] <= (DINA & BWA) | (cache[AA] & ~BWA);
                else
                    DOUTA <= cache[AA];
            end
            if (CEB) begin
                if (RDWENB == 1'b0)
                    cache[AB] <= (DINB & BWB) | (cache[AB] & ~BWB);
                else
                    DOUTB <= cache[AB];
            end
        end
    end

endmodule
