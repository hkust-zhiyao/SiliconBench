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

reg tail_current_route;
always @* begin
    case (current_route_f)
        `ROUTE_A: tail_current_route = tail_a_in;
        `ROUTE_B: tail_current_route = tail_b_in;
        `ROUTE_C: tail_current_route = tail_c_in;
        `ROUTE_D: tail_current_route = tail_d_in;
        `ROUTE_X: tail_current_route = tail_x_in;
        default:  tail_current_route = 1'b0;
    endcase
end

assign thanks_a = (current_route_f == `ROUTE_A) & valid_out_internal;
assign thanks_b = (current_route_f == `ROUTE_B) & valid_out_internal;
assign thanks_c = (current_route_f == `ROUTE_C) & valid_out_internal;
assign thanks_d = (current_route_f == `ROUTE_D) & valid_out_internal;
assign thanks_x = (current_route_f == `ROUTE_X) & valid_out_internal;

// Round-robin base is registered: current_route_f when planned_f == 1, else last_route_f!
// Notice: when planned_f == 0 and default_ready == 1, Route A is sending a default-route packet,
// AND if it finishes on this cycle (valid_out_internal && tail_current_route), its route is ROUTE_A!
// Even better: if we simply keep `current_route_f` holding the last served route during idle cycles
// (only defaulting to `ROUTE_A` when `!planned_f` at the output mux or when nothing requests),
// wait: in `dynamic_output_top`, `current_route` drives `datapath` (`one_of_five` mux), which MUST select `ROUTE_A` (`3'b000`) when `planned_f == 0` so the default route (`default_ready`) works!
// Therefore, `rr_base` is simply `planned_f ? current_route_f : last_route_f`, which depends ONLY on flip-flops (`planned_f`, `current_route_f`, `last_route_f`) and NOT on `valid_out_internal`!
wire [2:0] rr_base = planned_f ? current_route_f : last_route_f;

reg [2:0] new_route;
always @* begin
    case (rr_base)
        `ROUTE_A: new_route = route_req_b_in ? `ROUTE_B : (route_req_c_in ? `ROUTE_C : (route_req_d_in ? `ROUTE_D : (route_req_x_in ? `ROUTE_X : `ROUTE_A)));
        `ROUTE_B: new_route = route_req_c_in ? `ROUTE_C : (route_req_d_in ? `ROUTE_D : (route_req_x_in ? `ROUTE_X : (route_req_a_in ? `ROUTE_A : (route_req_b_in ? `ROUTE_B : `ROUTE_A))));
        `ROUTE_C: new_route = route_req_d_in ? `ROUTE_D : (route_req_x_in ? `ROUTE_X : (route_req_a_in ? `ROUTE_A : (route_req_b_in ? `ROUTE_B : (route_req_c_in ? `ROUTE_C : `ROUTE_A))));
        `ROUTE_D: new_route = route_req_x_in ? `ROUTE_X : (route_req_a_in ? `ROUTE_A : (route_req_b_in ? `ROUTE_B : (route_req_c_in ? `ROUTE_C : (route_req_d_in ? `ROUTE_D : `ROUTE_A))));
        `ROUTE_X: new_route = route_req_a_in ? `ROUTE_A : (route_req_b_in ? `ROUTE_B : (route_req_c_in ? `ROUTE_C : (route_req_d_in ? `ROUTE_D : (route_req_x_in ? `ROUTE_X : `ROUTE_A))));
        default:  new_route = `ROUTE_A;
    endcase
end

// Mask out current_route_f ONLY when `planned_f == 1` (exact same fast flop-only mask as original)!
wire route_req_a_mask = ~(planned_f & (current_route_f == `ROUTE_A));
wire route_req_b_mask = ~(planned_f & (current_route_f == `ROUTE_B));
wire route_req_c_mask = ~(planned_f & (current_route_f == `ROUTE_C));
wire route_req_d_mask = ~(planned_f & (current_route_f == `ROUTE_D));
wire route_req_x_mask = ~(planned_f & (current_route_f == `ROUTE_X));

wire route_req_all_or_with_planned =
    (route_req_a_in & route_req_a_mask) |
    (route_req_b_in & route_req_b_mask) |
    (route_req_c_in & route_req_c_mask) |
    (route_req_d_in & route_req_d_mask) |
    (route_req_x_in & route_req_x_mask);

wire route_req_all_but_default = route_req_b_in | route_req_c_in | route_req_d_in | route_req_x_in;

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
