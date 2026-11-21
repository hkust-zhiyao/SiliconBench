#include "Vtb_verilator_top.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <random>
#include <string>
#include <vector>

namespace {

struct AwCmd {
    uint16_t aligned_addr;
    uint8_t len;
};

struct WBeat {
    uint64_t data;
    uint8_t strb;
    bool last;
};

struct BRespItem {
    uint8_t resp;
    int ready_cycle;
};

struct ArCmd {
    uint16_t aligned_addr;
    uint8_t len;
    std::vector<uint8_t> beat_rresps;
    int beat_gap;
};

struct StreamBeat {
    uint64_t data;
    uint8_t keep;
    bool last;
    uint8_t id;
    uint8_t dest;
    uint8_t user;
    int pre_stall;
    int pkt_id;
};

struct WrDescCmd {
    int port;
    uint16_t addr;
    uint32_t len;
    uint8_t tag;
};

struct RdDescCmd {
    int port;
    uint16_t addr;
    uint32_t len;
    uint8_t tag;
    uint8_t id;
    uint8_t dest;
    uint8_t user;
};

struct WrStatusEvent {
    int cycle;
    int port;
    uint32_t len;
    uint8_t tag;
    uint8_t id;
    uint8_t dest;
    uint8_t user;
    uint8_t error;
};

struct RdStatusEvent {
    int cycle;
    int port;
    uint8_t tag;
    uint8_t error;
};

struct RdFrame {
    std::vector<uint8_t> bytes;
    uint8_t id;
    uint8_t dest;
    uint8_t user;
};

class DmaHarness {
public:
    Vtb_verilator_top* dut;
    std::mt19937 rng;
    int cur_cycle = 0;
    int error_count = 0;

    uint8_t ram[65536];

    // AXI write slave state
    std::deque<AwCmd> aw_q;
    std::deque<WBeat> w_q;
    bool w_active = false;
    uint16_t cur_w_addr = 0;
    int cur_w_beat = 0;
    int cur_w_total = 0;
    std::deque<uint8_t> planned_bresp_q;
    std::deque<BRespItem> b_q;
    int forced_awready_low_cycles = 0;
    int forced_wready_low_cycles = 0;
    int bresp_delay_cycles = 0;
    bool random_backpressure = false;

    int total_aw_count = 0;
    int total_w_beats = 0;
    int total_ar_count = 0;
    int total_r_beats = 0;

    // AXI read slave state
    std::deque<ArCmd> ar_q;
    std::deque<std::pair<std::vector<uint8_t>, int>> planned_ar_rresp_q;
    bool r_active = false;
    ArCmd cur_ar{};
    int cur_r_idx = 0;
    int r_gap_rem = 0;

    // Descriptor queues per port
    std::deque<WrDescCmd> wr_desc_q[4];
    std::deque<RdDescCmd> rd_desc_q[4];
    bool wr_port_busy[4] = {false, false, false, false};
    bool rd_port_busy[4] = {false, false, false, false};
    WrDescCmd cur_wr_port[4]{};
    RdDescCmd cur_rd_port[4]{};

    // Write stream source queue
    std::deque<StreamBeat> wr_stream_q;
    bool wr_beat_valid = false;
    StreamBeat cur_wr_beat{};
    int wr_stall_rem = 0;
    int pkt_tlast_cycle[4096];

    // Captured read stream frames
    std::vector<uint8_t> cur_rd_bytes;
    std::deque<RdFrame> rd_frames;

    // Captured status events
    std::deque<WrStatusEvent> wr_status_q;
    std::deque<RdStatusEvent> rd_status_q;

    int wr_desc_stall_rem = 0;
    int rd_desc_stall_rem = 0;

    explicit DmaHarness(uint32_t seed) : rng(seed) {
        dut = new Vtb_verilator_top;
        std::memset(ram, 0xA5, sizeof(ram));
        for (int i = 0; i < 4096; ++i) pkt_tlast_cycle[i] = -1;
    }

    ~DmaHarness() {
        delete dut;
    }

    void fail(const char* fmt, ...) {
        if (error_count < 25) {
            va_list args;
            va_start(args, fmt);
            std::fprintf(stderr, "[Cycle %d] FAIL: ", cur_cycle);
            std::vfprintf(stderr, fmt, args);
            std::fprintf(stderr, "\n");
            va_end(args);
        }
        error_count++;
    }

    void set_wr_len_port(int p, uint32_t len) {
        uint32_t v = len & 0xFFFFFU;
        if (p == 0) dut->s_wr_desc_len_0 = v;
        else if (p == 1) dut->s_wr_desc_len_1 = v;
        else if (p == 2) dut->s_wr_desc_len_2 = v;
        else dut->s_wr_desc_len_3 = v;
    }

    void set_rd_len_port(int p, uint32_t len) {
        uint32_t v = len & 0xFFFFFU;
        if (p == 0) dut->s_rd_desc_len_0 = v;
        else if (p == 1) dut->s_rd_desc_len_1 = v;
        else if (p == 2) dut->s_rd_desc_len_2 = v;
        else dut->s_rd_desc_len_3 = v;
    }

    uint32_t get_wr_status_len_port(int p) const {
        if (p == 0) return dut->m_wr_status_len_0;
        if (p == 1) return dut->m_wr_status_len_1;
        if (p == 2) return dut->m_wr_status_len_2;
        return dut->m_wr_status_len_3;
    }

    void reset() {
        dut->clk = 0;
        dut->rst = 1;
        dut->read_enable = 1;
        dut->write_enable = 1;
        dut->rd_desc_stall = 0;
        dut->wr_desc_stall = 0;

        dut->s_rd_desc_addr = 0;
        dut->s_rd_desc_len_0 = dut->s_rd_desc_len_1 = dut->s_rd_desc_len_2 = dut->s_rd_desc_len_3 = 0;
        dut->s_rd_desc_tag = 0;
        dut->s_rd_desc_id = 0;
        dut->s_rd_desc_dest = 0;
        dut->s_rd_desc_user = 0;
        dut->s_rd_desc_valid = 0;

        dut->s_wr_desc_addr = 0;
        dut->s_wr_desc_len_0 = dut->s_wr_desc_len_1 = dut->s_wr_desc_len_2 = dut->s_wr_desc_len_3 = 0;
        dut->s_wr_desc_tag = 0;
        dut->s_wr_desc_valid = 0;

        dut->m_axis_read_data_tready = 1;
        dut->s_axis_write_data_tdata = 0;
        dut->s_axis_write_data_tkeep = 0;
        dut->s_axis_write_data_tvalid = 0;
        dut->s_axis_write_data_tlast = 0;
        dut->s_axis_write_data_tid = 0;
        dut->s_axis_write_data_tdest = 0;
        dut->s_axis_write_data_tuser = 0;

        dut->m_axi_awready = 1;
        dut->m_axi_wready = 1;
        dut->m_axi_bid = 0;
        dut->m_axi_bresp = 0;
        dut->m_axi_bvalid = 0;

        dut->m_axi_arready = 1;
        dut->m_axi_rid = 0;
        dut->m_axi_rdata = 0;
        dut->m_axi_rresp = 0;
        dut->m_axi_rlast = 0;
        dut->m_axi_rvalid = 0;

        for (int i = 0; i < 8; ++i) {
            dut->clk = 0;
            dut->eval();
            dut->clk = 1;
            dut->eval();
        }
        dut->rst = 0;
        for (int i = 0; i < 4; ++i) step();
    }

