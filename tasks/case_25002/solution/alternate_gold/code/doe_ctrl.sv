// SPDX-License-Identifier: Apache-2.0
//
// Alternate reference implementation for Caliptra DOE AHB-Lite controller.
//
`include "caliptra_macros.svh"

module doe_ctrl
    import doe_defines_pkg::*;
    import kv_defines_pkg::*;
    #(
    parameter AHB_DATA_WIDTH = 32,
    parameter AHB_ADDR_WIDTH = 32,
    localparam TOTAL_OBF_KEY_BITS = `CLP_OBF_KEY_DWORDS * 32
)
(
    input wire          clk,
    input wire          reset_n,
    input wire          cptra_pwrgood,

    input logic [TOTAL_OBF_KEY_BITS-1:0] cptra_obf_key,

    input logic [`CLP_OBF_FE_DWORDS-1 :0][31:0] obf_field_entropy,
    input logic [`CLP_OBF_UDS_DWORDS-1:0][31:0] obf_uds_seed,
    input logic [OCP_LOCK_HEK_NUM_DWORDS-1:0][31:0] obf_hek_seed,

    input logic [AHB_ADDR_WIDTH-1:0] haddr_i,
    input logic [AHB_DATA_WIDTH-1:0] hwdata_i,
    input logic hsel_i,
    input logic hwrite_i,
    input logic hready_i,
    input logic [1:0] htrans_i,
    input logic [2:0] hsize_i,

    output logic hresp_o,
    output logic hreadyout_o,
    output logic [AHB_DATA_WIDTH-1:0] hrdata_o,
    output kv_write_t kv_write,
    input  kv_wr_resp_t kv_wr_resp,

    output logic clear_obf_secrets,
    output logic busy_o,

    output logic error_intr,
    output logic notif_intr,
    output logic doe_fsm_error,
    input  logic ocp_lock_en,
    input  logic doe_cmd_lock,
    input  logic debugUnlock_or_scan_mode_switch
);

    logic doe_cs;
    logic doe_we;
    logic [AHB_ADDR_WIDTH-1:0] doe_address;
    logic [AHB_DATA_WIDTH-1:0] doe_write_data;
    logic [AHB_DATA_WIDTH-1:0] doe_read_data;

    function automatic logic csr_write_permitted(
        input logic [11:0] local_addr,
        input logic [31:0] wdata,
        input logic        cmd_locked,
        input logic        fsm_fault,
        input logic        engine_busy
    );
        logic hit_iv;
        logic hit_ctrl;
        logic cmd_is_clear;

        hit_iv       = (local_addr[11:4] == 8'h00) && (local_addr[1:0] == 2'b00);
        hit_ctrl     = (local_addr == 12'h010);
        cmd_is_clear = ({wdata[8:7], wdata[1:0]} == 4'(DOE_CLEAR));

        if (!hit_iv && !hit_ctrl) begin
            return 1'b1;
        end
        if (cmd_locked || fsm_fault) begin
            return 1'b0;
        end
        if (engine_busy) begin
            return (hit_ctrl && cmd_is_clear);
        end
        return 1'b1;
    endfunction

    logic doe_we_filtered;
    logic fault_or_debug_zeroize;

    always_comb begin
        doe_we_filtered        = doe_we && csr_write_permitted(doe_address[11:0], doe_write_data[31:0], doe_cmd_lock, doe_fsm_error, busy_o);
        fault_or_debug_zeroize = debugUnlock_or_scan_mode_switch | doe_fsm_error;
    end

    doe_cbc #(
        .ADDR_WIDTH(AHB_ADDR_WIDTH),
        .DATA_WIDTH(32)
    ) doe_inst(
        .clk(clk),
        .reset_n(reset_n),
        .cptra_pwrgood(cptra_pwrgood),
        .cptra_obf_key(cptra_obf_key),
        .obf_uds_seed(obf_uds_seed),
        .obf_field_entropy(obf_field_entropy),
        .obf_hek_seed(obf_hek_seed),
        .cs(doe_cs),
        .we(doe_we_filtered),
        .address(doe_address),
        .write_data(doe_write_data[31:0]),
        .read_data(doe_read_data[31:0]),
        .error_intr(error_intr),
        .notif_intr(notif_intr),
        .doe_fsm_error(doe_fsm_error),
        .busy_o(busy_o),
        .clear_obf_secrets(clear_obf_secrets),
        .kv_write(kv_write),
        .kv_wr_resp(kv_wr_resp),
        .ocp_lock_en(ocp_lock_en),
        .doe_cmd_lock(doe_cmd_lock),
        .debugUnlock_or_scan_mode_switch(fault_or_debug_zeroize)
    );

    ahb_slv_sif #(
        .AHB_ADDR_WIDTH(AHB_ADDR_WIDTH),
        .AHB_DATA_WIDTH(AHB_DATA_WIDTH),
        .CLIENT_DATA_WIDTH(32)
    ) ahb_slv_sif_uut
    (
        .hclk(clk),
        .hreset_n(reset_n),
        .haddr_i(haddr_i),
        .hwdata_i(hwdata_i),
        .hsel_i(hsel_i),
        .hwrite_i(hwrite_i),
        .hready_i(hready_i),
        .htrans_i(htrans_i),
        .hsize_i(hsize_i),

        .hresp_o(hresp_o),
        .hreadyout_o(hreadyout_o),
        .hrdata_o(hrdata_o),

        .dv(doe_cs),
        .hld(1'b0),
        .err(1'b0),
        .write(doe_we),
        .wdata(doe_write_data[31:0]),
        .addr(doe_address),
        .rdata(doe_read_data[31:0])
    );

endmodule
