// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0.

(* blackbox, keep_hierarchy = "yes" *)
module VX_sp_ram_asic #(
    parameter DATAW = 1,
    parameter SIZE  = 1,
    parameter WRENW = 1,
    parameter ADDRW = $clog2(SIZE)
) (
    input wire               clk,
    input wire               reset,
    input wire               read,
    input wire               write,
    input wire [WRENW-1:0]   wren,
    input wire [ADDRW-1:0]   addr,
    input wire [DATAW-1:0]   wdata,
    output wire [DATAW-1:0]  rdata
);
    localparam WSELW = DATAW / WRENW;
    reg [DATAW-1:0] mem [0:SIZE-1];
    reg [DATAW-1:0] rdata_reg;
    always @(posedge clk) begin
        if (reset) begin
            rdata_reg <= '0;
        end else if (read) begin
            rdata_reg <= mem[addr];
        end
        if (write) begin
            for (integer i = 0; i < WRENW; ++i) begin
                if (wren[i]) begin
                    mem[addr][i * WSELW +: WSELW] <= wdata[i * WSELW +: WSELW];
                end
            end
        end
    end
    assign rdata = rdata_reg;
endmodule
