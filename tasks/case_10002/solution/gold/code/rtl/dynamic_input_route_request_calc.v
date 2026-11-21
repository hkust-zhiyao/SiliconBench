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

wire off_chip = (abs_chip_id != my_chip_id_in);

wire x_eq_abs = (abs_x == my_loc_x_in);
wire x_gt_abs = (abs_x >  my_loc_x_in);
wire x_lt_abs = (abs_x <  my_loc_x_in);
wire x_nz_loc = |my_loc_x_in;

wire y_eq_abs = (abs_y == my_loc_y_in);
wire y_gt_abs = (abs_y >  my_loc_y_in);
wire y_lt_abs = (abs_y <  my_loc_y_in);
wire y_nz_loc = |my_loc_y_in;

wire done_x = off_chip ? ~x_nz_loc : x_eq_abs;
wire more_x = ~off_chip & x_gt_abs;
wire less_x = off_chip ?  x_nz_loc : x_lt_abs;

wire done_y = off_chip ? ~y_nz_loc : y_eq_abs;
wire more_y = ~off_chip & y_gt_abs;
wire less_y = off_chip ?  y_nz_loc : y_lt_abs;

wire done = done_x & done_y;

wire is_fn = (final_bits == `FINAL_NORTH);
wire is_fs = (final_bits == `FINAL_SOUTH);
wire is_fe = (final_bits == `FINAL_EAST);
wire is_fw = (final_bits == `FINAL_WEST);
wire is_fp = ~(is_fn | is_fs | is_fe | is_fw);

wire north = (done_x & less_y) | (done & is_fn);
wire south = (done_x & more_y) | (done & is_fs);
wire east  = more_x            | (done & is_fe);
wire west  = less_x            | (done & is_fw);
wire proc  = done & is_fp;

assign route_req_n = header_in & north;
assign route_req_e = header_in & east;
assign route_req_s = header_in & south;
assign route_req_w = header_in & west;
assign route_req_p = header_in & proc;

assign default_ready_n = route_req_n;
assign default_ready_e = route_req_e;
assign default_ready_s = route_req_s;
assign default_ready_w = route_req_w;
assign default_ready_p = route_req_p;

endmodule