    void push_packet(const std::vector<uint8_t>& payload,
                     uint8_t mid_id, uint8_t mid_dest, uint8_t mid_user,
                     uint8_t last_id, uint8_t last_dest, uint8_t last_user,
                     int pkt_id, int last_beat_stall = 0) {
        if (payload.empty()) return;
        size_t num_beats = (payload.size() + 7) / 8;
        for (size_t b = 0; b < num_beats; ++b) {
            StreamBeat sb{};
            sb.data = 0;
            sb.keep = 0;
            sb.last = (b + 1 == num_beats);
            for (size_t k = 0; k < 8; ++k) {
                size_t idx = b * 8 + k;
                uint8_t byte_val = (idx < payload.size()) ? payload[idx] : uint8_t(0xEE);
                sb.data |= (uint64_t(byte_val) << (k * 8));
                if (idx < payload.size()) sb.keep |= (1U << k);
            }
            sb.id   = sb.last ? last_id   : mid_id;
            sb.dest = sb.last ? last_dest : mid_dest;
            sb.user = (sb.last ? last_user : mid_user) & 0xFU;
            sb.pre_stall = sb.last ? last_beat_stall : (random_backpressure && (rng() % 4 == 0) ? int(rng() % 3) : 0);
            sb.pkt_id = pkt_id;
            wr_stream_q.push_back(sb);
        }
    }

