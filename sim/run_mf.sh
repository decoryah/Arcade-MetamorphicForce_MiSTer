#!/bin/sh
# The whole-machine bench: mf_core behind mf_mem and a behavioural SDRAM, the real 68000 and Z80 programs from reset.
#   sim/run_mf.sh <image.rom> <eeprom.nv> <frames> <out prefix>
# Environment (see sim/tb_mf.cpp): SKIPBOOT=1 cuts the power-on tests and two splash delays (as tools/lua/dump_state.lua's
# SKIPBOOT=1 does in MAME), BACKDOOR=1 places the image straight into the SDRAM model, SCHED=survey|play and SCHEDLAG=n,
# ENERGY=1, SNAPFRAMES=a,b DUMPSTATE=a,b (tools/cmp_state.py compares the dump with MAME's), TRACE=1, AUDIO=1, ROMCHK=1,
# POSTJMP=<hex> (enter the power-on test chain at an address). About 0.1 MHz: 10 s of wall clock a frame.
set -e
cd "$(dirname "$0")"
IMG="$1"; NV="$2"
[ -f "$IMG" ] && [ -f "$NV" ] && [ -n "$3" ] && [ -n "$4" ] || { echo "usage: $0 <image.rom> <eeprom.nv> <frames> <prefix>" >&2; exit 2; }
case "$IMG" in /*) ;; *) IMG="$PWD/$IMG" ;; esac
case "$NV" in /*) ;; *) NV="$PWD/$NV" ;; esac
verilator --cc --exe --build -j ${JOBS:-8} -O3 -CFLAGS "-march=native" -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME \
    -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE \
    -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST -Wno-PROCASSWIRE -Wno-SYNCASYNCNET \
    +1364-2005ext+v waivers.vlt --top-module tb_mf_top --prefix Vtb_mf_top -Mdir obj_mf \
    ../rtl/*.sv ../modules/cpu-tg68k/gen/tg68k.v ../modules/cpu-tv80/*.v \
    ../target/mister/mf_mem.sv ../target/mister/rom_cache.sv ../target/mister/mem_test.sv ../target/mister/sdram_ctrl.sv \
    sdram_model.sv tb_mf_top.sv tb_mf.cpp > obj_mf.log 2>&1 || { tail -30 obj_mf.log; exit 1; }
./obj_mf/Vtb_mf_top "$IMG" "$NV" "$3" "$4"
