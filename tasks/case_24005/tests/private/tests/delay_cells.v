`timescale 1ps/1ps
module \$_NOT_ (input A, output Y);
  assign #(22) Y = ~A;
endmodule
module \$_AND_ (input A, B, output Y);
  assign #(34) Y = A & B;
endmodule
module \$_OR_ (input A, B, output Y);
  assign #(38) Y = A | B;
endmodule
module \$_XOR_ (input A, B, output Y);
  assign #(48) Y = A ^ B;
endmodule
module \$_MUX_ (input A, B, S, output Y);
  assign #(44) Y = S ? B : A;
endmodule
module \$_DFF_P_ (input D, C, output reg Q);
  integer dly;
  integer seed_arg;
  reg [8*80-1:0] inst_str;
  integer idx;
  initial begin
    seed_arg = 101;
    if (!$value$plusargs("seed=%d", seed_arg)) seed_arg = 101;
    $sformat(inst_str, "%m");
    dly = seed_arg * 17;
    for (idx = 0; idx < 80; idx = idx + 1)
      dly = (dly * 33 + inst_str[idx*8 +: 8]) & 32'h7fffffff;
    dly = 65 + (dly % 95);
    Q = 1'b0;
  end
  always @(posedge C) Q <= #(dly) D;
endmodule
module \$_DFF_PN0_ (input D, C, R, output reg Q);
  initial Q = 1'b0;
  always @(posedge C or negedge R)
    if (!R) Q <= #60 1'b0;
    else    Q <= #95 D;
endmodule
module \$_DFF_PP0_ (input D, C, R, output reg Q);
  initial Q = 1'b0;
  always @(posedge C or posedge R)
    if (R) Q <= #60 1'b0;
    else   Q <= #95 D;
endmodule
