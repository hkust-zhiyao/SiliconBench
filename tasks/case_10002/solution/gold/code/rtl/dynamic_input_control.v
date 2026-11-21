`include "network_define.v"
module dynamic_input_control(
    thanks_all_temp_out,
    route_req_n_out, route_req_e_out, route_req_s_out, route_req_w_out, route_req_p_out,
    default_ready_n, default_ready_e, default_ready_s, default_ready_w, default_ready_p,
    tail_out, clk, reset,
    my_loc_x_in, my_loc_y_in, my_chip_id_in,
    abs_x, abs_y, abs_chip_id, final_bits, valid_in,
    thanks_n, thanks_e, thanks_s, thanks_w, thanks_p,
    length
);

output thanks_all_temp_out;
output route_req_n_out;
output route_req_e_out;
output route_req_s_out;
output route_req_w_out;
output route_req_p_out;
output default_ready_n;
output default_ready_e;
output default_ready_s;
output default_ready_w;
output default_ready_p;
output tail_out;

input clk;
input reset;

input [`XY_WIDTH-1:0] my_loc_x_in;
input [`XY_WIDTH-1:0] my_loc_y_in;
input [`CHIP_ID_WIDTH-1:0] my_chip_id_in;
input [`XY_WIDTH-1:0] abs_x;
input [`XY_WIDTH-1:0] abs_y;
input [`CHIP_ID_WIDTH-1:0] abs_chip_id;
input [2:0] final_bits;
input valid_in;
input thanks_n;
input thanks_e;
input thanks_s;
input thanks_w;
input thanks_p;
input [`PAYLOAD_LEN-1:0] length;

reg [`PAYLOAD_LEN-1:0] rem_f;

wire thanks_all_temp = thanks_n | thanks_e | thanks_s | thanks_w | thanks_p;
wire is_header_phase = (rem_f == `PAYLOAD_LEN'd0);
wire header          = valid_in & is_header_phase;
wire length_zero     = (length == `PAYLOAD_LEN'd0);

assign thanks_all_temp_out = thanks_all_temp;
assign tail_out = is_header_phase ? (valid_in & length_zero) : (rem_f == `PAYLOAD_LEN'd1);

dynamic_input_route_request_calc tail_calc(
    .route_req_n(route_req_n_out),
    .route_req_e(route_req_e_out),
    .route_req_s(route_req_s_out),
    .route_req_w(route_req_w_out),
    .route_req_p(route_req_p_out),
    .default_ready_n(default_ready_n),
    .default_ready_e(default_ready_e),
    .default_ready_s(default_ready_s),
    .default_ready_w(default_ready_w),
    .default_ready_p(default_ready_p),
    .my_loc_x_in(my_loc_x_in),
    .my_loc_y_in(my_loc_y_in),
    .my_chip_id_in(my_chip_id_in),
    .abs_x(abs_x),
    .abs_y(abs_y),
    .abs_chip_id(abs_chip_id),
    .final_bits(final_bits),
    .length(length),
    .header_in(header)
);

always @(posedge clk) begin
    if (reset) begin
        rem_f <= `PAYLOAD_LEN'd0;
    end else if (thanks_all_temp) begin
        rem_f <= is_header_phase ? length : (rem_f - `PAYLOAD_LEN'd1);
    end
end

endmodule
