# Build & Verification Environment

## Editable RTL Files
- `code/VX_wctl_unit.sv`
- `code/VX_split_join.sv`
- `code/VX_ipdom_stack.sv`

## Integration Top & Read-Only Closure
- Top-level integration wrapper: `code/VX_wctl_ipdom_top.sv`
- Supporting headers, packages, interfaces, and library primitives are provided in `code/`.

## Example Synthesis & Lint Commands
```bash
# Yosys + slang latch-free synthesis check (multi-packet SIMT config)
yosys -m slang -p "
  read_slang -DASIC -DSYNTHESIS -DVX_CFG_XLEN=32 -DVX_CFG_NUM_WARPS=4 -DVX_CFG_NUM_THREADS=8 -DVX_CFG_NUM_SFU_LANES=2     -Icode code/VX_gpu_pkg.sv code/VX_execute_if.sv code/VX_txbar_bus_if.sv code/VX_warp_ctl_if.sv code/VX_result_if.sv     code/VX_dp_ram_asic.v code/VX_scan.sv code/VX_find_first.sv code/VX_lzc.sv code/VX_onehot_encoder.sv code/VX_priority_encoder.sv     code/VX_popcount.sv code/VX_pipe_register.sv code/VX_pipe_buffer.sv code/VX_stream_buffer.sv code/VX_async_ram_patch.sv     code/VX_dp_ram.sv code/VX_fifo_queue.sv code/VX_elastic_buffer.sv     code/VX_ipdom_stack.sv code/VX_split_join.sv code/VX_wctl_unit.sv code/VX_wctl_ipdom_top.sv --top VX_wctl_ipdom_top;
  hierarchy -check -top VX_wctl_ipdom_top; proc; opt_clean; check -assert; select -assert-none */t:\$dlatch*
"
```
