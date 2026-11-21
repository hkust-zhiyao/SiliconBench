#include <verilated.h>
#include "Vtb.h"
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    VerilatedContext* contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);
    Vtb* top = new Vtb{contextp};

    top->clk_i  = 0;
    top->rst_ni = 0;

    const unsigned long long max_half_cycles = 1000000ULL; // 500,000 clock cycles max
    unsigned long long hc = 0;

    while (!contextp->gotFinish() && hc < max_half_cycles) {
        if (hc >= 12) {
            top->rst_ni = 1;
        }
        top->clk_i = (hc & 1ULL) ? 1 : 0;
        top->eval();
        contextp->timeInc(5);
        ++hc;
    }

    if (!contextp->gotFinish()) {
        std::fprintf(stderr, "SIM_TIMEOUT: exceeded %llu clock cycles without $finish\n",
                     max_half_cycles / 2ULL);
        top->final();
        delete top;
        delete contextp;
        return 1;
    }

    top->final();
    delete top;
    delete contextp;
    return 0;
}
