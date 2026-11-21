# Build & Verification Reference (`data_offload_subsys`)

## Editable Files
- `code/data_offload.v`
- `code/data_offload_fsm.v`
- `code/data_offload_regmap.v`
- `code/util_axis_fifo_asym.v`

## Local Simulation & Nangate45 STA Commands
- **Verilator Three-Clock Simulation**:
  ```bash
  verilator --binary --timing +1364-2005ext+v -Wno-fatal -Icode \
    code/ad_mem.v code/up_axi.v code/axi_register_slice.v \
    code/sync_bits.v code/sync_data.v code/sync_event.v code/sync_gray.v \
    code/util_axis_fifo_address_generator.v code/util_axis_fifo.v code/util_axis_fifo_asym.v \
    code/data_offload_fsm.v code/data_offload_regmap.v code/data_offload.v \
    code/data_offload_subsys.v <your_tb.sv>
  ```
- **Yosys Nangate45 Synthesis & OpenROAD OpenSTA Signoff**:
  Synthesize `data_offload_subsys` against `lib/NangateOpenCellLibrary_typical.lib` (`hierarchy -check -top data_offload_subsys; proc; opt; memory; opt; flatten; opt; techmap; opt; dfflibmap -liberty ...; abc -liberty ... -script "+strash; &get -n; &fraig -x; &put; scorr; dc2; dretime; strash; &get -n; &dch -f; &nf -D 800; &put; buffer -N 8; upsize -D 800; dnsize -D 800"; hilomap -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z`) and check timing in OpenROAD (`openroad -exit`) using `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`, and `lib/NangateOpenCellLibrary_typical.lib` at the exact clocks and I/O delays in `issue.md`.
