# Build & Verification Instructions

Compile the TCDM request channel integration with Verilator 5 (`verilator --binary --timing -j 1 -Wno-fatal +incdir+code`) using:
- `code/RequestBlock1CH.sv`
- `code/ArbitrationTree.sv`
- `code/FanInPrimitive_Req.sv`
- `code/priority_Flag_Req.sv`
- `code/TestAndSet.sv`
- `code/AddressDecoder_Resp.sv`

Check latch-free synthesis with Yosys (`read_verilog -sv -Icode ...; hierarchy -check -top RequestBlock1CH; proc; opt_clean; select -assert-none t:$dlatch* t:$adlatch* t:$latch* t:$sr*`).

The editable files are `code/ArbitrationTree.sv` and `code/priority_Flag_Req.sv`. Do not modify the other files in `code/`.