    void step() {
        dut->clk = 0;
        dut->eval();

        // -------------------------------------------------------------
        // 1. Sample handshakes on settled pre-posedge signals
        // -------------------------------------------------------------
        // AXI AW monitor
        bool aw_hs = dut->m_axi_awvalid && dut->m_axi_awready;
        if (dut->m_axi_awvalid) {
            if (dut->m_axi_awlen >= 16) {
                fail("AXI AWLEN %u >= AXI_MAX_BURST_LEN(16)", unsigned(dut->m_axi_awlen));
            }
            if (dut->m_axi_awsize != 3) {
                fail("AXI AWSIZE %u != 3", unsigned(dut->m_axi_awsize));
            }
            uint32_t aligned_start = uint32_t(dut->m_axi_awaddr) & ~7U;
            uint32_t aligned_end   = aligned_start + (uint32_t(dut->m_axi_awlen) << 3);
            if ((aligned_start >> 12) != (aligned_end >> 12)) {
                fail("AXI AW burst crossed 4KB boundary: awaddr=0x%04x awlen=%u (0x%04x..0x%04x)",
                     unsigned(dut->m_axi_awaddr), unsigned(dut->m_axi_awlen), aligned_start, aligned_end);
            }
        }
        if (aw_hs) {
            aw_q.push_back({uint16_t(dut->m_axi_awaddr & ~7U), uint8_t(dut->m_axi_awlen)});
            total_aw_count++;
        }

        // AXI W monitor (AXI4 allows W beats to handshake before AW; buffer in w_q and commit in order once AW is available)
        bool w_hs = dut->m_axi_wvalid && dut->m_axi_wready;
        if (w_hs) {
            w_q.push_back({uint64_t(dut->m_axi_wdata), uint8_t(dut->m_axi_wstrb), bool(dut->m_axi_wlast)});
            total_w_beats++;
        }
        while (!w_q.empty() && (w_active || !aw_q.empty())) {
            if (!w_active) {
                AwCmd c = aw_q.front();
                aw_q.pop_front();
                w_active = true;
                cur_w_addr = c.aligned_addr;
                cur_w_beat = 0;
                cur_w_total = int(c.len) + 1;
            }
            WBeat wb = w_q.front();
            w_q.pop_front();
            for (int k = 0; k < 8; ++k) {
                if ((wb.strb >> k) & 1U) {
                    ram[(cur_w_addr + k) & 0xFFFF] = uint8_t((wb.data >> (k * 8)) & 0xFFU);
                }
            }
            cur_w_addr = uint16_t(cur_w_addr + 8);
            cur_w_beat++;
            if (cur_w_beat == cur_w_total) {
                if (!wb.last) {
                    fail("Missing AXI WLAST on beat %d/%d", cur_w_beat, cur_w_total);
                }
                w_active = false;
                uint8_t resp = 0;
                if (!planned_bresp_q.empty()) {
                    resp = planned_bresp_q.front();
                    planned_bresp_q.pop_front();
                }
                int delay = bresp_delay_cycles;
                if (random_backpressure) delay += int(rng() % 4);
                b_q.push_back({resp, cur_cycle + 1 + delay});
            } else if (wb.last) {
                fail("Early AXI WLAST on beat %d/%d", cur_w_beat, cur_w_total);
                w_active = false;
            }
        }

        bool b_hs = dut->m_axi_bvalid && dut->m_axi_bready;

        // AXI AR monitor
        bool ar_hs = dut->m_axi_arvalid && dut->m_axi_arready;
        if (dut->m_axi_arvalid) {
            if (dut->m_axi_arlen >= 16) {
                fail("AXI ARLEN %u >= AXI_MAX_BURST_LEN(16)", unsigned(dut->m_axi_arlen));
            }
            if (dut->m_axi_arsize != 3) {
                fail("AXI ARSIZE %u != 3", unsigned(dut->m_axi_arsize));
            }
            uint32_t aligned_start = uint32_t(dut->m_axi_araddr) & ~7U;
            uint32_t aligned_end   = aligned_start + (uint32_t(dut->m_axi_arlen) << 3);
            if ((aligned_start >> 12) != (aligned_end >> 12)) {
                fail("AXI AR burst crossed 4KB boundary: araddr=0x%04x arlen=%u (0x%04x..0x%04x)",
                     unsigned(dut->m_axi_araddr), unsigned(dut->m_axi_arlen), aligned_start, aligned_end);
            }
        }
        if (ar_hs) {
            ArCmd c{};
            c.aligned_addr = uint16_t(dut->m_axi_araddr & ~7U);
            c.len = uint8_t(dut->m_axi_arlen);
            c.beat_gap = 0;
            if (!planned_ar_rresp_q.empty()) {
                c.beat_rresps = planned_ar_rresp_q.front().first;
                c.beat_gap    = planned_ar_rresp_q.front().second;
                planned_ar_rresp_q.pop_front();
            }
            ar_q.push_back(c);
            total_ar_count++;
        }

        bool r_hs = dut->m_axi_rvalid && dut->m_axi_rready;
        if (r_hs) {
            total_r_beats++;
        }

        // Write stream handshake
        bool wr_axis_hs = dut->s_axis_write_data_tvalid && dut->s_axis_write_data_tready;
        if (wr_axis_hs && cur_wr_beat.last && cur_wr_beat.pkt_id >= 0 && cur_wr_beat.pkt_id < 4096) {
            pkt_tlast_cycle[cur_wr_beat.pkt_id] = cur_cycle;
        }

        // Read stream monitor
        if (dut->m_axis_read_data_tvalid && dut->m_axis_read_data_tready) {
            uint8_t keep = dut->m_axis_read_data_tkeep;
            if (!dut->m_axis_read_data_tlast && keep != 0xFFU) {
                fail("Non-final read stream beat has partial tkeep=0x%02x", unsigned(keep));
            }
            for (int k = 0; k < 8; ++k) {
                if ((keep >> k) & 1U) {
                    cur_rd_bytes.push_back(uint8_t((dut->m_axis_read_data_tdata >> (k * 8)) & 0xFFU));
                }
            }
            if (dut->m_axis_read_data_tlast) {
                RdFrame f{};
                f.bytes = std::move(cur_rd_bytes);
                cur_rd_bytes.clear();
                f.id = dut->m_axis_read_data_tid;
                f.dest = dut->m_axis_read_data_tdest;
                f.user = dut->m_axis_read_data_tuser & 0xFU;
                rd_frames.push_back(std::move(f));
            }
        }

        // Descriptor input handshakes
        uint8_t wr_hs_mask = dut->s_wr_desc_valid & dut->s_wr_desc_ready;
        uint8_t rd_hs_mask = dut->s_rd_desc_valid & dut->s_rd_desc_ready;

        // Status outputs
        if (dut->m_wr_status_valid) {
            int popc = __builtin_popcount(unsigned(dut->m_wr_status_valid & 0xFU));
            if (popc != 1) {
                fail("m_wr_status_valid multi-hot: 0x%x", unsigned(dut->m_wr_status_valid));
            }
            for (int p = 0; p < 4; ++p) {
                if ((dut->m_wr_status_valid >> p) & 1U) {
                    WrStatusEvent ev{};
                    ev.cycle = cur_cycle;
                    ev.port  = p;
                    ev.len   = get_wr_status_len_port(p);
                    ev.tag   = uint8_t((dut->m_wr_status_tag >> (p * 8)) & 0xFFU);
                    ev.id    = uint8_t((dut->m_wr_status_id >> (p * 8)) & 0xFFU);
                    ev.dest  = uint8_t((dut->m_wr_status_dest >> (p * 8)) & 0xFFU);
                    ev.user  = uint8_t((dut->m_wr_status_user >> (p * 4)) & 0xFU);
                    ev.error = uint8_t((dut->m_wr_status_error >> (p * 4)) & 0xFU);
                    wr_status_q.push_back(ev);
                }
            }
        }

        if (dut->m_rd_status_valid) {
            int popc = __builtin_popcount(unsigned(dut->m_rd_status_valid & 0xFU));
            if (popc != 1) {
                fail("m_rd_status_valid multi-hot: 0x%x", unsigned(dut->m_rd_status_valid));
            }
            for (int p = 0; p < 4; ++p) {
                if ((dut->m_rd_status_valid >> p) & 1U) {
                    RdStatusEvent ev{};
                    ev.cycle = cur_cycle;
                    ev.port  = p;
                    ev.tag   = uint8_t((dut->m_rd_status_tag >> (p * 8)) & 0xFFU);
                    ev.error = uint8_t((dut->m_rd_status_error >> (p * 4)) & 0xFU);
                    rd_status_q.push_back(ev);
                }
            }
        }

        // -------------------------------------------------------------
        // 2. Posedge clock!
        // -------------------------------------------------------------
        dut->clk = 1;
        dut->eval();
        cur_cycle++;

        // -------------------------------------------------------------
        // 3. Post-posedge NBA updates for testbench drivers/slaves
        // -------------------------------------------------------------
        // Descriptor stall counters
        if (wr_desc_stall_rem > 0) {
            dut->wr_desc_stall = 1;
            wr_desc_stall_rem--;
        } else {
            dut->wr_desc_stall = (random_backpressure && (rng() % 5 == 0)) ? 1 : 0;
        }
        if (rd_desc_stall_rem > 0) {
            dut->rd_desc_stall = 1;
            rd_desc_stall_rem--;
        } else {
            dut->rd_desc_stall = (random_backpressure && (rng() % 5 == 0)) ? 1 : 0;
        }

        // Update write descriptor ports
        for (int p = 0; p < 4; ++p) {
            if (wr_port_busy[p] && ((wr_hs_mask >> p) & 1U)) {
                wr_port_busy[p] = false;
            }
            if (!wr_port_busy[p] && !wr_desc_q[p].empty()) {
                cur_wr_port[p] = wr_desc_q[p].front();
                wr_desc_q[p].pop_front();
                wr_port_busy[p] = true;
            }
        }
        uint64_t wr_addr_bus = 0;
        uint32_t wr_tag_bus = 0;
        uint8_t wr_val_bus = 0;
        for (int p = 0; p < 4; ++p) {
            if (wr_port_busy[p]) {
                wr_addr_bus |= (uint64_t(cur_wr_port[p].addr) << (p * 16));
                wr_tag_bus  |= (uint32_t(cur_wr_port[p].tag)  << (p * 8));
                set_wr_len_port(p, cur_wr_port[p].len);
                wr_val_bus  |= (1U << p);
            }
        }
        dut->s_wr_desc_addr  = wr_addr_bus;
        dut->s_wr_desc_tag   = wr_tag_bus;
        dut->s_wr_desc_valid = wr_val_bus;

        // Update read descriptor ports
        for (int p = 0; p < 4; ++p) {
            if (rd_port_busy[p] && ((rd_hs_mask >> p) & 1U)) {
                rd_port_busy[p] = false;
            }
            if (!rd_port_busy[p] && !rd_desc_q[p].empty()) {
                cur_rd_port[p] = rd_desc_q[p].front();
                rd_desc_q[p].pop_front();
                rd_port_busy[p] = true;
            }
        }
        uint64_t rd_addr_bus = 0;
        uint32_t rd_tag_bus = 0, rd_id_bus = 0, rd_dest_bus = 0;
        uint16_t rd_user_bus = 0;
        uint8_t rd_val_bus = 0;
        for (int p = 0; p < 4; ++p) {
            if (rd_port_busy[p]) {
                rd_addr_bus |= (uint64_t(cur_rd_port[p].addr) << (p * 16));
                rd_tag_bus  |= (uint32_t(cur_rd_port[p].tag)  << (p * 8));
                rd_id_bus   |= (uint32_t(cur_rd_port[p].id)   << (p * 8));
                rd_dest_bus |= (uint32_t(cur_rd_port[p].dest) << (p * 8));
                rd_user_bus |= (uint16_t(cur_rd_port[p].user & 0xFU) << (p * 4));
                set_rd_len_port(p, cur_rd_port[p].len);
                rd_val_bus  |= (1U << p);
            }
        }
        dut->s_rd_desc_addr  = rd_addr_bus;
        dut->s_rd_desc_tag   = rd_tag_bus;
        dut->s_rd_desc_id    = rd_id_bus;
        dut->s_rd_desc_dest  = rd_dest_bus;
        dut->s_rd_desc_user  = rd_user_bus;
        dut->s_rd_desc_valid = rd_val_bus;

        // Update write AXI-Stream driver
        if (wr_beat_valid && wr_axis_hs) {
            wr_beat_valid = false;
        }
        if (!wr_beat_valid) {
            if (wr_stall_rem > 0) {
                wr_stall_rem--;
            } else if (!wr_stream_q.empty()) {
                if (wr_stream_q.front().pre_stall > 0) {
                    wr_stall_rem = wr_stream_q.front().pre_stall - 1;
                    wr_stream_q.front().pre_stall = 0;
                } else {
                    cur_wr_beat = wr_stream_q.front();
                    wr_stream_q.pop_front();
                    wr_beat_valid = true;
                }
            }
        }
        if (wr_beat_valid) {
            dut->s_axis_write_data_tvalid = 1;
            dut->s_axis_write_data_tdata  = cur_wr_beat.data;
            dut->s_axis_write_data_tkeep  = cur_wr_beat.keep;
            dut->s_axis_write_data_tlast  = cur_wr_beat.last ? 1 : 0;
            dut->s_axis_write_data_tid    = cur_wr_beat.id;
            dut->s_axis_write_data_tdest  = cur_wr_beat.dest;
            dut->s_axis_write_data_tuser  = cur_wr_beat.user;
        } else {
            dut->s_axis_write_data_tvalid = 0;
            dut->s_axis_write_data_tlast  = 0;
        }

        // Update AXI B channel
        if (b_hs && !b_q.empty()) {
            b_q.pop_front();
        }
        if (!b_q.empty() && cur_cycle >= b_q.front().ready_cycle) {
            dut->m_axi_bvalid = 1;
            dut->m_axi_bresp  = b_q.front().resp;
        } else {
            dut->m_axi_bvalid = 0;
            dut->m_axi_bresp  = 0;
        }

        // Update AXI R channel
        if (r_hs && r_active) {
            cur_r_idx++;
            if (cur_r_idx > int(cur_ar.len)) {
                r_active = false;
                dut->m_axi_rvalid = 0;
                dut->m_axi_rlast  = 0;
            } else {
                r_gap_rem = cur_ar.beat_gap + (random_backpressure && (rng() % 3 == 0) ? int(rng() % 3) : 0);
                dut->m_axi_rvalid = 0;
            }
        }
        if (!r_active && !ar_q.empty()) {
            cur_ar = ar_q.front();
            ar_q.pop_front();
            r_active = true;
            cur_r_idx = 0;
            r_gap_rem = cur_ar.beat_gap;
        }
        if (r_active && !dut->m_axi_rvalid) {
            if (r_gap_rem > 0) {
                r_gap_rem--;
            } else {
                uint64_t rword = 0;
                uint16_t base = uint16_t(cur_ar.aligned_addr + cur_r_idx * 8);
                for (int k = 0; k < 8; ++k) {
                    rword |= (uint64_t(ram[(base + k) & 0xFFFF]) << (k * 8));
                }
                uint8_t rr = (cur_r_idx < int(cur_ar.beat_rresps.size())) ? cur_ar.beat_rresps[cur_r_idx] : 0;
                dut->m_axi_rdata  = rword;
                dut->m_axi_rresp  = rr;
                dut->m_axi_rlast  = (cur_r_idx == int(cur_ar.len)) ? 1 : 0;
                dut->m_axi_rvalid = 1;
            }
        }

        // Ready backpressure
        if (forced_wready_low_cycles > 0) {
            dut->m_axi_wready = 0;
            forced_wready_low_cycles--;
        } else {
            dut->m_axi_wready = (!random_backpressure || (rng() % 4 != 0)) ? 1 : 0;
        }
        if (forced_awready_low_cycles > 0) {
            dut->m_axi_awready = 0;
            forced_awready_low_cycles--;
        } else {
            dut->m_axi_awready = (!random_backpressure || (rng() % 5 != 0)) ? 1 : 0;
        }
        dut->m_axi_arready = (!random_backpressure || (rng() % 5 != 0)) ? 1 : 0;
        dut->m_axis_read_data_tready = (!random_backpressure || (rng() % 4 != 0)) ? 1 : 0;
    }

