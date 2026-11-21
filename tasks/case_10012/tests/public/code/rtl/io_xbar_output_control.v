// Copyright (c) 2015 Princeton University
// All rights reserved.
// BSD-3-Clause
`include "network_define.v"

module io_xbar_output_control(
    thanks_0, thanks_1, thanks_2, thanks_3, thanks_4, thanks_5, thanks_6, thanks_7,
    valid_out, current_route, ec_wants_to_send_but_cannot, clk, reset,
    route_req_0_in, route_req_1_in, route_req_2_in, route_req_3_in, route_req_4_in, route_req_5_in, route_req_6_in, route_req_7_in,
    tail_0_in, tail_1_in, tail_2_in, tail_3_in, tail_4_in, tail_5_in, tail_6_in, tail_7_in,
    valid_out_temp, default_ready, space_avail
);

output thanks_0, thanks_1, thanks_2, thanks_3, thanks_4, thanks_5, thanks_6, thanks_7;
output valid_out;
output [2:0] current_route;
output reg ec_wants_to_send_but_cannot;

input clk, reset;
input route_req_0_in, route_req_1_in, route_req_2_in, route_req_3_in, route_req_4_in, route_req_5_in, route_req_6_in, route_req_7_in;
input tail_0_in, tail_1_in, tail_2_in, tail_3_in, tail_4_in, tail_5_in, tail_6_in, tail_7_in;
input valid_out_temp, default_ready, space_avail;

reg [2:0] current_route_f;
reg planned_f;

wire planned_or_default = planned_f | default_ready;
wire valid_out_internal = valid_out_temp & planned_or_default & space_avail;
assign valid_out = valid_out_internal;
assign current_route = current_route_f;

always @(posedge clk) begin
    ec_wants_to_send_but_cannot <= valid_out_temp & planned_or_default & ~space_avail;
end

reg tail_current_route;
always @* begin
    case (current_route_f)
        3'd0: tail_current_route = tail_0_in;
        3'd1: tail_current_route = tail_1_in;
        3'd2: tail_current_route = tail_2_in;
        3'd3: tail_current_route = tail_3_in;
        3'd4: tail_current_route = tail_4_in;
        3'd5: tail_current_route = tail_5_in;
        3'd6: tail_current_route = tail_6_in;
        3'd7: tail_current_route = tail_7_in;
        default: tail_current_route = 1'bx;
    endcase
end

assign thanks_0 = (current_route_f == 3'd0) & valid_out_internal;
assign thanks_1 = (current_route_f == 3'd1) & valid_out_internal;
assign thanks_2 = (current_route_f == 3'd2) & valid_out_internal;
assign thanks_3 = (current_route_f == 3'd3) & valid_out_internal;
assign thanks_4 = (current_route_f == 3'd4) & valid_out_internal;
assign thanks_5 = (current_route_f == 3'd5) & valid_out_internal;
assign thanks_6 = (current_route_f == 3'd6) & valid_out_internal;
assign thanks_7 = (current_route_f == 3'd7) & valid_out_internal;

reg [2:0] new_route;
always @* begin
    case (current_route_f)
        3'd0: new_route = (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : 3'd0)))))));
        3'd1: new_route = (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : 3'd0)))))));
        3'd2: new_route = (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : 3'd0)))))));
        3'd3: new_route = (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : 3'd0)))))));
        3'd4: new_route = (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : 3'd0)))))));
        3'd5: new_route = (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : 3'd0)))))));
        3'd6: new_route = (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : 3'd0)))))));
        3'd7: new_route = (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : 3'd0)))))));
        default: new_route = 3'd0;
    endcase
end

wire route_req_0_mask = ~(planned_f & (current_route_f == 3'd0));
wire route_req_1_mask = ~(planned_f & (current_route_f == 3'd1));
wire route_req_2_mask = ~(planned_f & (current_route_f == 3'd2));
wire route_req_3_mask = ~(planned_f & (current_route_f == 3'd3));
wire route_req_4_mask = ~(planned_f & (current_route_f == 3'd4));
wire route_req_5_mask = ~(planned_f & (current_route_f == 3'd5));
wire route_req_6_mask = ~(planned_f & (current_route_f == 3'd6));
wire route_req_7_mask = ~(planned_f & (current_route_f == 3'd7));

wire route_req_all_or_with_planned =
    (route_req_0_in & route_req_0_mask) | (route_req_1_in & route_req_1_mask) |
    (route_req_2_in & route_req_2_mask) | (route_req_3_in & route_req_3_mask) |
    (route_req_4_in & route_req_4_mask) | (route_req_5_in & route_req_5_mask) |
    (route_req_6_in & route_req_6_mask) | (route_req_7_in & route_req_7_mask);

wire route_req_all_but_default =
    route_req_1_in | route_req_2_in | route_req_3_in | route_req_4_in |
    route_req_5_in | route_req_6_in | route_req_7_in;

reg new_route_needed;
always @* begin
    case ({default_ready, valid_out_internal, tail_current_route, planned_f})
        4'b0000: new_route_needed = 1'b1;
        4'b0001: new_route_needed = 1'b0;
        4'b0010: new_route_needed = 1'b1;
        4'b0011: new_route_needed = 1'b0;
        4'b0100: new_route_needed = 1'b0;
        4'b0101: new_route_needed = 1'b0;
        4'b0110: new_route_needed = 1'b1;
        4'b0111: new_route_needed = 1'b1;
        4'b1000: new_route_needed = 1'b1;
        4'b1001: new_route_needed = 1'b0;
        4'b1010: new_route_needed = 1'b1;
        4'b1011: new_route_needed = 1'b0;
        4'b1100: new_route_needed = 1'b0;
        4'b1101: new_route_needed = 1'b0;
        4'b1110: new_route_needed = 1'b1;
        4'b1111: new_route_needed = 1'b1;
        default: new_route_needed = 1'b1;
    endcase
end

reg planned_temp;
always @* begin
    case ({route_req_all_or_with_planned, default_ready, valid_out_internal, tail_current_route, planned_f})
        5'b00000: planned_temp = 1'b0;
        5'b00001: planned_temp = 1'b1;
        5'b00010: planned_temp = 1'b0;
        5'b00011: planned_temp = 1'b1;
        5'b00100: planned_temp = 1'b0;
        5'b00101: planned_temp = 1'b1;
        5'b00110: planned_temp = 1'b0;
        5'b00111: planned_temp = 1'b0;
        5'b01000: planned_temp = 1'b0;
        5'b01001: planned_temp = 1'b1;
        5'b01010: planned_temp = 1'b0;
        5'b01011: planned_temp = 1'b1;
        5'b01100: planned_temp = 1'b0;
        5'b01101: planned_temp = 1'b1;
        5'b01110: planned_temp = 1'b0;
        5'b01111: planned_temp = 1'b0;
        5'b10000: planned_temp = 1'b1;
        5'b10001: planned_temp = 1'b1;
        5'b10010: planned_temp = 1'b1;
        5'b10011: planned_temp = 1'b1;
        5'b10100: planned_temp = 1'b1;
        5'b10101: planned_temp = 1'b1;
        5'b10110: planned_temp = 1'b1;
        5'b10111: planned_temp = 1'b1;
        5'b11000: planned_temp = 1'b1;
        5'b11001: planned_temp = 1'b1;
        5'b11010: planned_temp = 1'b1;
        5'b11011: planned_temp = 1'b1;
        5'b11100: planned_temp = 1'b1;
        5'b11101: planned_temp = 1'b1;
        5'b11110: planned_temp = route_req_all_but_default;
        5'b11111: planned_temp = 1'b1;
        default:  planned_temp = 1'b0;
    endcase
end

wire [2:0] current_route_temp = new_route_needed ? new_route : current_route_f;

always @(posedge clk) begin
    if (reset) begin
        current_route_f <= 3'd0;
        planned_f       <= 1'b0;
    end else begin
        current_route_f <= current_route_temp;
        planned_f       <= planned_temp;
    end
end
endmodule
