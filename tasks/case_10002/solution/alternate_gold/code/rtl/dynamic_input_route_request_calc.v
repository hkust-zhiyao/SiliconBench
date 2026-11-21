`include "network_define.v"

module dynamic_input_route_request_calc(
    route_req_n, route_req_e, route_req_s, route_req_w, route_req_p,
    default_ready_n, default_ready_e, default_ready_s, default_ready_w, default_ready_p,
    my_loc_x_in, my_loc_y_in, my_chip_id_in, abs_x, abs_y, abs_chip_id, final_bits, length, header_in
);

output route_req_n;
output route_req_e;
output route_req_s;
output route_req_w;
output route_req_p;
output default_ready_n;
output default_ready_e;
output default_ready_s;
output default_ready_w;
output default_ready_p;

input [`XY_WIDTH-1:0] my_loc_x_in;
input [`XY_WIDTH-1:0] my_loc_y_in;
input [`CHIP_ID_WIDTH-1:0] my_chip_id_in;
input [`XY_WIDTH-1:0] abs_x;
input [`XY_WIDTH-1:0] abs_y;
input [`CHIP_ID_WIDTH-1:0] abs_chip_id;
input [2:0] final_bits;
input [`PAYLOAD_LEN-1:0] length;
input header_in;

`define FINAL_NONE  3'b000
`define FINAL_WEST  3'b010
`define FINAL_SOUTH 3'b011
`define FINAL_EAST  3'b100
`define FINAL_NORTH 3'b101

wire off_chip = |(abs_chip_id ^ my_chip_id_in);

// 2-nibble magnitude comparison for X
wire x_eq_hi = (abs_x[7:4] == my_loc_x_in[7:4]);
wire x_eq_lo = (abs_x[3:0] == my_loc_x_in[3:0]);
wire x_gt_hi = (abs_x[7:4] >  my_loc_x_in[7:4]);
wire x_gt_lo = (abs_x[3:0] >  my_loc_x_in[3:0]);
wire x_lt_hi = (abs_x[7:4] <  my_loc_x_in[7:4]);
wire x_lt_lo = (abs_x[3:0] <  my_loc_x_in[3:0]);

wire x_eq_abs = x_eq_hi & x_eq_lo;
wire x_gt_abs = x_gt_hi | (x_eq_hi & x_gt_lo);
wire x_lt_abs = x_lt_hi | (x_eq_hi & x_lt_lo);
wire x_zero_loc = (my_loc_x_in == 8'd0);

// 2-nibble magnitude comparison for Y
wire y_eq_hi = (abs_y[7:4] == my_loc_y_in[7:4]);
wire y_eq_lo = (abs_y[3:0] == my_loc_y_in[3:0]);
wire y_gt_hi = (abs_y[7:4] >  my_loc_y_in[7:4]);
wire y_gt_lo = (abs_y[3:0] >  my_loc_y_in[3:0]);
wire y_lt_hi = (abs_y[7:4] <  my_loc_y_in[7:4]);
wire y_lt_lo = (abs_y[3:0] <  my_loc_y_in[3:0]);

wire y_eq_abs = y_eq_hi & y_eq_lo;
wire y_gt_abs = y_gt_hi | (y_eq_hi & y_gt_lo);
wire y_lt_abs = y_lt_hi | (y_eq_hi & y_lt_lo);
wire y_zero_loc = (my_loc_y_in == 8'd0);

wire done_x = off_chip ?  x_zero_loc : x_eq_abs;
wire more_x = off_chip ?  1'b0       : x_gt_abs;
wire less_x = off_chip ? ~x_zero_loc : x_lt_abs;

wire done_y = off_chip ?  y_zero_loc : y_eq_abs;
wire more_y = off_chip ?  1'b0       : y_gt_abs;
wire less_y = off_chip ? ~y_zero_loc : y_lt_abs;

wire done = done_x & done_y;

reg [4:0] fbit_dir;
always @* begin
    case (final_bits)
        `FINAL_NORTH: fbit_dir = 5'b10000;
        `FINAL_EAST:  fbit_dir = 5'b01000;
        `FINAL_SOUTH: fbit_dir = 5'b00100;
        `FINAL_WEST:  fbit_dir = 5'b00010;
        default:      fbit_dir = 5'b00001;
    endcase
end

assign route_req_n = header_in & ((done_x & less_y) | (done & fbit_dir[4]));
assign route_req_e = header_in & (more_x            | (done & fbit_dir[3]));
assign route_req_s = header_in & ((done_x & more_y) | (done & fbit_dir[2]));
assign route_req_w = header_in & (less_x            | (done & fbit_dir[1]));
assign route_req_p = header_in & (done              & fbit_dir[0]);

assign default_ready_n = route_req_n;
assign default_ready_e = route_req_e;
assign default_ready_s = route_req_s;
assign default_ready_w = route_req_w;
assign default_ready_p = route_req_p;

endmodule
