# Build & Verification Reference (`dmac_sg_cluster`)

## Editable Files
- `code/dmac_sg.v`
- `code/data_mover.v`
- `code/request_arb.v`
- `code/axi_dmac_burst_memory.v`

## Local Simulation & Nangate45 STA Commands
- **Verilator Multi-Clock Simulation**:
  ```bash
  verilator --binary --timing -Wno-fatal -Icode code/ad_mem.v code/ad_mem_asym.v \
    code/sync_bits.v code/sync_gray.v code/sync_event.v \
    code/util_axis_fifo_address_generator.v code/util_axis_fifo.v code/splitter.v \
    code/address_generator.v code/request_generator.v code/response_handler.v \
    code/axi_dmac_response_manager.v code/axi_dmac_resize_src.v code/axi_dmac_resize_dest.v \
    code/axi_register_slice.v code/axi_dmac_ext_sync.v code/data_mover.v \
    code/src_axi_stream.v code/src_axi_mm.v code/src_fifo_inf.v \
    code/dest_axi_mm.v code/dest_axi_stream.v code/dest_fifo_inf.v \
    code/axi_dmac_burst_memory.v code/request_arb.v code/dmac_sg.v code/dmac_sg_cluster.v <your_tb.sv>
  ```
- **Yosys Nangate45 Synthesis & OpenROAD OpenSTA Signoff**:
  Use `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`, and `lib/NangateOpenCellLibrary_typical.lib` with Yosys (`hierarchy -check -top dmac_sg_cluster; proc; opt; memory; opt; flatten; opt; techmap; opt; dfflibmap -liberty ...; abc -liberty ... -script "+strash; &get -n; &fraig -x; &put; scorr; dc2; dretime; strash; &get -n; &dch -f; &nf -D 800; &put; buffer -N 8; upsize -D 800; dnsize -D 800"; hilomap -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z`) and OpenROAD (`openroad -exit`) at the exact clock periods and I/O delays specified in `issue.md`.
