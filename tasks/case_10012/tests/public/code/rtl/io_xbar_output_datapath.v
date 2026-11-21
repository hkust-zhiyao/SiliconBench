// Copyright (c) 2015 Princeton University
// All rights reserved.
// BSD-3-Clause
`include "network_define.v"

module io_xbar_output_datapath(
    data_out, valid_out_temp,
    data_0_in, data_1_in, data_2_in, data_3_in, data_4_in, data_5_in, data_6_in, data_7_in,
    valid_0_in, valid_1_in, valid_2_in, valid_3_in, valid_4_in, valid_5_in, valid_6_in, valid_7_in,
    current_route_in
);
output [`DATA_WIDTH-1:0] data_out;
output valid_out_temp;
input [`DATA_WIDTH-1:0] data_0_in, data_1_in, data_2_in, data_3_in, data_4_in, data_5_in, data_6_in, data_7_in;
input valid_0_in, valid_1_in, valid_2_in, valid_3_in, valid_4_in, valid_5_in, valid_6_in, valid_7_in;
input [2:0] current_route_in;

one_of_eight #(`DATA_WIDTH) data_mux(
    .in0(data_0_in), .in1(data_1_in), .in2(data_2_in), .in3(data_3_in),
    .in4(data_4_in), .in5(data_5_in), .in6(data_6_in), .in7(data_7_in),
    .sel(current_route_in),
    .out(data_out)
);
one_of_eight #(1) valid_mux(
    .in0(valid_0_in), .in1(valid_1_in), .in2(valid_2_in), .in3(valid_3_in),
    .in4(valid_4_in), .in5(valid_5_in), .in6(valid_6_in), .in7(valid_7_in),
    .sel(current_route_in),
    .out(valid_out_temp)
);
endmodule
