// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
//======================================================================
//
// hmac_ctrl.sv
// --------
// HMAC controller for the AHB-Lite interface.
//
//======================================================================

`include "caliptra_macros.svh"
`include "kv_macros.svh"

module hmac_ctrl
    import kv_defines_pkg::*;
    #(
    parameter AHB_DATA_WIDTH = 32,
    parameter AHB_ADDR_WIDTH = 32
)
(
    // Clock and reset.
    input wire           clk,
    input wire           reset_n,
    input wire           cptra_pwrgood,

    // CSR key
    input logic [`CLP_CSR_HMAC_KEY_DWORDS-1:0][31:0] cptra_csr_hmac_key,

    // From SLAVE PORT
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

    // KV interface
    output kv_read_t [1:0] kv_read,
    output kv_write_t kv_write,
    input kv_rd_resp_t [1:0] kv_rd_resp,
    input kv_wr_resp_t kv_wr_resp,

    output logic busy_o,

    // Interrupt
    output logic error_intr,
    output logic notif_intr,
    input  logic ocp_lock_in_progress,
    input  logic debugUnlock_or_scan_mode_switch
);

    localparam logic [2:0] AHB_SIZE_WORD = 3'b010;

    logic                         raw_hmac_cs;
    logic                         raw_hmac_we;
    logic                         hmac_cs;
    logic                         hmac_we;
    logic [AHB_ADDR_WIDTH-1 : 0]  hmac_address;
    logic [31 : 0]                hmac_write_data;
    logic [31 : 0]                hmac_read_data;
    logic [31 : 0]                sif_rdata;

    logic                         ahb_active_transfer;
    logic                         ahb_malformed_addr_phase;
    logic                         ahb_malformed_q;
    logic                         ahb_err;
    logic                         debug_or_scan_lock_q;
    logic                         bus_isolate;

    logic [`CLP_CSR_HMAC_KEY_DWORDS-1:0][31:0] csr_hmac_key_masked;

    always_comb begin
        ahb_active_transfer      = hsel_i && hready_i && (htrans_i inside {2'b10, 2'b11});
        ahb_malformed_addr_phase = ahb_active_transfer &&
                                   ((hsize_i != AHB_SIZE_WORD) || (haddr_i[1:0] != 2'b00));
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ahb_malformed_q      <= 1'b0;
            debug_or_scan_lock_q <= 1'b0;
        end
        else if (hready_i) begin
            ahb_malformed_q      <= ahb_malformed_addr_phase;
            debug_or_scan_lock_q <= ahb_active_transfer && debugUnlock_or_scan_mode_switch;
        end
        else if (raw_hmac_cs) begin
            ahb_malformed_q      <= 1'b0;
            debug_or_scan_lock_q <= 1'b0;
        end
    end

    always_comb begin
        ahb_err             = raw_hmac_cs && ahb_malformed_q;
        bus_isolate         = ahb_malformed_q || debugUnlock_or_scan_mode_switch || debug_or_scan_lock_q;
        hmac_cs             = raw_hmac_cs && !bus_isolate;
        hmac_we             = raw_hmac_we && !bus_isolate;
        sif_rdata           = bus_isolate ? 32'h0 : hmac_read_data;
        csr_hmac_key_masked = debugUnlock_or_scan_mode_switch ? '0 : cptra_csr_hmac_key;
    end

    hmac #(
        .ADDR_WIDTH (AHB_ADDR_WIDTH),
        .DATA_WIDTH (32)
    ) hmac_inst (
        .clk(clk),
        .reset_n(reset_n),
        .cptra_pwrgood(cptra_pwrgood),
        .cptra_csr_hmac_key(csr_hmac_key_masked),
        .cs(hmac_cs),
        .we(hmac_we),
        .address(hmac_address),
        .write_data(hmac_write_data),
        .read_data(hmac_read_data),
        .kv_read(kv_read),
        .kv_write(kv_write),
        .kv_rd_resp(kv_rd_resp),
        .kv_wr_resp(kv_wr_resp),
        .error_intr(error_intr),
        .notif_intr(notif_intr),
        .busy_o(busy_o),
        .ocp_lock_in_progress(ocp_lock_in_progress),
        .debugUnlock_or_scan_mode_switch(debugUnlock_or_scan_mode_switch)
    );

    ahb_slv_sif #(
        .AHB_ADDR_WIDTH(AHB_ADDR_WIDTH),
        .AHB_DATA_WIDTH(AHB_DATA_WIDTH),
        .CLIENT_DATA_WIDTH(32)
    ) ahb_slv_sif_uut (
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

        .dv(raw_hmac_cs),
        .hld(1'b0),
        .err(ahb_err),
        .write(raw_hmac_we),
        .wdata(hmac_write_data),
        .addr(hmac_address),
        .rdata(sif_rdata)
    );

endmodule
