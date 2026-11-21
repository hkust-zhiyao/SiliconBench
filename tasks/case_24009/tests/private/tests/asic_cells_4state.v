`timescale 1ns/100ps
// 4-state ASIC standard cells WITHOUT FPGA bitstream initial=0! Every flip-flop powers up to 1'bx!
module \$_NOT_ (input A, output Y);
  assign Y = ~A;
endmodule
module \$_AND_ (input A, B, output Y);
  assign Y = A & B;
endmodule
module \$_OR_ (input A, B, output Y);
  assign Y = A | B;
endmodule
module \$_XOR_ (input A, B, output Y);
  assign Y = A ^ B;
endmodule
module \$_MUX_ (input A, B, S, output Y);
  assign Y = S ? B : A;
endmodule
module \$_DFF_P_ (input C, D, output reg Q);
  initial Q = 1'bx;
  always @(posedge C) Q <= D;
endmodule
module \$_DFF_N_ (input C, D, output reg Q);
  initial Q = 1'bx;
  always @(negedge C) Q <= D;
endmodule
module \$_DFFE_PP_ (input C, E, D, output reg Q);
  initial Q = 1'bx;
  always @(posedge C) if (E) Q <= D;
endmodule
module \$_DFF_PP0_ (input C, R, D, output reg Q);
  initial Q = 1'bx;
  always @(posedge C or posedge R) if (R) Q <= 1'b0; else Q <= D;
endmodule
module \$_DFF_PP1_ (input C, R, D, output reg Q);
  initial Q = 1'bx;
  always @(posedge C or posedge R) if (R) Q <= 1'b1; else Q <= D;
endmodule
module \$_DFF_PN0_ (input C, R, D, output reg Q);
  initial Q = 1'bx;
  always @(posedge C or negedge R) if (!R) Q <= 1'b0; else Q <= D;
endmodule
module \$_DFF_PN1_ (input C, R, D, output reg Q);
  initial Q = 1'bx;
  always @(posedge C or negedge R) if (!R) Q <= 1'b1; else Q <= D;
endmodule
module \$_SDFF_PP0_ (input C, R, D, output reg Q);
  initial Q = 1'bx;
  always @(posedge C) if (R) Q <= 1'b0; else Q <= D;
endmodule
module \$_SDFF_PP1_ (input C, R, D, output reg Q);
  initial Q = 1'bx;
  always @(posedge C) if (R) Q <= 1'b1; else Q <= D;
endmodule
