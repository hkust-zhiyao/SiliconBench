module idma_legalizer_page_splitter #(
    parameter int unsigned BurstLen      = 4'd8,
    parameter int unsigned OffsetWidth   = 32'd2,
    parameter int unsigned PageAddrWidth = 32'd5,
    parameter type         addr_t        = logic,
    parameter type         page_len_t    = logic,
    parameter type         page_addr_t   = logic
) (
    input  addr_t      addr_i,
    input  logic       not_bursting_i,
    input  logic       reduce_len_i,
    input  logic [2:0] max_llen_i,
    output page_len_t  num_bytes_to_pb_o
);
    logic [3:0] page_addr_width;
    page_len_t  page_size;
    page_addr_t page_offset;

    always_comb begin : proc_addr_width
        if (not_bursting_i) begin
            page_addr_width = OffsetWidth[3:0];
        end else begin
            logic [3:0] raw_w;
            raw_w = OffsetWidth[3:0] + (reduce_len_i ? {1'b0, max_llen_i} : BurstLen[3:0]);
            page_addr_width = (raw_w > 4'd12) ? 4'd12 : raw_w;
        end
    end

    assign page_size   = page_len_t'(1) << page_addr_width;
    assign page_offset = addr_i[PageAddrWidth-1:0] & page_addr_t'(page_size - 1'b1);
    assign num_bytes_to_pb_o = page_size - page_len_t'(page_offset);
endmodule
