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

reg                    in_body_f;
reg [`PAYLOAD_LEN-1:0] flits_left_f;

wire thanks_all_temp = thanks_n | thanks_e | thanks_s | thanks_w | thanks_p;
wire header          = valid_in & ~in_body_f;
wire len_is_zero     = ~|length;
wire last_body_flit  = ~|flits_left_f[`PAYLOAD_LEN-1:1] & flits_left_f[0];

assign thanks_all_temp_out = thanks_all_temp;
assign tail_out            = in_body_f ? last_body_flit : (valid_in & len_is_zero);

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
        in_body_f    <= 1'b0;
        flits_left_f <= {`PAYLOAD_LEN{1'b0}};
    end else if (thanks_all_temp) begin
        if (!in_body_f) begin
            in_body_f    <= ~len_is_zero;
            flits_left_f <= length;
        end else begin
            in_body_f    <= ~last_body_flit;
            flits_left_f <= flits_left_f - `PAYLOAD_LEN'd1;
        end
    end
end

endmodule
