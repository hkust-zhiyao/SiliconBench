`include "network_define.v"

module dynamic_output_control(
    thanks_a, thanks_b, thanks_c, thanks_d, thanks_x,
    valid_out, current_route, ec_wants_to_send_but_cannot,
    clk, reset,
    route_req_a_in, route_req_b_in, route_req_c_in, route_req_d_in, route_req_x_in,
    tail_a_in, tail_b_in, tail_c_in, tail_d_in, tail_x_in,
    valid_out_temp, default_ready, space_avail
);

output thanks_a;
output thanks_b;
output thanks_c;
output thanks_d;
output thanks_x;
output valid_out;
output [2:0] current_route;
output ec_wants_to_send_but_cannot;

input clk;
input reset;

input route_req_a_in;
input route_req_b_in;
input route_req_c_in;
input route_req_d_in;
input route_req_x_in;

input tail_a_in;
input tail_b_in;
input tail_c_in;
input tail_d_in;
input tail_x_in;

input valid_out_temp;
input default_ready;
input space_avail;

`define ROUTE_A 3'b000
`define ROUTE_B 3'b001
`define ROUTE_C 3'b010
`define ROUTE_D 3'b011
`define ROUTE_X 3'b100

reg [2:0] current_route_f;
reg [2:0] last_route_f;
reg planned_f;
reg ec_wants_to_send_but_cannot;

wire planned_or_default = planned_f | default_ready;
wire valid_out_internal = valid_out_temp & planned_or_default & space_avail;
assign valid_out = valid_out_internal;
assign current_route = current_route_f;

always @(posedge clk) begin
    if (reset)
        ec_wants_to_send_but_cannot <= 1'b0;
    else
        ec_wants_to_send_but_cannot <= valid_out_temp & planned_or_default & ~space_avail;
end

wire tail_current_route =
    ((current_route_f == `ROUTE_A) & tail_a_in) |
    ((current_route_f == `ROUTE_B) & tail_b_in) |
    ((current_route_f == `ROUTE_C) & tail_c_in) |
    ((current_route_f == `ROUTE_D) & tail_d_in) |
    ((current_route_f == `ROUTE_X) & tail_x_in);

assign thanks_a = (current_route_f == `ROUTE_A) & valid_out_internal;
assign thanks_b = (current_route_f == `ROUTE_B) & valid_out_internal;
assign thanks_c = (current_route_f == `ROUTE_C) & valid_out_internal;
assign thanks_d = (current_route_f == `ROUTE_D) & valid_out_internal;
assign thanks_x = (current_route_f == `ROUTE_X) & valid_out_internal;

wire [2:0] rr_base = planned_f ? current_route_f : last_route_f;

wire [4:0] req_vec = {route_req_x_in, route_req_d_in, route_req_c_in, route_req_b_in, route_req_a_in};
reg  [2:0] new_route;
always @* begin
    case (rr_base)
        `ROUTE_A: new_route = req_vec[1] ? `ROUTE_B : req_vec[2] ? `ROUTE_C : req_vec[3] ? `ROUTE_D : req_vec[4] ? `ROUTE_X : `ROUTE_A;
        `ROUTE_B: new_route = req_vec[2] ? `ROUTE_C : req_vec[3] ? `ROUTE_D : req_vec[4] ? `ROUTE_X : req_vec[0] ? `ROUTE_A : req_vec[1] ? `ROUTE_B : `ROUTE_A;
        `ROUTE_C: new_route = req_vec[3] ? `ROUTE_D : req_vec[4] ? `ROUTE_X : req_vec[0] ? `ROUTE_A : req_vec[1] ? `ROUTE_B : req_vec[2] ? `ROUTE_C : `ROUTE_A;
        `ROUTE_D: new_route = req_vec[4] ? `ROUTE_X : req_vec[0] ? `ROUTE_A : req_vec[1] ? `ROUTE_B : req_vec[2] ? `ROUTE_C : req_vec[3] ? `ROUTE_D : `ROUTE_A;
        `ROUTE_X: new_route = req_vec[0] ? `ROUTE_A : req_vec[1] ? `ROUTE_B : req_vec[2] ? `ROUTE_C : req_vec[3] ? `ROUTE_D : req_vec[4] ? `ROUTE_X : `ROUTE_A;
        default:  new_route = `ROUTE_A;
    endcase
end

wire [4:0] mask_vec = planned_f ? ~(5'b00001 << current_route_f) : 5'b11111;
wire route_req_all_or_with_planned = |(req_vec & mask_vec);
wire route_req_all_but_default     = |req_vec[4:1];

wire new_route_needed = (~planned_f & ~valid_out_internal) | (valid_out_internal & tail_current_route);
wire default_zero_sent = (~planned_f) & default_ready & valid_out_internal & tail_current_route;
wire planned_temp = default_zero_sent ? route_req_all_but_default :
                    route_req_all_or_with_planned ? 1'b1 :
                    (planned_f & ~(valid_out_internal & tail_current_route));

wire [2:0] current_route_temp = new_route_needed ? new_route : current_route_f;

always @(posedge clk) begin
    if (reset) begin
        current_route_f <= `ROUTE_A;
        last_route_f    <= `ROUTE_A;
        planned_f       <= 1'b0;
    end else begin
        current_route_f <= current_route_temp;
        planned_f       <= planned_temp;
        if (valid_out_internal & tail_current_route)
            last_route_f <= current_route_f;
    end
end

endmodule
