// Copyright (c) 2015 Princeton University
// All rights reserved.
// BSD-3-Clause
`include "network_define.v"

module io_xbar_output_top(
    data_out,
    thanks_0_out, thanks_1_out, thanks_2_out, thanks_3_out, thanks_4_out, thanks_5_out, thanks_6_out, thanks_7_out,
    valid_out, popped_interrupt_mesg_out, popped_memory_ack_mesg_out, popped_memory_ack_mesg_out_sender,
    ec_wants_to_send_but_cannot, clk, reset,
    route_req_0_in, route_req_1_in, route_req_2_in, route_req_3_in, route_req_4_in, route_req_5_in, route_req_6_in, route_req_7_in,
    tail_0_in, tail_1_in, tail_2_in, tail_3_in, tail_4_in, tail_5_in, tail_6_in, tail_7_in,
    data_0_in, data_1_in, data_2_in, data_3_in, data_4_in, data_5_in, data_6_in, data_7_in,
    valid_0_in, valid_1_in, valid_2_in, valid_3_in, valid_4_in, valid_5_in, valid_6_in, valid_7_in,
    default_ready_in, yummy_in
);
parameter KILL_HEADERS = 1'b0;

output [`DATA_WIDTH-1:0] data_out;
output thanks_0_out, thanks_1_out, thanks_2_out, thanks_3_out, thanks_4_out, thanks_5_out, thanks_6_out, thanks_7_out;
output valid_out;
output popped_interrupt_mesg_out;
output popped_memory_ack_mesg_out;
output [9:0] popped_memory_ack_mesg_out_sender;
output ec_wants_to_send_but_cannot;

input clk, reset;
input route_req_0_in, route_req_1_in, route_req_2_in, route_req_3_in, route_req_4_in, route_req_5_in, route_req_6_in, route_req_7_in;
input tail_0_in, tail_1_in, tail_2_in, tail_3_in, tail_4_in, tail_5_in, tail_6_in, tail_7_in;
input [`DATA_WIDTH-1:0] data_0_in, data_1_in, data_2_in, data_3_in, data_4_in, data_5_in, data_6_in, data_7_in;
input valid_0_in, valid_1_in, valid_2_in, valid_3_in, valid_4_in, valid_5_in, valid_6_in, valid_7_in;
input default_ready_in;
input yummy_in;

wire valid_out_temp_connection;
wire [2:0] current_route_connection;
wire space_avail_connection;
wire valid_out_pre;
wire [`DATA_WIDTH-1:0] data_out_internal;
wire valid_out_internal;

assign valid_out = valid_out_internal;
assign valid_out_internal = valid_out_pre;
assign popped_interrupt_mesg_out = 1'b0;
assign popped_memory_ack_mesg_out = 1'b0;
assign popped_memory_ack_mesg_out_sender = 10'd0;
assign data_out = data_out_internal;

space_avail_top space(
    .valid(valid_out_internal),
    .clk(clk),
    .reset(reset),
    .yummy(yummy_in),
    .spc_avail(space_avail_connection)
);

io_xbar_output_datapath datapath(
    .data_out(data_out_internal),
    .valid_out_temp(valid_out_temp_connection),
    .data_0_in(data_0_in), .data_1_in(data_1_in), .data_2_in(data_2_in), .data_3_in(data_3_in),
    .data_4_in(data_4_in), .data_5_in(data_5_in), .data_6_in(data_6_in), .data_7_in(data_7_in),
    .valid_0_in(valid_0_in), .valid_1_in(valid_1_in), .valid_2_in(valid_2_in), .valid_3_in(valid_3_in),
    .valid_4_in(valid_4_in), .valid_5_in(valid_5_in), .valid_6_in(valid_6_in), .valid_7_in(valid_7_in),
    .current_route_in(current_route_connection)
);

io_xbar_output_control control(
    .thanks_0(thanks_0_out), .thanks_1(thanks_1_out), .thanks_2(thanks_2_out), .thanks_3(thanks_3_out),
    .thanks_4(thanks_4_out), .thanks_5(thanks_5_out), .thanks_6(thanks_6_out), .thanks_7(thanks_7_out),
    .valid_out(valid_out_pre),
    .current_route(current_route_connection),
    .ec_wants_to_send_but_cannot(ec_wants_to_send_but_cannot),
    .clk(clk),
    .reset(reset),
    .route_req_0_in(route_req_0_in), .route_req_1_in(route_req_1_in), .route_req_2_in(route_req_2_in), .route_req_3_in(route_req_3_in),
    .route_req_4_in(route_req_4_in), .route_req_5_in(route_req_5_in), .route_req_6_in(route_req_6_in), .route_req_7_in(route_req_7_in),
    .tail_0_in(tail_0_in), .tail_1_in(tail_1_in), .tail_2_in(tail_2_in), .tail_3_in(tail_3_in),
    .tail_4_in(tail_4_in), .tail_5_in(tail_5_in), .tail_6_in(tail_6_in), .tail_7_in(tail_7_in),
    .valid_out_temp(valid_out_temp_connection),
    .default_ready(default_ready_in),
    .space_avail(space_avail_connection)
);
endmodule
