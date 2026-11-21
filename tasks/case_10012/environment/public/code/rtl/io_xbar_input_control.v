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

reg [`PAYLOAD_LEN-1:0] count_f;
reg header_last_f;
reg thanks_all_f;
reg count_zero_f;
reg count_one_f;
reg tail_last_f;

reg [`PAYLOAD_LEN-1:0] count_temp;
wire header_last_temp;
wire thanks_all_temp;
wire count_zero_temp;
wire count_one_temp;
wire tail_last_temp;

wire header;
wire [`PAYLOAD_LEN-1:0] count_minus_one;
wire length_zero;
wire tail;
reg header_temp;

assign thanks_all_temp = thanks_0 | thanks_1 | thanks_2 | thanks_3 | thanks_4 | thanks_5 | thanks_6 | thanks_7;
assign header = valid_in & header_temp;
assign count_zero_temp = count_temp == 0;
assign count_one_temp = count_temp == 1;
assign thanks_all_temp_out = thanks_all_temp;
assign tail_out = tail;
assign count_minus_one = count_f - 1;
assign length_zero = length == 0;
assign header_last_temp = header_temp;
assign tail = (header & length_zero) | ((~thanks_all_f) & tail_last_f) | (thanks_all_f & count_one_f);
assign tail_last_temp = tail;

io_xbar_route_request_calc tail_calc(
    .route_req_0(route_req_0_out), .route_req_1(route_req_1_out), .route_req_2(route_req_2_out), .route_req_3(route_req_3_out),
    .route_req_4(route_req_4_out), .route_req_5(route_req_5_out), .route_req_6(route_req_6_out), .route_req_7(route_req_7_out),
    .default_ready_0(default_ready_0), .default_ready_1(default_ready_1), .default_ready_2(default_ready_2), .default_ready_3(default_ready_3),
    .default_ready_4(default_ready_4), .default_ready_5(default_ready_5), .default_ready_6(default_ready_6), .default_ready_7(default_ready_7),
    .my_loc_x_in(my_loc_x_in), .my_loc_y_in(my_loc_y_in), .my_chip_id_in(my_chip_id_in),
    .abs_x(abs_x), .abs_y(abs_y), .abs_chip_id(abs_chip_id),
    .final_bits(final_bits), .length(length), .header_in(header)
);

always @ (header_last_f or thanks_all_f or count_zero_f) begin
    case({header_last_f, count_zero_f, thanks_all_f})
    3'b000: header_temp <= 1'b0;
    3'b001: header_temp <= 1'b0;
    3'b010: header_temp <= 1'b0;
    3'b011: header_temp <= 1'b1;
    3'b100: header_temp <= 1'b1;
    3'b101: header_temp <= 1'b0;
    3'b110: header_temp <= 1'b1;
    3'b111: header_temp <= 1'b1;
    default: header_temp <= 1'b1;
    endcase
end

always @ (header or thanks_all_f or count_f or count_minus_one or length) begin
    if(header)
        count_temp <= length;
    else if(thanks_all_f)
        count_temp <= count_minus_one;
    else
        count_temp <= count_f;
end

always @ (posedge clk) begin
    if(reset) begin
        count_f <= 5'd0;
        header_last_f <= 1'b1;
        thanks_all_f <= 1'b0;
        count_zero_f <= 1'b1;
        count_one_f <= 1'b0;
        tail_last_f <= 1'b0;
    end else begin
        count_f <= count_temp;
        header_last_f <= header_last_temp;
        thanks_all_f <= thanks_all_temp;
        count_zero_f <= count_zero_temp;
        count_one_f <= count_one_temp;
        tail_last_f <= tail_last_temp;
    end
end
endmodule
