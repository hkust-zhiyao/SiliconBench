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

`include "caliptra_macros.svh"
`include "kv_macros.svh"
`include "caliptra_prim_assert.sv"

module hmac
       import hmac_param_pkg::*;
       import hmac_reg_pkg::*;
       import kv_defines_pkg::*;
      #(
        ADDR_WIDTH = 32,
        DATA_WIDTH = 32
      )(
        input wire           clk,
        input wire           reset_n,
        input wire           cptra_pwrgood,

        input logic [`CLP_CSR_HMAC_KEY_DWORDS-1:0][31:0] cptra_csr_hmac_key,

        input wire           cs,
        input wire           we,

        input wire  [ADDR_WIDTH - 1 : 0] address,
        input wire  [DATA_WIDTH - 1 : 0] write_data,
        output wire [DATA_WIDTH - 1 : 0] read_data,

        output kv_read_t [1:0] kv_read,
        output kv_write_t kv_write,
        input kv_rd_resp_t [1:0] kv_rd_resp,
        input kv_wr_resp_t kv_wr_resp,

        output logic busy_o,

        output wire error_intr,
        output wire notif_intr,
        input logic ocp_lock_in_progress,
        input logic debugUnlock_or_scan_mode_switch
      );

  localparam int BLOCK_NUM_DWORDS = BLOCK_SIZE / DATA_WIDTH;
  localparam int KEY_NUM_DWORDS   = KEY_SIZE / DATA_WIDTH;
  localparam int TAG_NUM_DWORDS   = TAG_SIZE / DATA_WIDTH;
  localparam int SEED_NUM_DWORDS  = ((LFSR_SEED_SIZE - 1) / DATA_WIDTH) + 1;

  typedef struct packed {
    logic key_active;
    logic blk_active;
    logic wr_active;
    logic hide_tag;
  } kv_activity_t;

  logic init_reg, next_reg, last_reg, mode_reg;
  logic ready_reg, tag_valid_reg;
  logic sanitize_now;

  logic [KEY_NUM_DWORDS - 1   : 0][DATA_WIDTH - 1 : 0] key_reg;
  logic [BLOCK_NUM_DWORDS - 1 : 0][DATA_WIDTH - 1 : 0] block_reg;
  logic [SEED_NUM_DWORDS - 1  : 0][DATA_WIDTH - 1 : 0] lfsr_seed_reg;
  logic [SEED_NUM_DWORDS - 1  : 0][DATA_WIDTH - 1 : 0] seed_mirror_q;
  logic                                                csr_key_sel_q;

  wire [KEY_SIZE-1 : 0]         core_key;
  wire [BLOCK_SIZE-1 : 0]       core_block;
  wire                          core_ready;
  wire [TAG_SIZE-1 : 0]         core_tag;
  wire                          core_tag_valid;
  wire [LFSR_SEED_SIZE-1 : 0]   core_lfsr_seed;
  logic [TAG_NUM_DWORDS - 1 : 0][DATA_WIDTH - 1 : 0] tag_reg;
  logic [TAG_NUM_DWORDS - 1 : 0][DATA_WIDTH - 1 : 0] kv_reg;
  logic [TAG_NUM_DWORDS - 1 : 0][DATA_WIDTH - 1 : 0] get_mask;

  hmac_reg__in_t  hwif_in;
  hmac_reg__out_t hwif_out;

  logic        kv_key_write_en;
  logic [3:0]  kv_key_write_offset;
  logic [31:0] kv_key_write_data;
  logic        kv_block_write_en;
  logic [4:0]  kv_block_write_offset;
  logic [31:0] kv_block_write_data;

  logic                        kv_key_data_present, kv_key_data_present_set;
  logic [BLOCK_NUM_DWORDS-1:0] block_reg_lock, block_reg_lock_nxt;
  logic                        kv_block_data_present, kv_block_data_present_set;
  logic                        kv_data_present, kv_data_present_reset;

  logic                       dest_keyvault;
  kv_error_code_e             kv_key_error, kv_block_error, kv_write_error;
  logic                       kv_key_ready, kv_key_done;
  logic                       kv_block_ready, kv_block_done;
  logic                       kv_write_ready, kv_write_done;
  logic [KV_ENTRY_SIZE_W-1:0] hmac_expected_key_size;

  kv_read_ctrl_reg_t        kv_key_read_ctrl_reg;
  kv_read_ctrl_reg_t        kv_block_read_ctrl_reg;
  kv_write_ctrl_reg_t       kv_write_ctrl_reg;
  kv_read_filter_metrics_t  kv_key_read_metrics;
  kv_read_filter_metrics_t  kv_block_read_metrics;
  kv_write_filter_metrics_t kv_write_metrics;
  kv_activity_t             kv_act;

  logic core_tag_we;
  logic engine_can_launch;
  logic launch_attempt;
  logic ctrl_wr_permitted;
  logic csr_mode_wr_permitted;

  logic key_zero_error, key_zero_error_reg, key_zero_error_edge;
  logic key_mode_error, key_mode_error_reg, key_mode_error_edge;
  logic last_alone_error, last_alone_error_reg, last_alone_error_edge;
  logic error_flag, error_flag_reg, error_flag_edge;

  assign core_block = {block_reg[00], block_reg[01], block_reg[02], block_reg[03],
                       block_reg[04], block_reg[05], block_reg[06], block_reg[07],
                       block_reg[08], block_reg[09], block_reg[10], block_reg[11],
                       block_reg[12], block_reg[13], block_reg[14], block_reg[15],
                       block_reg[16], block_reg[17], block_reg[18], block_reg[19],
                       block_reg[20], block_reg[21], block_reg[22], block_reg[23],
                       block_reg[24], block_reg[25], block_reg[26], block_reg[27],
                       block_reg[28], block_reg[29], block_reg[30], block_reg[31]};

  assign core_key = {key_reg[00], key_reg[01], key_reg[02], key_reg[03], key_reg[04], key_reg[05],
                     key_reg[06], key_reg[07], key_reg[08], key_reg[09], key_reg[10], key_reg[11],
                     key_reg[12], key_reg[13], key_reg[14], key_reg[15]} & get_mask;

  assign core_lfsr_seed = {lfsr_seed_reg[00], lfsr_seed_reg[01], lfsr_seed_reg[02],
                           lfsr_seed_reg[03], lfsr_seed_reg[04], lfsr_seed_reg[05]};

  assign core_tag_we = (core_tag_valid & ~tag_valid_reg) & ~error_flag_reg;

  hmac_core core (
    .clk       (clk),
    .reset_n   (reset_n),
    .zeroize   (sanitize_now),
    .init_cmd  (init_reg),
    .next_cmd  (next_reg),
    .last_cmd  (last_reg),
    .mode_cmd  (mode_reg),
    .lfsr_seed (core_lfsr_seed),
    .key       (core_key),
    .block_msg (core_block),
    .ready     (core_ready),
    .tag       (core_tag),
    .tag_valid (core_tag_valid)
  );

  always_comb begin
    sanitize_now             = hwif_out.HMAC512_CTRL.ZEROIZE.value | debugUnlock_or_scan_mode_switch;
    kv_act.key_active        = kv_key_read_ctrl_reg.read_en | ~kv_key_ready;
    kv_act.blk_active        = kv_block_read_ctrl_reg.read_en | ~kv_block_ready;
    kv_act.wr_active         = ~kv_write_ready | (core_tag_we & dest_keyvault);
    kv_act.hide_tag          = dest_keyvault | ~kv_write_ready;

    engine_can_launch        = core_ready & ~kv_act.key_active & ~kv_act.blk_active & ~kv_act.wr_active & ~sanitize_now;
    launch_attempt           = (hwif_out.HMAC512_CTRL.INIT.value | hwif_out.HMAC512_CTRL.NEXT.value) & engine_can_launch;

    mode_reg                 = hwif_out.HMAC512_CTRL.MODE.value;
    init_reg                 = hwif_out.HMAC512_CTRL.INIT.value & engine_can_launch & ~(error_flag | error_flag_reg | last_alone_error);
    next_reg                 = hwif_out.HMAC512_CTRL.NEXT.value & engine_can_launch & ~(error_flag | error_flag_reg | last_alone_error);
    last_reg                 = hwif_out.HMAC512_CTRL.LAST.value & (init_reg | next_reg);

    busy_o                   = ~core_ready | kv_act.key_active | kv_act.blk_active | kv_act.wr_active | init_reg | next_reg;
    ctrl_wr_permitted        = ready_reg & ~busy_o & ~sanitize_now;
    csr_mode_wr_permitted    = ctrl_wr_permitted & ~kv_key_data_present & ~kv_key_read_ctrl_reg.read_en;
  end

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      csr_key_sel_q         <= 1'b0;
      seed_mirror_q         <= '0;
      kv_reg                <= '0;
      tag_reg               <= '0;
      tag_valid_reg         <= 1'b0;
      ready_reg             <= 1'b0;
      block_reg_lock        <= '0;
      kv_key_data_present   <= 1'b0;
      kv_block_data_present <= 1'b0;
    end
    else if (sanitize_now) begin
      csr_key_sel_q         <= 1'b0;
      seed_mirror_q         <= '0;
      kv_reg                <= '0;
      tag_reg               <= '0;
      tag_valid_reg         <= 1'b0;
      ready_reg             <= 1'b0;
      block_reg_lock        <= '0;
      kv_key_data_present   <= 1'b0;
      kv_block_data_present <= 1'b0;
    end
    else begin
      tag_valid_reg <= core_tag_valid & ~error_flag_reg;
      ready_reg     <= ~busy_o;

      if (kv_act.hide_tag) begin
        tag_reg <= '0;
      end
      else if (core_tag_we) begin
        tag_reg <= core_tag & get_mask;
      end

      if (core_tag_we && (dest_keyvault || kv_data_present)) begin
        kv_reg <= core_tag & get_mask;
      end

      block_reg_lock        <= block_reg_lock_nxt;
      kv_key_data_present   <= kv_key_data_present_set ? 1'b1 : (kv_data_present_reset ? 1'b0 : kv_key_data_present);
      kv_block_data_present <= kv_block_data_present_set ? 1'b1 : (kv_data_present_reset ? 1'b0 : kv_block_data_present);

      if (kv_key_read_ctrl_reg.read_en || kv_key_data_present ||
          (cs && we && (address[HMAC_REG_ADDR_WIDTH-1:0] == 12'h010) && write_data[2])) begin
        csr_key_sel_q <= 1'b0;
      end
      else if (cs && we && (address[HMAC_REG_ADDR_WIDTH-1:0] == 12'h010) && csr_mode_wr_permitted) begin
        csr_key_sel_q <= write_data[4];
      end

      if (cs && we && !busy_o) begin
        for (int idx = 0; idx < SEED_NUM_DWORDS; idx++) begin
          if (address[HMAC_REG_ADDR_WIDTH-1:0] == (12'h140 + 12'(idx * 4))) begin
            seed_mirror_q[idx] <= write_data;
          end
        end
      end
    end
  end

  always_comb begin
    automatic logic eff_csr_mode;
    automatic logic flush_stale_key;
    automatic logic flush_stale_blk;

    eff_csr_mode    = csr_key_sel_q & ~kv_key_data_present & ~kv_key_read_ctrl_reg.read_en & ~sanitize_now;
    flush_stale_key = kv_key_read_ctrl_reg.read_en & ~kv_key_data_present;
    flush_stale_blk = kv_block_read_ctrl_reg.read_en & ~kv_block_data_present;

    hwif_in.error_reset_b = cptra_pwrgood;
    hwif_in.reset_b       = reset_n;

    hwif_in.HMAC512_NAME[0].NAME.next       = HMAC_CORE_NAME[31:0];
    hwif_in.HMAC512_NAME[1].NAME.next       = HMAC_CORE_NAME[63:32];
    hwif_in.HMAC512_VERSION[0].VERSION.next = HMAC_CORE_VERSION[31:0];
    hwif_in.HMAC512_VERSION[1].VERSION.next = HMAC_CORE_VERSION[63:32];

    hwif_in.HMAC512_CTRL.CSR_MODE.swwe = csr_mode_wr_permitted;
    hwif_in.HMAC512_CTRL.INIT.swwe     = ctrl_wr_permitted;
    hwif_in.HMAC512_CTRL.NEXT.swwe     = ctrl_wr_permitted;
    hwif_in.HMAC512_CTRL.LAST.swwe     = ctrl_wr_permitted;
    hwif_in.HMAC512_CTRL.MODE.swwe     = ctrl_wr_permitted;

    hwif_in.HMAC512_STATUS.READY.next = ready_reg & ~busy_o & ~sanitize_now;
    hwif_in.HMAC512_STATUS.VALID.next = tag_valid_reg & ~sanitize_now;

    for (int dword = 0; dword < TAG_NUM_DWORDS; dword++) begin
      hwif_in.HMAC512_TAG[dword].TAG.next  = kv_act.hide_tag ? 32'h0 : tag_reg[(TAG_NUM_DWORDS - 1) - dword];
      hwif_in.HMAC512_TAG[dword].TAG.hwclr = sanitize_now | kv_act.hide_tag;
    end

    for (int dword = 0; dword < BLOCK_NUM_DWORDS; dword++) begin
      hwif_in.HMAC512_BLOCK[dword].BLOCK.we    = kv_block_write_en && (kv_block_write_offset == 5'(dword)) && !sanitize_now && !kv_data_present_reset;
      hwif_in.HMAC512_BLOCK[dword].BLOCK.next  = kv_block_write_data;
      hwif_in.HMAC512_BLOCK[dword].BLOCK.hwclr = sanitize_now | kv_data_present_reset | flush_stale_blk | (kv_block_error != KV_SUCCESS);
      hwif_in.HMAC512_BLOCK[dword].BLOCK.swwel = sanitize_now | busy_o | kv_block_read_ctrl_reg.read_en | kv_block_data_present | block_reg_lock[dword];
    end

    for (int dword = 0; dword < KEY_NUM_DWORDS; dword++) begin
      hwif_in.HMAC512_KEY[dword].KEY.we    = kv_key_write_en && (kv_key_write_offset == 4'(dword)) && !sanitize_now && !kv_data_present_reset;
      hwif_in.HMAC512_KEY[dword].KEY.next  = kv_key_write_data;
      hwif_in.HMAC512_KEY[dword].KEY.hwclr = sanitize_now | kv_data_present_reset | flush_stale_key | (kv_key_error != KV_SUCCESS);
      hwif_in.HMAC512_KEY[dword].KEY.swwel = sanitize_now | busy_o | kv_key_read_ctrl_reg.read_en | kv_key_data_present;
    end

    hwif_in.HMAC512_KV_RD_KEY_STATUS.READY.next   = ~kv_act.key_active;
    hwif_in.HMAC512_KV_RD_BLOCK_STATUS.READY.next = ~kv_act.blk_active;
    hwif_in.HMAC512_KV_WR_STATUS.READY.next       = ~kv_act.wr_active;

    hwif_in.HMAC512_KV_RD_KEY_STATUS.ERROR.next   = kv_key_error;
    hwif_in.HMAC512_KV_RD_BLOCK_STATUS.ERROR.next = kv_block_error;
    hwif_in.HMAC512_KV_WR_STATUS.ERROR.next       = kv_write_error;

    hwif_in.HMAC512_KV_RD_KEY_STATUS.VALID.hwset   = kv_key_done & ~sanitize_now;
    hwif_in.HMAC512_KV_RD_BLOCK_STATUS.VALID.hwset = kv_block_done & ~sanitize_now;
    hwif_in.HMAC512_KV_WR_STATUS.VALID.hwset       = kv_write_done & ~sanitize_now;

    hwif_in.HMAC512_KV_RD_KEY_STATUS.VALID.hwclr   = kv_key_read_ctrl_reg.read_en | sanitize_now;
    hwif_in.HMAC512_KV_RD_BLOCK_STATUS.VALID.hwclr = kv_block_read_ctrl_reg.read_en | sanitize_now;
    hwif_in.HMAC512_KV_WR_STATUS.VALID.hwclr       = kv_write_ctrl_reg.write_en | sanitize_now;

    hwif_in.HMAC512_KV_RD_KEY_CTRL.read_en.hwclr   = ~kv_key_ready | sanitize_now;
    hwif_in.HMAC512_KV_RD_BLOCK_CTRL.read_en.hwclr = ~kv_block_ready | sanitize_now;
    hwif_in.HMAC512_KV_WR_CTRL.write_en.hwclr      = ~kv_write_ready | sanitize_now;

    for (int dword = 0; dword < KEY_NUM_DWORDS; dword++) begin
      key_reg[dword] = sanitize_now ? 32'h0 : (eff_csr_mode ? cptra_csr_hmac_key[dword] : hwif_out.HMAC512_KEY[dword].KEY.value);
    end
    for (int dword = 0; dword < BLOCK_NUM_DWORDS; dword++) begin
      block_reg[dword] = sanitize_now ? 32'h0 : hwif_out.HMAC512_BLOCK[dword].BLOCK.value;
    end
    for (int dword = 0; dword < SEED_NUM_DWORDS; dword++) begin
      lfsr_seed_reg[dword] = sanitize_now ? 32'h0 : seed_mirror_q[dword];
    end
  end

  assign get_mask = (mode_reg == 1'b0) ? {{(HMAC384_TAG_SIZE/DATA_WIDTH){{DATA_WIDTH{1'b1}}}},
                                          {(HMAC384_TAG_PAD /DATA_WIDTH){{DATA_WIDTH{1'b0}}}}}
                                       : {TAG_NUM_DWORDS{{DATA_WIDTH{1'b1}}}};

  always_comb begin
    for (int dword = 0; dword < BLOCK_NUM_DWORDS; dword++) begin
      if (kv_data_present_reset || (kv_block_error != KV_SUCCESS)) begin
        block_reg_lock_nxt[dword] = 1'b0;
      end
      else begin
        block_reg_lock_nxt[dword] = block_reg_lock[dword] | (kv_block_write_en & (kv_block_write_offset == 5'(dword)));
      end
    end
  end

  always_comb begin
    hwif_in.HMAC512_KV_RD_KEY_CTRL.read_en.swwe         = !kv_key_data_present && !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_RD_KEY_CTRL.read_entry.swwe      = !kv_key_data_present && !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_RD_KEY_CTRL.pcr_hash_extend.swwe = 1'b0;
    hwif_in.HMAC512_KV_RD_KEY_CTRL.rsvd.swwe            = 1'b0;

    hwif_in.HMAC512_KV_RD_BLOCK_CTRL.read_en.swwe         = !kv_block_data_present && !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_RD_BLOCK_CTRL.read_entry.swwe      = !kv_block_data_present && !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_RD_BLOCK_CTRL.pcr_hash_extend.swwe = 1'b0;
    hwif_in.HMAC512_KV_RD_BLOCK_CTRL.rsvd.swwe            = 1'b0;

    hwif_in.HMAC512_KV_WR_CTRL.write_en.swwe              = !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_WR_CTRL.write_entry.swwe           = !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_WR_CTRL.hmac_key_dest_valid.swwe   = !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_WR_CTRL.hmac_block_dest_valid.swwe = !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_WR_CTRL.mldsa_seed_dest_valid.swwe = !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_WR_CTRL.ecc_pkey_dest_valid.swwe   = !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_WR_CTRL.ecc_seed_dest_valid.swwe   = !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_WR_CTRL.aes_key_dest_valid.swwe    = !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_WR_CTRL.mlkem_seed_dest_valid.swwe = !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_WR_CTRL.mlkem_msg_dest_valid.swwe  = !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_WR_CTRL.dma_data_dest_valid.swwe   = !busy_o && !sanitize_now;
    hwif_in.HMAC512_KV_WR_CTRL.rsvd.swwe                  = 1'b0;
  end

  `CALIPTRA_KV_READ_CTRL_REG2STRUCT(kv_key_read_ctrl_reg, HMAC512_KV_RD_KEY_CTRL)
  `CALIPTRA_KV_READ_CTRL_REG2STRUCT(kv_block_read_ctrl_reg, HMAC512_KV_RD_BLOCK_CTRL)
  `CALIPTRA_KV_WRITE_CTRL_REG2STRUCT(kv_write_ctrl_reg, HMAC512_KV_WR_CTRL)

  assign kv_key_data_present_set   = kv_key_read_ctrl_reg.read_en;
  assign kv_block_data_present_set = kv_block_read_ctrl_reg.read_en;
  assign kv_data_present           = kv_key_data_present | kv_block_data_present;
  assign kv_data_present_reset     = kv_data_present & core_tag_we;

  hmac_reg i_hmac_reg (
      .clk(clk),
      .rst(1'b0),

      .s_cpuif_req         (cs),
      .s_cpuif_req_is_wr   (we),
      .s_cpuif_addr        (address[HMAC_REG_ADDR_WIDTH-1:0]),
      .s_cpuif_wr_data     (write_data),
      .s_cpuif_wr_biten    ('1),
      .s_cpuif_req_stall_wr(),
      .s_cpuif_req_stall_rd(),
      .s_cpuif_rd_ack      (),
      .s_cpuif_rd_err      (),
      .s_cpuif_rd_data     (read_data),
      .s_cpuif_wr_ack      (),
      .s_cpuif_wr_err      (),

      .hwif_in (hwif_in),
      .hwif_out(hwif_out)
  );

  assign key_mode_error   = kv_key_data_present & launch_attempt & (mode_reg == HMAC512_MODE) & (key_reg[KEY_NUM_DWORDS-1 : HMAC384_KEY_SIZE/DATA_WIDTH] == '0);
  assign key_zero_error   = kv_key_data_present & launch_attempt & (key_reg == '0);
  assign last_alone_error = hwif_out.HMAC512_CTRL.LAST.value & ~hwif_out.HMAC512_CTRL.INIT.value & ~hwif_out.HMAC512_CTRL.NEXT.value;
  assign error_flag       = key_zero_error | key_mode_error | (kv_key_error == KV_RD_LEN_MISMATCH);

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      error_flag_reg       <= 1'b0;
      key_mode_error_reg   <= 1'b0;
      key_zero_error_reg   <= 1'b0;
      last_alone_error_reg <= 1'b0;
    end
    else if (sanitize_now) begin
      error_flag_reg       <= 1'b0;
      key_mode_error_reg   <= 1'b0;
      key_zero_error_reg   <= 1'b0;
      last_alone_error_reg <= 1'b0;
    end
    else begin
      if (error_flag)
        error_flag_reg <= 1'b1;
      key_mode_error_reg   <= key_mode_error;
      key_zero_error_reg   <= key_zero_error;
      last_alone_error_reg <= last_alone_error;
    end
  end

  assign error_flag_edge       = error_flag & ~error_flag_reg;
  assign key_mode_error_edge   = key_mode_error & ~key_mode_error_reg;
  assign key_zero_error_edge   = key_zero_error & ~key_zero_error_reg;
  assign last_alone_error_edge = last_alone_error & ~last_alone_error_reg;

  assign hwif_in.intr_block_rf.notif_internal_intr_r.notif_cmd_done_sts.hwset = core_tag_we;
  assign hwif_in.intr_block_rf.error_internal_intr_r.key_mode_error_sts.hwset = key_mode_error_edge;
  assign hwif_in.intr_block_rf.error_internal_intr_r.key_zero_error_sts.hwset = key_zero_error_edge;
  assign hwif_in.intr_block_rf.error_internal_intr_r.error2_sts.hwset         = last_alone_error_edge;
  assign hwif_in.intr_block_rf.error_internal_intr_r.error3_sts.hwset         = 1'b0;

  assign error_intr = hwif_out.intr_block_rf.error_global_intr_r.intr;
  assign notif_intr = hwif_out.intr_block_rf.notif_global_intr_r.intr;

  always_comb begin
    kv_key_read_metrics.ocp_lock_in_progress = ocp_lock_in_progress;
    kv_key_read_metrics.kv_read_dest         = KV_NUM_READ'(1<<KV_DEST_IDX_HMAC_KEY);
    kv_key_read_metrics.kv_key_entry         = kv_key_read_ctrl_reg.read_entry;
  end

  assign hmac_expected_key_size = (mode_reg == HMAC512_MODE) ? KV_ENTRY_SIZE_W'(HMAC512_KV_LAST_DWORD)
                                                             : KV_ENTRY_SIZE_W'(HMAC384_KV_LAST_DWORD);

  kv_read_client #(
    .DATA_WIDTH(KEY_SIZE),
    .PAD(0),
    .LEN_CHECK_AT_KEY_USE(1)
  ) hmac_key_kv_read (
    .clk              (clk),
    .rst_b            (reset_n),
    .zeroize          (sanitize_now),
    .read_ctrl_reg    (kv_key_read_ctrl_reg),
    .read_metrics     (kv_key_read_metrics),
    .kv_read          (kv_read[0]),
    .kv_resp          (kv_rd_resp[0]),
    .write_en         (kv_key_write_en),
    .write_offset     (kv_key_write_offset),
    .write_data       (kv_key_write_data),
    .error_code       (kv_key_error),
    .kv_ready         (kv_key_ready),
    .read_done        (kv_key_done),
    .check_key_size   (launch_attempt & kv_key_data_present),
    .expected_key_size(hmac_expected_key_size)
  );

  always_comb begin
    kv_block_read_metrics.ocp_lock_in_progress = ocp_lock_in_progress;
    kv_block_read_metrics.kv_read_dest         = KV_NUM_READ'(1<<KV_DEST_IDX_HMAC_BLOCK);
    kv_block_read_metrics.kv_key_entry         = kv_block_read_ctrl_reg.read_entry;
  end

  kv_read_client #(
    .DATA_WIDTH(BLOCK_SIZE),
    .HMAC(1),
    .PAD(1),
    .LEN_CHECK(0)
  ) hmac_block_kv_read (
    .clk              (clk),
    .rst_b            (reset_n),
    .zeroize          (sanitize_now),
    .read_ctrl_reg    (kv_block_read_ctrl_reg),
    .read_metrics     (kv_block_read_metrics),
    .kv_read          (kv_read[1]),
    .kv_resp          (kv_rd_resp[1]),
    .write_en         (kv_block_write_en),
    .write_offset     (kv_block_write_offset),
    .write_data       (kv_block_write_data),
    .error_code       (kv_block_error),
    .kv_ready         (kv_block_ready),
    .read_done        (kv_block_done),
    .check_key_size   (1'b0),
    .expected_key_size('0)
  );

  logic [$clog2(TAG_SIZE/32):0] num_dwords;
  assign num_dwords = mode_reg ? 'd16 : 'd12;

  always_comb begin
    kv_write_metrics.ocp_lock_in_progress = ocp_lock_in_progress;
    kv_write_metrics.kv_data0_present     = kv_key_data_present;
    kv_write_metrics.kv_data0_entry       = kv_key_read_ctrl_reg.read_entry;
    kv_write_metrics.kv_data1_present     = kv_block_data_present;
    kv_write_metrics.kv_data1_entry       = kv_block_read_ctrl_reg.read_entry;
    kv_write_metrics.kv_write_src         = KV_NUM_WRITE'(1 << KV_WRITE_IDX_HMAC);
    kv_write_metrics.kv_write_entry       = kv_write_ctrl_reg.write_entry;
    kv_write_metrics.aes_decrypt_ecb_op   = 1'b0;
  end

  kv_write_client #(
    .DATA_WIDTH(TAG_SIZE)
  ) hmac_result_kv_write (
    .clk            (clk),
    .rst_b          (reset_n),
    .zeroize        (sanitize_now),
    .write_ctrl_reg (kv_write_ctrl_reg),
    .write_metrics  (kv_write_metrics),
    .num_dwords     (num_dwords),
    .kv_write       (kv_write),
    .kv_resp        (kv_wr_resp),
    .dest_keyvault  (dest_keyvault),
    .dest_data_avail(core_tag_we),
    .dest_data      (kv_reg),
    .error_code     (kv_write_error),
    .kv_ready       (kv_write_ready),
    .dest_done      (kv_write_done)
  );

endmodule
