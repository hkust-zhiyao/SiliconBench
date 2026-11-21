// Copyright (c) 2017 Princeton University
// All rights reserved.
// BSD-3-Clause

module storage_addr_trans #(
    parameter MEM_ADDR_WIDTH = 64,
    parameter VA_ADDR_WIDTH = 40,
    parameter STORAGE_ADDR_WIDTH = 64
) (
    input  wire [VA_ADDR_WIDTH-1:0]      va_byte_addr,
    output wire [STORAGE_ADDR_WIDTH-1:0] storage_addr_out,
    output wire                          hit_any_section
);

    wire [63:0] va_ext = {{(64-VA_ADDR_WIDTH){1'b0}}, va_byte_addr};
    assign hit_any_section  = (va_ext >= 64'h0000_0000_8000_0000) && (va_ext < 64'h0000_0001_0000_0000);
    wire [63:0] translated  = hit_any_section ? ((va_ext - 64'h0000_0000_8000_0000) >> 3) : 64'd0;
    assign storage_addr_out = translated[STORAGE_ADDR_WIDTH-1:0];

endmodule
