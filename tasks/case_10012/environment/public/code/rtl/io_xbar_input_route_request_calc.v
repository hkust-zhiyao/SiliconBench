// Copyright (c) 2015 Princeton University
// All rights reserved.
// BSD-3-Clause
`include "network_define.v"

module io_xbar_route_request_calc(
    route_req_0, route_req_1, route_req_2, route_req_3, route_req_4, route_req_5, route_req_6, route_req_7,
    default_ready_0, default_ready_1, default_ready_2, default_ready_3, default_ready_4, default_ready_5, default_ready_6, default_ready_7,
    my_loc_x_in, my_loc_y_in, my_chip_id_in, abs_x, abs_y, abs_chip_id, final_bits, length, header_in
);

output route_req_0, route_req_1, route_req_2, route_req_3, route_req_4, route_req_5, route_req_6, route_req_7;
output default_ready_0, default_ready_1, default_ready_2, default_ready_3, default_ready_4, default_ready_5, default_ready_6, default_ready_7;

input [`XY_WIDTH-1:0] my_loc_x_in;
input [`XY_WIDTH-1:0] my_loc_y_in;
input [`CHIP_ID_WIDTH-1:0] my_chip_id_in;
input [`XY_WIDTH-1:0] abs_x;
input [`XY_WIDTH-1:0] abs_y;
input [`CHIP_ID_WIDTH-1:0] abs_chip_id;
input [2:0] final_bits;
input [`PAYLOAD_LEN-1:0] length;
input header_in;

wire off_chip = (abs_chip_id != my_chip_id_in);

assign route_req_0 = header_in & (!off_chip) & (abs_x == 8'd0);
assign route_req_1 = header_in & (!off_chip) & (abs_x == 8'd1);
assign route_req_2 = header_in & (!off_chip) & (abs_x == 8'd2);
assign route_req_3 = header_in & (!off_chip) & (abs_x == 8'd3);
assign route_req_4 = header_in & (!off_chip) & (abs_x == 8'd4);
assign route_req_5 = header_in & (!off_chip) & (abs_x == 8'd5);
assign route_req_6 = header_in & (!off_chip) & (abs_x == 8'd6);
assign route_req_7 = header_in & (!off_chip) & (abs_x == 8'd7);

assign default_ready_0 = route_req_0;
assign default_ready_1 = route_req_1;
assign default_ready_2 = route_req_2;
assign default_ready_3 = route_req_3;
assign default_ready_4 = route_req_4;
assign default_ready_5 = route_req_5;
assign default_ready_6 = route_req_6;
assign default_ready_7 = route_req_7;

endmodule
