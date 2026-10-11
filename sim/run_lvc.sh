#!/bin/sh
# The K053250 differential bench: rtl/k053250_lvc.sv against a transcription of MAME's k053250_device::draw (lvc_ref.h)
# on random line RAM, registers, ROM and frame timing.
#   sim/run_lvc.sh [cases, default 20] [seed, default 1] [ROM latency in clocks, default 6] [control byte, e.g. 0x82]
#                  [slow, 1 = scan out at the pixel rate with a DMA delaying the next row]
set -e
cd "$(dirname "$0")"
verilator --cc --exe --build -j ${JOBS:-8} -O2 -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT \
    -Wno-PINCONNECTEMPTY -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-PROCASSWIRE -Wno-SYNCASYNCNET -Wno-BLKSEQ \
    --top-module tb_lvc_top --prefix Vtb_lvc_top -Mdir obj_lvc \
    ../rtl/k053250_lvc.sv tb_lvc_top.sv tb_lvc.cpp > obj_lvc.log 2>&1 || { tail -30 obj_lvc.log; exit 1; }
./obj_lvc/Vtb_lvc_top +cases=${1:-20} +seed=${2:-1} +lat=${3:-6} ${4:+ +ctrl=$4} ${5:+ +slow=$5}