    bool wait_wr_statuses(size_t count, int max_cycles = 4000) {
        for (int i = 0; i < max_cycles && wr_status_q.size() < count; ++i) step();
        if (wr_status_q.size() < count) {
            fail("Timed out waiting for %zu write status events (got %zu)", count, wr_status_q.size());
            return false;
        }
        return true;
    }

    bool wait_rd_statuses(size_t count, int max_cycles = 4000) {
        for (int i = 0; i < max_cycles && rd_status_q.size() < count; ++i) step();
        if (rd_status_q.size() < count) {
            fail("Timed out waiting for %zu read status events (got %zu)", count, rd_status_q.size());
            return false;
        }
        return true;
    }
};

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    uint32_t seed = 101;
    for (int i = 1; i < argc; ++i) {
        if (std::string(argv[i]) == "--seed" && i + 1 < argc) {
            seed = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 10));
        }
    }

    DmaHarness h(seed);
    h.reset();
    int next_pkt_id = 1;

    // =========================================================================
    // Phase 1: 4-Port Descriptor Mux Skid Backpressure & Tag/Port Demux Routing
    // =========================================================================
    h.wr_desc_stall_rem = 10;
    h.rd_desc_stall_rem = 10;
    for (int p = 0; p < 4; ++p) {
        uint16_t waddr = uint16_t(0x0200 + p * 0x80 + p); // unaligned per port
        std::memset(h.ram + waddr - 4, 0x5A, 48);
        std::vector<uint8_t> pkt(24);
        for (size_t i = 0; i < pkt.size(); ++i) pkt[i] = uint8_t(0x10 * (p + 1) + i);
        h.wr_desc_q[p].push_back({p, waddr, 24, uint8_t(0xA0 + p)});
        h.push_packet(pkt, 0x10 + p, 0x20 + p, p, 0x30 + p, 0x40 + p, p ^ 3, next_pkt_id++);
    }
    // Wait for all 4 write completions; note packets are shared on single stream so run port-by-port check on tag+port routing:
    if (h.wait_wr_statuses(4)) {
        bool seen_port[4] = {false, false, false, false};
        for (int i = 0; i < 4; ++i) {
            auto ev = h.wr_status_q.front();
            h.wr_status_q.pop_front();
            if (ev.port < 0 || ev.port >= 4 || seen_port[ev.port]) {
                h.fail("Phase 1 write mux duplicate/invalid port routing: port=%d tag=0x%02x", ev.port, ev.tag);
            } else {
                seen_port[ev.port] = true;
                if (ev.tag != uint8_t(0xA0 + ev.port) || ev.len != 24 || ev.error != 0) {
                    h.fail("Phase 1 write status mismatch on port %d: tag=0x%02x len=%u err=%u",
                           ev.port, ev.tag, ev.len, ev.error);
                }
            }
        }
    }

    // Same simultaneous 4-port skid stall on Read Descriptor Mux
    for (int i = 0; i < 1024; ++i) h.ram[0x0600 + i] = uint8_t((i * 7 + 3) & 0xFF);
    h.rd_desc_stall_rem = 10;
    for (int p = 0; p < 4; ++p) {
        h.rd_desc_q[p].push_back({p, uint16_t(0x0600 + p * 64 + p), 19, uint8_t(0xB0 + p),
                                  uint8_t(0x50 + p), uint8_t(0x60 + p), uint8_t(p + 5)});
    }
    if (h.wait_rd_statuses(4) && h.rd_frames.size() >= 4) {
        bool seen_port[4] = {false, false, false, false};
        for (int i = 0; i < 4; ++i) {
            auto ev = h.rd_status_q.front();
            h.rd_status_q.pop_front();
            if (ev.port < 0 || ev.port >= 4 || seen_port[ev.port]) {
                h.fail("Phase 1 read mux duplicate/invalid port routing: port=%d tag=0x%02x", ev.port, ev.tag);
            } else {
                seen_port[ev.port] = true;
                if (ev.tag != uint8_t(0xB0 + ev.port) || ev.error != 0) {
                    h.fail("Phase 1 read status mismatch on port %d: tag=0x%02x err=%u", ev.port, ev.tag, ev.error);
                }
            }
        }
        h.rd_frames.clear();
    }

    // =========================================================================
    // Phase 2: Unaligned 4KB Boundary + AXI_MAX_BURST_LEN(16 -> 128B) Split Matrix
    // =========================================================================
    struct SplitCase {
        uint16_t addr;
        uint32_t len;
    };
    const SplitCase split_cases[] = {
        {0x0FF3, 37},    // unaligned crossing 0x1000
        {0x1F7B, 280},   // unaligned crossing BOTH 128B max-burst AND 0x2000 4KB boundary
        {0x2003, 130},   // unaligned > 128B max-burst (triggers AWLEN=16 overflow if unadjusted!)
        {0x2F85, 300},   // unaligned multi-burst across 0x3000
        {0x4000, 4096},  // exact 4096B aligned transfer
        {0x5FF9, 4120},  // > 4096B unaligned transfer crossing TWO 4KB boundaries (0x6000 & 0x7000)!
    };
    for (size_t tc = 0; tc < sizeof(split_cases) / sizeof(split_cases[0]); ++tc) {
        uint16_t addr = split_cases[tc].addr;
        uint32_t len  = split_cases[tc].len;
        int port = int(tc % 4);
        std::memset(h.ram, 0xC6, sizeof(h.ram));

        std::vector<uint8_t> pkt(len);
        for (uint32_t i = 0; i < len; ++i) pkt[i] = uint8_t((i * 29 + tc * 17 + 11) & 0xFF);

        h.wr_desc_q[port].push_back({port, addr, len, uint8_t(0x10 + tc)});
        h.push_packet(pkt, 0x01, 0x02, 0x1, uint8_t(0x80 + tc), uint8_t(0x90 + tc), uint8_t(tc & 0xF), next_pkt_id++);

        if (!h.wait_wr_statuses(1, 8000)) break;
        auto wev = h.wr_status_q.front();
        h.wr_status_q.pop_front();
        if (wev.port != port || wev.len != len || wev.tag != uint8_t(0x10 + tc) ||
            wev.id != uint8_t(0x80 + tc) || wev.dest != uint8_t(0x90 + tc) ||
            wev.user != uint8_t(tc & 0xF) || wev.error != 0) {
            h.fail("Phase 2[%zu] write status mismatch: port=%d len=%u tag=0x%02x id=0x%02x err=%u",
                   tc, wev.port, wev.len, wev.tag, wev.id, wev.error);
        }
        // Check canary guard bytes before & after written region
        for (int g = 1; g <= 16; ++g) {
            if (h.ram[(addr - g) & 0xFFFF] != 0xC6) {
                h.fail("Phase 2[%zu] pre-canary corrupted at 0x%04x", tc, unsigned((addr - g) & 0xFFFF));
                break;
            }
            if (h.ram[(addr + len - 1 + g) & 0xFFFF] != 0xC6) {
                h.fail("Phase 2[%zu] post-canary corrupted at 0x%04x", tc, unsigned((addr + len - 1 + g) & 0xFFFF));
                break;
            }
        }
        for (uint32_t i = 0; i < len; ++i) {
            uint8_t got = h.ram[(addr + i) & 0xFFFF];
            if (got != pkt[i]) {
                h.fail("Phase 2[%zu] RAM mismatch at +0x%x: got=0x%02x exp=0x%02x", tc, i, got, pkt[i]);
                break;
            }
        }

        // Read back the exact same unaligned buffer!
        int rport = int((tc + 1) % 4);
        h.rd_desc_q[rport].push_back({rport, addr, len, uint8_t(0x40 + tc),
                                      uint8_t(0x21 + tc), uint8_t(0x31 + tc), uint8_t((tc + 3) & 0xF)});
        if (!h.wait_rd_statuses(1, 8000)) break;
        for (int w = 0; w < 200 && h.rd_frames.empty(); ++w) h.step();
        auto rev = h.rd_status_q.front();
        h.rd_status_q.pop_front();
        if (rev.port != rport || rev.tag != uint8_t(0x40 + tc) || rev.error != 0 || h.rd_frames.empty()) {
            h.fail("Phase 2[%zu] read status/frame missing", tc);
        } else {
            auto rf = std::move(h.rd_frames.front());
            h.rd_frames.pop_front();
            if (rf.bytes != pkt || rf.id != uint8_t(0x21 + tc) || rf.dest != uint8_t(0x31 + tc) ||
                rf.user != uint8_t((tc + 3) & 0xF)) {
                h.fail("Phase 2[%zu] readback payload/sideband mismatch (got %zu bytes, exp %u)",
                       tc, rf.bytes.size(), len);
            }
        }
    }

    // =========================================================================
    // Phase 3: Unaligned Multi-Burst Short Packets + Back-to-Back Residual Flush
    // =========================================================================
    {
        struct ShortCase {
            uint16_t addr1;
            uint32_t desc_len1;
            uint32_t pkt_len1;
            uint16_t addr2;
            uint32_t desc_len2;
        };
        const ShortCase scases[] = {
            // 1. Multi-burst desc (200B at 0x2006 -> Burst0=122B, Burst1=78B),
            //    packet=124B -> Beat 15 has tlast=1 with 2 residual bytes for Burst 1!
            //    Upstream leaks tready in STATE_START of Burst 1 and eats Beat 0 of Packet 2!
            {0x2006, 200, 124, 0x2403, 53},
            // 2. Multi-burst desc (260B at 0x28F5), packet=95B ends inside Burst 0 (STATE_FINISH_BURST)
            {0x28F5, 260, 95,  0x2C05, 41},
            // 3. Single-beat 4B unaligned short packet at offset=6 requiring extra barrel-shifter cycle
            {0x3106, 64,  4,   0x3201, 29},
        };
        for (size_t i = 0; i < sizeof(scases) / sizeof(scases[0]); ++i) {
            std::memset(h.ram, 0x39, sizeof(h.ram));
            std::vector<uint8_t> p1(scases[i].pkt_len1), p2(scases[i].desc_len2);
            for (size_t b = 0; b < p1.size(); ++b) p1[b] = uint8_t(0x41 + ((b * 5 + i) & 0x7F));
            for (size_t b = 0; b < p2.size(); ++b) p2[b] = uint8_t(0x81 + ((b * 11 + i) & 0x7F));

            int sp = int((i + 1) % 4);
            // Enqueue BOTH descriptors on port sp & BOTH stream packets back-to-back with ZERO idle gap!
            h.wr_desc_q[sp].push_back({sp, scases[i].addr1, scases[i].desc_len1, uint8_t(0x50 + i * 2)});
            h.wr_desc_q[sp].push_back({sp, scases[i].addr2, scases[i].desc_len2, uint8_t(0x51 + i * 2)});
            h.push_packet(p1, 0x11, 0x22, 0x2, 0x6A, 0x7B, 0xC, next_pkt_id++);
            h.push_packet(p2, 0x33, 0x44, 0x4, 0x8C, 0x9D, 0x5, next_pkt_id++);

            if (!h.wait_wr_statuses(2)) break;
            auto s1 = h.wr_status_q.front(); h.wr_status_q.pop_front();
            auto s2 = h.wr_status_q.front(); h.wr_status_q.pop_front();

            if (s1.port != sp || s1.len != scases[i].pkt_len1 || s1.id != 0x6A || s1.dest != 0x7B || s1.user != 0xC) {
                h.fail("Phase 3[%zu] short pkt 1 status mismatch: port=%d len=%u(exp %u) id=0x%02x dest=0x%02x user=0x%x",
                       i, s1.port, s1.len, scases[i].pkt_len1, s1.id, s1.dest, s1.user);
            }
            if (s2.port != sp || s2.len != scases[i].desc_len2 || s2.id != 0x8C || s2.dest != 0x9D || s2.user != 0x5) {
                h.fail("Phase 3[%zu] back-to-back pkt 2 status mismatch: port=%d len=%u(exp %u) id=0x%02x",
                       i, s2.port, s2.len, scases[i].desc_len2, s2.id);
            }
            for (size_t b = 0; b < p1.size(); ++b) {
                if (h.ram[scases[i].addr1 + b] != p1[b]) {
                    h.fail("Phase 3[%zu] pkt 1 byte %zu mismatch", i, b);
                    break;
                }
            }
            if (h.ram[scases[i].addr1 + p1.size()] != 0x39) {
                h.fail("Phase 3[%zu] short pkt 1 wrote past packet_len!", i);
            }
            for (size_t b = 0; b < p2.size(); ++b) {
                if (h.ram[scases[i].addr2 + b] != p2[b]) {
                    h.fail("Phase 3[%zu] back-to-back pkt 2 byte %zu corrupted (got 0x%02x exp 0x%02x)!",
                           i, b, h.ram[scases[i].addr2 + b], p2[b]);
                    break;
                }
            }
        }
    }

    // =========================================================================
    // Phase 4: Oversized Packets (packet_len > desc_len) + Terminal TLAST Metadata & Timing
    // =========================================================================
    {
        struct OverCase {
            uint16_t addr1;
            uint32_t desc_len1;
            uint32_t pkt_len1;
        };
        const OverCase ocases[] = {
            {0x4103, 4,   36},   // small unaligned desc, multi-beat excess drain
            {0x4206, 124, 129},  // 2-burst unaligned desc where Beat 16 has 1 excess byte (tlast on W-beat)
            {0x4406, 124, 136},  // 2-burst unaligned desc where Beat 16 is full 8B with tlast=1
            {0x46F5, 210, 315},  // multi-burst 4KB-crossing oversized frame with delayed terminal tlast!
        };
        for (size_t i = 0; i < sizeof(ocases) / sizeof(ocases[0]); ++i) {
            std::memset(h.ram, 0xE7, sizeof(h.ram));
            std::vector<uint8_t> p1(ocases[i].pkt_len1), p2(37);
            for (size_t b = 0; b < p1.size(); ++b) p1[b] = uint8_t(0x13 + ((b * 9 + i) & 0xFF));
            for (size_t b = 0; b < p2.size(); ++b) p2[b] = uint8_t(0x97 + ((b * 3 + i) & 0xFF));

            int op = int((i + 2) % 4);
            int pid1 = next_pkt_id++;
            int pid2 = next_pkt_id++;
            h.bresp_delay_cycles = 0; // BVALID returns immediately, while terminal tlast is delayed by 14 cycles!
            h.wr_desc_q[op].push_back({op, ocases[i].addr1, ocases[i].desc_len1, uint8_t(0x70 + i * 2)});
            h.wr_desc_q[op].push_back({op, 0x4A02, 37, uint8_t(0x71 + i * 2)});
            h.push_packet(p1, 0xAA, 0x55, 0x3, 0x3C, 0xC3, 0x9, pid1, /*last_beat_stall=*/14);
            h.push_packet(p2, 0x12, 0x34, 0x1, 0x7E, 0xE7, 0x6, pid2, 0);

            if (!h.wait_wr_statuses(2)) break;
            auto s1 = h.wr_status_q.front(); h.wr_status_q.pop_front();
            auto s2 = h.wr_status_q.front(); h.wr_status_q.pop_front();

            if (h.pkt_tlast_cycle[pid1] < 0 || s1.cycle <= h.pkt_tlast_cycle[pid1]) {
                h.fail("Phase 4[%zu] oversized status fired at cycle %d BEFORE terminal tlast handshake at cycle %d!",
                       i, s1.cycle, h.pkt_tlast_cycle[pid1]);
            }
            if (s1.port != op || s1.len != ocases[i].desc_len1 ||
                s1.id != 0x3C || s1.dest != 0xC3 || s1.user != 0x9 || s1.error != 0) {
                h.fail("Phase 4[%zu] oversized status mismatch: len=%u(exp %u) id=0x%02x(exp 0x3C) dest=0x%02x(exp 0xC3) user=0x%x(exp 0x9)",
                       i, s1.len, ocases[i].desc_len1, s1.id, s1.dest, s1.user);
            }
            for (uint32_t b = 0; b < ocases[i].desc_len1; ++b) {
                if (h.ram[ocases[i].addr1 + b] != p1[b]) {
                    h.fail("Phase 4[%zu] oversized pkt 1 byte %u mismatch", i, b);
                    break;
                }
            }
            if (h.ram[ocases[i].addr1 - 1] != 0xE7 || h.ram[ocases[i].addr1 + ocases[i].desc_len1] != 0xE7) {
                h.fail("Phase 4[%zu] oversized pkt 1 overwrote memory outside desc_len!", i);
            }
            if (s2.port != op || s2.len != 37 || s2.id != 0x7E) {
                h.fail("Phase 4[%zu] post-oversized pkt 2 status mismatch: len=%u id=0x%02x", i, s2.len, s2.id);
            }
            for (size_t b = 0; b < p2.size(); ++b) {
                if (h.ram[0x4A02 + b] != p2[b]) {
                    h.fail("Phase 4[%zu] post-oversized pkt 2 byte %zu corrupted!", i, b);
                    break;
                }
            }
        }
    }

    // =========================================================================
    // Phase 5: Zero-Length Descriptors (len == 0) Interleaved In-Flight Ordering
    // =========================================================================
    {
        // Write engine: [Desc A: len=150 (2 bursts, BVALID delayed 12 cycles)]
        //            -> [Desc B: len=0] -> [Desc C: len=0] -> [Desc D: len=25]
        h.bresp_delay_cycles = 12;
        std::vector<uint8_t> pA(150), pD(25);
        for (size_t b = 0; b < pA.size(); ++b) pA[b] = uint8_t(0x20 + b);
        for (size_t b = 0; b < pD.size(); ++b) pD[b] = uint8_t(0x60 + b);

        int aw_before = h.total_aw_count;
        int w_before  = h.total_w_beats;

        // Submit all on port 0 so mux round-robin preserves exact A -> B -> C -> D submission order!
        h.wr_desc_q[0].push_back({0, 0x5103, 150, 0xD1});
        h.wr_desc_q[0].push_back({0, 0x5555, 0,   0xD2});
        h.wr_desc_q[0].push_back({0, 0x5666, 0,   0xD3});
        h.wr_desc_q[0].push_back({0, 0x5305, 25,  0xD4});
        h.push_packet(pA, 0x11, 0x22, 0x1, 0xA1, 0xB1, 0x7, next_pkt_id++);
        h.push_packet(pD, 0x33, 0x44, 0x2, 0xA4, 0xB4, 0xB, next_pkt_id++);

        if (h.wait_wr_statuses(4)) {
            WrStatusEvent evs[4];
            for (int i = 0; i < 4; ++i) { evs[i] = h.wr_status_q.front(); h.wr_status_q.pop_front(); }
            // Desc A has 2 AW bursts, Desc D has 1 AW burst => total 3 AW bursts! Zero-len B & C must issue 0!
            if (h.total_aw_count - aw_before != 3) {
                h.fail("Phase 5 zero-len write issued unexpected AW count: %d (expected 3)",
                       h.total_aw_count - aw_before);
            }
            (void)w_before;
            if (evs[0].tag != 0xD1 || evs[1].tag != 0xD2 || evs[2].tag != 0xD3 || evs[3].tag != 0xD4) {
                h.fail("Phase 5 write status ordering broken: got tags 0x%02x, 0x%02x, 0x%02x, 0x%02x",
                       evs[0].tag, evs[1].tag, evs[2].tag, evs[3].tag);
            }
            for (int z = 1; z <= 2; ++z) {
                if (evs[z].len != 0 || evs[z].id != 0 || evs[z].dest != 0 || evs[z].user != 0 || evs[z].error != 0) {
                    h.fail("Phase 5 zero-len write status[%d] non-zero fields: len=%u id=0x%02x dest=0x%02x user=0x%x err=%u",
                           z, evs[z].len, evs[z].id, evs[z].dest, evs[z].user, evs[z].error);
                }
            }
            if (evs[3].len != 25 || evs[3].id != 0xA4) {
                h.fail("Phase 5 post-zero-len Desc D corrupted: len=%u id=0x%02x", evs[3].len, evs[3].id);
            }
        }
        h.bresp_delay_cycles = 0;

        // Read engine: [Desc A: len=150 (2 bursts, R beat gap = 3)] -> [Desc B: len=0] -> [Desc C: len=18]
        int ar_before = h.total_ar_count;
        h.planned_ar_rresp_q.push_back({{}, 3});
        h.planned_ar_rresp_q.push_back({{}, 3});
        h.rd_desc_q[2].push_back({2, 0x5103, 150, 0xE1, 0x11, 0x21, 0x3});
        h.rd_desc_q[2].push_back({2, 0x5999, 0,   0xE2, 0x99, 0x88, 0xF});
        h.rd_desc_q[2].push_back({2, 0x5305, 25,  0xE3, 0x13, 0x23, 0x6});

        if (h.wait_rd_statuses(3)) {
            for (int w = 0; w < 100 && h.rd_frames.size() < 2; ++w) h.step();
            RdStatusEvent revs[3];
            for (int i = 0; i < 3; ++i) { revs[i] = h.rd_status_q.front(); h.rd_status_q.pop_front(); }
            if (h.total_ar_count - ar_before != 3) {
                h.fail("Phase 5 zero-len read issued unexpected AR count: %d (expected 3)",
                       h.total_ar_count - ar_before);
            }
            if (revs[0].tag != 0xE1 || revs[1].tag != 0xE2 || revs[2].tag != 0xE3 || revs[1].error != 0) {
                h.fail("Phase 5 zero-len read ordering/error mismatch: tags 0x%02x 0x%02x 0x%02x err=%u",
                       revs[0].tag, revs[1].tag, revs[2].tag, revs[1].error);
            }
            if (h.rd_frames.size() != 2) {
                h.fail("Phase 5 zero-len read emitted unexpected AXI-Stream frame count: %zu (expected 2)",
                       h.rd_frames.size());
            }
            h.rd_frames.clear();
        }
    }

    // =========================================================================
    // Phase 6: Sticky AXI Error Severity (DECERR > SLVERR > OKAY) & Per-Descriptor Reset
    // =========================================================================
    {
        // Write 1: 3 bursts (300B at 0x6003 -> 125B + 128B + 47B) with BRESP = [OKAY(0), DECERR(3), SLVERR(2)] -> expect 7 (WR_DECERR)!
        // Write 2: 2 bursts (160B) with BRESP = [SLVERR(2), OKAY(0)] -> expect 6 (WR_SLVERR)!
        // Write 3: 1 burst (32B) with BRESP = [OKAY(0)] -> expect 0 (NONE)!
        h.planned_bresp_q = {0, 3, 2,  2, 0,  0};
        std::vector<uint8_t> w1(300, 0x51), w2(160, 0x52), w3(32, 0x53);
        h.wr_desc_q[1].push_back({1, 0x6003, 300, 0xF1});
        h.wr_desc_q[1].push_back({1, 0x6200, 160, 0xF2});
        h.wr_desc_q[1].push_back({1, 0x6400, 32,  0xF3});
        h.push_packet(w1, 1, 1, 1, 1, 1, 1, next_pkt_id++);
        h.push_packet(w2, 2, 2, 2, 2, 2, 2, next_pkt_id++);
        h.push_packet(w3, 3, 3, 3, 3, 3, 3, next_pkt_id++);

        if (h.wait_wr_statuses(3)) {
            auto e1 = h.wr_status_q.front(); h.wr_status_q.pop_front();
            auto e2 = h.wr_status_q.front(); h.wr_status_q.pop_front();
            auto e3 = h.wr_status_q.front(); h.wr_status_q.pop_front();
            if (e1.error != 7) h.fail("Phase 6 write DECERR+SLVERR downgraded: got %u exp 7", e1.error);
            if (e2.error != 6) h.fail("Phase 6 write SLVERR+OKAY mismatch: got %u exp 6", e2.error);
            if (e3.error != 0) h.fail("Phase 6 write error bled into next OKAY descriptor: got %u exp 0", e3.error);
        }

        // Read 1: 2 bursts (160B at 0x6003 -> 125B (16 beats) + 35B (5 beats))
        //         Burst 0 has DECERR(3) on beat 2, Burst 1 has SLVERR(2) on beat 1 -> expect 5 (RD_DECERR)!
        // Read 2: 1 burst (32B = 4 beats) with SLVERR(2) on beat 0, OKAY(0) on beats 1..3 -> expect 4 (RD_SLVERR)!
        // Read 3: 1 burst (16B) all OKAY -> expect 0!
        h.planned_ar_rresp_q.push_back({{0, 0, 3, 0}, 0});
        h.planned_ar_rresp_q.push_back({{0, 2, 0}, 0});
        h.planned_ar_rresp_q.push_back({{2, 0, 0, 0}, 0});
        h.planned_ar_rresp_q.push_back({{0, 0}, 0});

        h.rd_desc_q[3].push_back({3, 0x6003, 160, 0xC1, 1, 1, 1});
        h.rd_desc_q[3].push_back({3, 0x6200, 32,  0xC2, 2, 2, 2});
        h.rd_desc_q[3].push_back({3, 0x6400, 16,  0xC3, 3, 3, 3});

        if (h.wait_rd_statuses(3)) {
            for (int w = 0; w < 100 && h.rd_frames.size() < 3; ++w) h.step();
            auto r1 = h.rd_status_q.front(); h.rd_status_q.pop_front();
            auto r2 = h.rd_status_q.front(); h.rd_status_q.pop_front();
            auto r3 = h.rd_status_q.front(); h.rd_status_q.pop_front();
            if (r1.error != 5) h.fail("Phase 6 read DECERR+SLVERR downgraded: got %u exp 5", r1.error);
            if (r2.error != 4) h.fail("Phase 6 read SLVERR+OKAY mismatch: got %u exp 4", r2.error);
            if (r3.error != 0) h.fail("Phase 6 read error bled into next OKAY descriptor: got %u exp 0", r3.error);
            h.rd_frames.clear();
        }
    }

    // =========================================================================
    // Phase 7: Severe WREADY Stall Filling Internal Output FIFO Mid-Burst
    // =========================================================================
    {
        std::memset(h.ram, 0x77, sizeof(h.ram));
        std::vector<uint8_t> pkt(290);
        for (size_t b = 0; b < pkt.size(); ++b) pkt[b] = uint8_t((b * 19 + 5) & 0xFF);
        h.forced_wready_low_cycles = 45; // forces out_fifo_half_full_reg = 1 -> m_axi_wready_int = 0!
        h.wr_desc_q[2].push_back({2, 0x7F83, 290, 0x99});
        h.push_packet(pkt, 0x10, 0x20, 0x4, 0x5A, 0xA5, 0xE, next_pkt_id++);
        if (h.wait_wr_statuses(1, 5000)) {
            auto ev = h.wr_status_q.front(); h.wr_status_q.pop_front();
            if (ev.len != 290 || ev.id != 0x5A || ev.error != 0) {
                h.fail("Phase 7 WREADY stall status mismatch");
            }
            for (size_t b = 0; b < pkt.size(); ++b) {
                if (h.ram[0x7F83 + b] != pkt[b]) {
                    h.fail("Phase 7 WREADY stall corrupted byte %zu (got 0x%02x exp 0x%02x)",
                           b, h.ram[0x7F83 + b], pkt[b]);
                    break;
                }
            }
        }
    }

    // =========================================================================
    // Phase 7b: Bounded AWREADY Stall With WREADY=1 (AXI4 W-Before-AW Ordering)
    // =========================================================================
    {
        std::memset(h.ram, 0x6B, sizeof(h.ram));
        const uint16_t waddr = 0x7FB5; // unaligned multi-burst write crossing 0x8000 4KB boundary
        const uint32_t wlen  = 200;
        std::vector<uint8_t> pkt(wlen);
        for (size_t b = 0; b < pkt.size(); ++b) pkt[b] = uint8_t((b * 23 + 17) & 0xFF);
        h.forced_awready_low_cycles = 20; // AWREADY=0 for 20 cycles while WREADY=1!
        h.wr_desc_q[0].push_back({0, waddr, wlen, 0x9A});
        h.push_packet(pkt, 0x12, 0x34, 0x5, 0x6C, 0xC6, 0xA, next_pkt_id++);
        if (h.wait_wr_statuses(1, 5000)) {
            auto ev = h.wr_status_q.front(); h.wr_status_q.pop_front();
            if (ev.port != 0 || ev.len != wlen || ev.tag != 0x9A ||
                ev.id != 0x6C || ev.dest != 0xC6 || ev.user != 0xA || ev.error != 0) {
                h.fail("Phase 7b AWREADY stall write status mismatch: port=%d len=%u tag=0x%02x id=0x%02x err=%u",
                       ev.port, ev.len, ev.tag, ev.id, ev.error);
            }
            if (h.ram[waddr - 1] != 0x6B || h.ram[waddr + wlen] != 0x6B) {
                h.fail("Phase 7b AWREADY stall canary overwritten around [0x%04x, +%u)", waddr, wlen);
            }
            for (size_t b = 0; b < pkt.size(); ++b) {
                if (h.ram[waddr + b] != pkt[b]) {
                    h.fail("Phase 7b AWREADY stall corrupted byte %zu (got 0x%02x exp 0x%02x)",
                           b, h.ram[waddr + b], pkt[b]);
                    break;
                }
            }
        }
        h.rd_desc_q[1].push_back({1, waddr, wlen, 0x9B, 0x22, 0x33, 0x7});
        if (h.wait_rd_statuses(1, 5000)) {
            for (int w = 0; w < 200 && h.rd_frames.empty(); ++w) h.step();
            auto rev = h.rd_status_q.front(); h.rd_status_q.pop_front();
            if (rev.port != 1 || rev.tag != 0x9B || rev.error != 0 || h.rd_frames.empty()) {
                h.fail("Phase 7b AWREADY stall companion readback missing");
            } else {
                auto rf = std::move(h.rd_frames.front());
                h.rd_frames.pop_front();
                if (rf.bytes != pkt || rf.id != 0x22 || rf.dest != 0x33 || rf.user != 0x7) {
                    h.fail("Phase 7b AWREADY stall companion readback payload mismatch");
                }
            }
        }
    }

    // =========================================================================
    // Phase 8: Seeded Randomized Full-System Stress (60 Write + 60 Read Descriptors)
    // =========================================================================
    h.random_backpressure = true;
    for (int iter = 0; iter < 60 && h.error_count == 0; ++iter) {
        int wport = int(h.rng() % 4);
        int rport = int(h.rng() % 4);

        // Bias addresses near 4KB (0x1000) and 128B boundaries with random byte offset 0..7
        uint16_t base_page = uint16_t(((iter % 12) + 1) * 0x1000);
        int delta = int(h.rng() % 320) - 180;
        uint16_t addr = uint16_t((int(base_page) + delta) & 0xFFFC) | uint16_t(h.rng() % 8);
        if (addr < 0x0400) addr += 0x0800;
        if (addr > 0xF000) addr -= 0x2000;

        uint32_t desc_len;
        int mode = int(h.rng() % 5);
        if (mode == 0) {
            desc_len = 0; // zero-length descriptor!
        } else {
            desc_len = 1 + (h.rng() % 340);
        }

        uint32_t pkt_len = desc_len;
        if (desc_len > 0) {
            if (mode == 1 && desc_len > 4) {
                pkt_len = 1 + (h.rng() % (desc_len - 1)); // short packet
            } else if (mode == 2) {
                pkt_len = desc_len + 1 + (h.rng() % 75);  // oversized packet
            }
        }

        std::memset(h.ram + addr - 16, 0xD2, desc_len + 96);
        std::vector<uint8_t> pkt(pkt_len);
        for (size_t b = 0; b < pkt_len; ++b) pkt[b] = uint8_t((h.rng() & 0xFF));

        uint8_t wtag = uint8_t((iter * 3 + 7) & 0xFF);
        uint8_t last_id = uint8_t(0x40 + (iter & 0x3F));
        uint8_t last_dest = uint8_t(0x80 + (iter & 0x3F));
        uint8_t last_user = uint8_t((iter * 5 + 1) & 0xF);
        int pid = next_pkt_id++;

        h.wr_desc_q[wport].push_back({wport, addr, desc_len, wtag});
        if (pkt_len > 0) {
            h.push_packet(pkt, 0x05, 0x06, 0x2, last_id, last_dest, last_user, pid,
                          (mode == 2) ? int(h.rng() % 6) : 0);
        }

        if (!h.wait_wr_statuses(1, 6000)) break;
        auto wev = h.wr_status_q.front();
        h.wr_status_q.pop_front();

        uint32_t exp_written = std::min(desc_len, pkt_len);
        if (wev.port != wport || wev.tag != wtag || wev.len != exp_written || wev.error != 0) {
            h.fail("Phase 8[%d] write status mismatch: port=%d(exp %d) tag=0x%02x(exp 0x%02x) len=%u(exp %u)",
                   iter, wev.port, wport, wev.tag, wtag, wev.len, exp_written);
            break;
        }
        if (desc_len == 0) {
            if (wev.id != 0 || wev.dest != 0 || wev.user != 0) {
                h.fail("Phase 8[%d] zero-len write non-zero metadata", iter);
            }
        } else {
            if (wev.id != last_id || wev.dest != last_dest || wev.user != last_user) {
                h.fail("Phase 8[%d] write metadata mismatch: id=0x%02x(exp 0x%02x)", iter, wev.id, last_id);
            }
            if (mode == 2 && (h.pkt_tlast_cycle[pid] < 0 || wev.cycle <= h.pkt_tlast_cycle[pid])) {
                h.fail("Phase 8[%d] oversized write status preceded tlast!", iter);
            }
        }
        if (h.ram[addr - 1] != 0xD2 || h.ram[addr + exp_written] != 0xD2) {
            h.fail("Phase 8[%d] canary overwritten around [0x%04x, +%u)", iter, addr, exp_written);
        }
        for (uint32_t b = 0; b < exp_written; ++b) {
            if (h.ram[addr + b] != pkt[b]) {
                h.fail("Phase 8[%d] written byte %u mismatch", iter, b);
                break;
            }
        }

        // Companion readback (zero-length or exact exp_written)
        uint8_t rtag = uint8_t((iter * 5 + 3) & 0xFF);
        uint8_t rid  = uint8_t(0x10 + (iter & 0x3F));
        uint8_t rdst = uint8_t(0x90 + (iter & 0x3F));
        uint8_t rusr = uint8_t((iter + 9) & 0xF);
        h.rd_desc_q[rport].push_back({rport, addr, exp_written, rtag, rid, rdst, rusr});
        if (!h.wait_rd_statuses(1, 6000)) break;
        auto rev = h.rd_status_q.front();
        h.rd_status_q.pop_front();
        if (rev.port != rport || rev.tag != rtag || rev.error != 0) {
            h.fail("Phase 8[%d] read status mismatch", iter);
        }
        if (exp_written == 0) {
            for (int w = 0; w < 10; ++w) h.step();
            if (!h.rd_frames.empty()) {
                h.fail("Phase 8[%d] zero-len read emitted unexpected frame", iter);
            }
        } else {
            for (int w = 0; w < 200 && h.rd_frames.empty(); ++w) h.step();
            if (h.rd_frames.empty()) {
                h.fail("Phase 8[%d] missing readback frame", iter);
            } else {
                auto rf = std::move(h.rd_frames.front());
                h.rd_frames.pop_front();
                std::vector<uint8_t> exp_slice(pkt.begin(), pkt.begin() + exp_written);
                if (rf.bytes != exp_slice || rf.id != rid || rf.dest != rdst || rf.user != rusr) {
                    h.fail("Phase 8[%d] readback frame mismatch", iter);
                }
            }
        }
    }

    if (!h.aw_q.empty() || !h.w_q.empty() || h.w_active) {
        h.fail("Unmatched AXI write beats/bursts at end of simulation: aw_q=%zu w_q=%zu w_active=%d",
               h.aw_q.size(), h.w_q.size(), int(h.w_active));
    }

    if (h.error_count == 0) {
        std::printf("PASS: Verilator SmartNIC AXI4 DMA suite passed (seed=%u, cycles=%d, aw=%d, ar=%d)\n",
                    seed, h.cur_cycle, h.total_aw_count, h.total_ar_count);
        return 0;
    } else {
        std::fprintf(stderr, "FAIL: Verilator SmartNIC AXI4 DMA suite failed with %d errors (seed=%u)\n",
                     h.error_count, seed);
        return 1;
    }
}
