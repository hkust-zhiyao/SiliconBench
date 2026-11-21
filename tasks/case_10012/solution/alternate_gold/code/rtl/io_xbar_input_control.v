// Copyright (c) 2015 Princeton University
// All rights reserved.
// BSD-3-Clause
`include "network_define.v"

module io_xbar_input_control(
    thanks_all_temp_out,
    route_req_0_out, route_req_1_out, route_req_2_out, route_req_3_out, route_req_4_out, route_req_5_out, route_req_6_out, route_req_7_out,
    default_ready_0, default_ready_1, default_ready_2, default_ready_3, default_ready_4, default_ready_5, default_ready_6, default_ready_7,
    tail_out, clk, reset,
    my_loc_x_in, my_loc_y_in, my_chip_id_in,
    abs_x, abs_y, abs_chip_id, final_bits, valid_in,
    thanks_0, thanks_1, thanks_2, thanks_3, thanks_4, thanks_5, thanks_6, thanks_7,
    length
);

output thanks_all_temp_out;
output route_req_0_out, route_req_1_out, route_req_2_out, route_req_3_out, route_req_4_out, route_req_5_out, route_req_6_out, route_req_7_out;
output default_ready_0, default_ready_1, default_ready_2, default_ready_3, default_ready_4, default_ready_5, default_ready_6, default_ready_7;
output tail_out;

input clk, reset;
input [`XY_WIDTH-1:0] my_loc_x_in, my_loc_y_in, abs_x, abs_y;
input [`CHIP_ID_WIDTH-1:0] my_chip_id_in, abs_chip_id;
input [2:0] final_bits;
input valid_in;
input thanks_0, thanks_1, thanks_2, thanks_3, thanks_4, thanks_5, thanks_6, thanks_7;
input [`PAYLOAD_LEN-1:0] length;

reg [`PAYLOAD_LEN-1:0] rem_f;

wire thanks_all_temp = thanks_0 | thanks_1 | thanks_2 | thanks_3 | thanks_4 | thanks_5 | thanks_6 | thanks_7;
wire is_header_phase = (rem_f == `PAYLOAD_LEN'd0);
wire header          = valid_in & is_header_phase;
wire length_zero     = (length == `PAYLOAD_LEN'd0);

assign thanks_all_temp_out = thanks_all_temp;
assign tail_out = is_header_phase ? (valid_in & length_zero) : (rem_f == `PAYLOAD_LEN'd1);

io_xbar_route_request_calc tail_calc(
    .route_req_0(route_req_0_out), .route_req_1(route_req_1_out), .route_req_2(route_req_2_out), .route_req_3(route_req_3_out),
    .route_req_4(route_req_4_out), .route_req_5(route_req_5_out), .route_req_6(route_req_6_out), .route_req_7(route_req_7_out),
    .default_ready_0(default_ready_0), .default_ready_1(default_ready_1), .default_ready_2(default_ready_2), .default_ready_3(default_ready_3),
    .default_ready_4(default_ready_4), .default_ready_5(default_ready_5), .default_ready_6(default_ready_6), .default_ready_7(default_ready_7),
    .my_loc_x_in(my_loc_x_in), .my_loc_y_in(my_loc_y_in), .my_chip_id_in(my_chip_id_in),
    .abs_x(abs_x), .abs_y(abs_y), .abs_chip_id(abs_chip_id),
    .final_bits(final_bits), .length(length), .header_in(header)
);

always @(posedge clk) begin
    if (reset) begin
        rem_f <= `PAYLOAD_LEN'd0;
    end else if (thanks_all_temp) begin
        rem_f <= is_header_phase ? length : (rem_f - `PAYLOAD_LEN'd1);
    end
end
endmodule
