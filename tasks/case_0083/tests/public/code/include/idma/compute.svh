typedef enum logic [2:0] {
    COMPUTE_NONE           = 3'd0,
    COMPUTE_TRANSPOSE      = 3'd1,
    COMPUTE_MXQUANT        = 3'd2,
    COMPUTE_MXQUANT_FP16   = 3'd3,
    COMPUTE_MXDEQUANT      = 3'd4,
    COMPUTE_MXDEQUANT_FP16 = 3'd5
} compute_op_e;

localparam logic [7:0] ComputeOpValid = 8'h3f;

typedef enum logic [0:0] {
    MX_GROUP_G32 = 1'd0,
    MX_GROUP_G64 = 1'd1
} mx_group_e;
