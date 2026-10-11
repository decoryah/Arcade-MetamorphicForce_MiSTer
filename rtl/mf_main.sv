//------------------------------------------------------------------------------
// Metamorphic Force main board: 68000 @ 16 MHz and everything on its bus.
//
// Address decode follows docs/hardware.md section 3 (MAME's metamrph_map in
// mystwarr.cpp). The CPU is TG68K.C, paced by a token bucket the way the
// S.T.U.N. Runner core paces its 68010 -- STEP_COST_BUS/STEP_COST_INT/STEP_GAIN
// set the step rate; the values are calibrated against MAME's frame timing.
//
// Derived from the Monster Maulers core's main board (itself the Gaiapolis core's,
// plasticbugs' Pocket core): the same chip set sits on this board. What differs is
// the map (everything in 2xxxxx/3xxxxx), two scanline interrupts instead of the
// vblank one, the K053250 line-scroll plane in place of the K053936, no K055550 /
// K054000, four players' inputs, and the 4bpp tile and sprite ROM readbacks.
//
// What lives here: work RAM, K056832 tile RAM (all 16 pages, one visible
// through the banked window), palette, sprite RAM, the K053250's registers (its
// RAM is in k053250_lvc), and the register files of every video chip, exported to
// the renderers. Renderers read the memories through their own ports.
//
// The ROM-readback windows are real. The self-test checksums every graphics ROM
// through them. They share the renderers' ROM ports through arbiters that give
// the renderer priority.
//   310000  K056832 mw_rom_word_r: bank regs[0x1a]|regs[0x1b]<<16 (mod 256)
//           selects 2048 groups of four chunky bytes (and a never-fitted fifth
//           plane byte, 0); a word is one half of a group, or with regsb[2]
//           bit 3 a spread of the fifth plane's bits (all 0 here).
//   244000  K055673 k055673_rom_word_r (4bpp): u16 view of the sprite ROM at the
//           offset in k053246 regs 6/7/4.
//   320000  K053250 rom_r: a byte of its ROM, 0x800 * regs[7] + offset / 2.
//------------------------------------------------------------------------------
`default_nettype none

module mf_main #(
    parameter int STEP_COST_BUS = 16, // tokens per kernel step that runs a bus cycle: 4 clocks, as the 68000's
    parameter int STEP_COST_INT = 8,  // tokens per internal step: 2 clocks
    parameter int STEP_GAIN = 4       // tokens per cen_16m: 4 tokens = one 16 MHz clock
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_16m,

    // program ROM, 2 MB
    output logic        rom_req,
    output logic [22:1] rom_addr,
    input  logic        rom_ack,
    input  logic [15:0] rom_q,

    // K053250 ROM, for its readback window (shared with the renderer's port): 64-bit groups
    output logic        lrom_req,
    output logic [14:0] lrom_addr,
    input  logic        lrom_ack,
    input  logic [63:0] lrom_q,
    // tile ROM (K056832 readback) and sprite ROM (K055673 readback)
    output logic        trom_req,
    output logic [18:0] trom_addr,      // a row of 8 pixels
    input  logic        trom_ack,
    input  logic [39:0] trom_q,         // {4 chunky bytes, the fifth plane's byte (0)}
    output logic        srom_req,
    output logic [19:0] srom_addr,      // 16-pixel row
    input  logic        srom_ack,
    input  logic [79:0] srom_q,         // {the four planes' 64 bits, 16 zero bits}

    // the two scanline interrupts, one clock each (IRQ5 only if the K053246's register 5 bit 4 is set)
    input  logic        irq6_set,
    input  logic        irq5_set,

    // inputs, active low as the board sees them
    input  logic [15:0] in_p1_p3,       // 274000: P1 low byte, P3 high byte
    input  logic [15:0] in_p2_p4,       // 274002
    input  logic  [7:0] in0,            // 278000: coins, service
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic  [7:0] in1,            // 278002: bits 1:0 are replaced by the EEPROM's DO and READY
    /* verilator lint_on UNUSEDSIGNAL */

    // ER5911 serial EEPROM
    output logic        eep_di,
    output logic        eep_cs,
    output logic        eep_clk,
    input  logic        eep_do,
    input  logic        eep_ready,

    // K054321 main side: byte registers at word offsets 0..15 (the low byte of each word)
    output logic        snd_wr,
    output logic        snd_rd,
    output logic  [3:0] snd_off,
    output logic  [7:0] snd_wdata,
    input  logic  [7:0] snd_rdata,
    output logic        snd_irq,        // 264000 write: Z80 IRQ0

    // video chip register files
    output logic [15:0] k56regs  [32],
    output logic [15:0] k56regsb [4],
    output logic  [7:0] k55regs  [48],
    output logic [15:0] k38regs  [16],
    output logic  [7:0] k46regs  [8],
    output logic [15:0] k47regs  [8],
    output logic  [7:0] k50regs  [8],

    // the K053250's line RAM lives in its renderer: this is its bus
    output logic        lvc_we,
    output logic [12:0] lvc_addr,
    output logic  [1:0] lvc_be,
    output logic [15:0] lvc_wdata,
    input  logic [15:0] lvc_rq,
    input  logic        lvc_dma_busy,   // the chip's DMA holds the bus

    // memories the renderers read
    // tile RAM lives outside; the CPU window's accesses go out as
    // request/ack, writes byte-enabled, and the kernel waits for them
    output logic        vc_req,
    output logic        vc_we,
    output logic [15:0] vc_addr,
    output logic  [1:0] vc_be,
    output logic [15:0] vc_wdata,
    input  logic        vc_ack,
    input  logic [15:0] vc_q,
    input  logic [10:0] sram_raddr,
    output logic [15:0] sram_q,
    input  logic [10:0] pal_raddr,
    output logic [23:0] pal_q,

    // diagnostics
    output logic [23:0] dbg_addr,
    output logic [15:0] dbg_data,       // data_in of the last completed read
    output logic  [1:0] dbg_busstate,
    output logic        dbg_step,
    output logic        dbg_irq5,
    output logic        dbg_irq6,
    output logic        dbg_spr_we          // a CPU write into the sprite RAM (benches)
);
    // ------------------------------------------------------------ TG68K
    logic        clkena;
    logic [15:0] data_in;
    logic  [2:0] ipl_n;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] addr_out;   // a 68000 has 24 address lines and no A0
    /* verilator lint_on UNUSEDSIGNAL */
    logic [15:0] data_write;
    logic        nWr, nUDS, nLDS;
    logic  [1:0] busstate;
    logic        nResetOut;
    logic [31:0] regin_out, vbr_out;
    logic  [3:0] cacr_out;
    logic  [2:0] fc;
    logic        longword, clr_berr, skipFetch;
    logic  [2:0] step_gap;

    TG68KdotC_Kernel cpu (
        .clk            ( clk ),
        .nReset         ( ~reset ),
        .clkena_in      ( clkena ),
        .data_in        ( data_in ),
        .IPL            ( ipl_n ),
        .IPL_autovector ( 1'b1 ),
        .berr           ( 1'b0 ),
        .CPU            ( 2'b00 ),          // 68000
        .addr_out       ( addr_out ),
        .data_write     ( data_write ),
        .nWr            ( nWr ),
        .nUDS           ( nUDS ),
        .nLDS           ( nLDS ),
        .busstate       ( busstate ),
        .longword       ( longword ),
        .nResetOut      ( nResetOut ),
        .FC             ( fc ),
        .clr_berr       ( clr_berr ),
        .skipFetch      ( skipFetch ),
        .regin_out      ( regin_out ),
        .CACR_out       ( cacr_out ),
        .VBR_out        ( vbr_out )
    );

    wire [23:1] A       = addr_out[23:1];
    wire        is_wr   = (busstate == 2'b11);
    wire  [5:0] step_cost = (busstate == 2'b01 || skipFetch) ? 6'(STEP_COST_INT) : 6'(STEP_COST_BUS);
    wire        uds     = ~nUDS;             // D15:8
    wire        lds     = ~nLDS;             // D7:0
    wire  [15:0] wdat   = data_write;
    assign dbg_addr     = {A, 1'b0};
    assign dbg_data     = data_in;
    assign dbg_busstate = busstate;

    // --------------------------------------------------------- decode (MAME's metamrph_map)
    wire sel_rom    = (A[23:21] == 3'b000);                     // 000000-1fffff
    wire sel_wram   = (A[23:16] == 8'h20);                      // 200000-20ffff
    wire sel_sprram = (A[23:12] == 12'h210);                    // 210000-210fff  K053247 RAM
    // 211000-213fff  plain RAM: the game never uses it, but the power-on test checks 0x210000-0x213fff (16 KB: sprite RAM and
    // these 12 KB, a pattern a 4 KB block) and halts on an error. Nothing above 213fff was touched in 60,000 frames of play
    // (tools/lua/ram_use.lua), so 214000-21ffff reads zero and ignores writes.
    wire sel_oram   = (A[23:16] == 8'h21) && (A[15:14] == 2'b00) && (A[13:12] != 2'b00);
    wire sel_k46    = (A[23:3]  == 21'h048000);                 // 240000-240007
    wire sel_sprrb  = (A[23:4]  == 20'h24400);                  // 244000-24400f  sprite ROM readback
    wire sel_k47    = (A[23:4]  == 20'h24401);                  // 244010-24401f
    wire sel_lvcram = (A[23:14] == 10'h093);                    // 24c000-24ffff
    wire sel_lvcreg = (A[23:4]  == 20'h25000);                  // 250000-25000f
    wire sel_k338   = (A[23:5]  == 19'h12a00);                  // 254000-25401f
    wire sel_k555   = (A[23:8]  == 16'h2580);                   // 258000-2580ff
    wire sel_k252   = (A[23:5]  == 19'h13000);                  // 260000-26001f
    wire sel_sndirq = (A[23:1]  == 23'h132000);                 // 264000
    wire sel_k321   = (A[23:5]  == 19'h13400);                  // 268000-26801f
    wire sel_vsccs  = (A[23:3]  == 21'h04d800);                 // 26c000-26c007
    wire sel_vacset = (A[23:6]  == 18'h09c00);                  // 270000-27003f
    wire sel_p13    = (A[23:1]  == 23'h13a000);                 // 274000
    wire sel_p24    = (A[23:1]  == 23'h13a001);                 // 274002
    wire sel_in0    = (A[23:1]  == 23'h13c000);                 // 278000
    wire sel_in1    = (A[23:1]  == 23'h13c001);                 // 278002
    wire sel_eep    = (A[23:1]  == 23'h13e000);                 // 27c000 (a read is the watchdog)
    wire sel_vram   = (A[23:14] == 10'h0c0);                    // 300000-303fff (mirror at 302000)
    wire sel_tmrb   = (A[23:13] == 11'h188);                    // 310000-311fff  tile ROM readback
    wire sel_lvcrb  = (A[23:13] == 11'h190);                    // 320000-321fff  K053250 ROM readback
    wire sel_pal    = (A[23:13] == 11'h198);                    // 330000-331fff

    // -------------------------------------------------------- memories
    // work RAM 32K x 16, byte lanes
    logic [1:0][7:0] wram [32768];
    logic [15:0] wram_q;
    // palette: two 16-bit words per entry (00RR, GGBB), each a byte-enabled
    // RAM in Quartus's template form so it infers rather than becoming 64K
    // registers; the CPU and the mixer each read a copy
    logic [1:0][7:0] pal0 [2048] /*verilator public_flat_rd*/;
    logic [1:0][7:0] pal1 [2048] /*verilator public_flat_rd*/;
    logic [1:0][15:0] pal_cpu_q, pal_rd_q;
    logic        pal_we;
    logic [10:0] pal_waddr;
    logic  [1:0] pal_wsel;             // which word, {word1, word0}
    logic  [1:0] pal_wbe;              // {uds, lds}
    logic [15:0] pal_wdata;
    always_ff @(posedge clk) begin
        if (pal_we && pal_wsel[0]) begin
            if (pal_wbe[1]) pal0[pal_waddr][1] <= pal_wdata[15:8];
            if (pal_wbe[0]) pal0[pal_waddr][0] <= pal_wdata[7:0];
        end
        pal_cpu_q[0] <= pal0[A[12:2]];
        pal_rd_q[0]  <= pal0[pal_raddr];
    end
    always_ff @(posedge clk) begin
        if (pal_we && pal_wsel[1]) begin
            if (pal_wbe[1]) pal1[pal_waddr][1] <= pal_wdata[15:8];
            if (pal_wbe[0]) pal1[pal_waddr][0] <= pal_wdata[7:0];
        end
        pal_cpu_q[1] <= pal1[A[12:2]];
        pal_rd_q[1]  <= pal1[pal_raddr];
    end
    // sprite RAM: the K053247's 2,048 words, direct; and the 4 KB of plain RAM after it
    logic [15:0] sram [2048] /*verilator public_flat_rd*/;
    logic [15:0] sram_cpu_q;
    logic [15:0] oram [6144];                                   // 211000-213fff
    wire  [12:0] oram_a = {A[13:12] - 2'd1, A[11:1]};           // word index inside it
    logic [15:0] oram_q;
    // K053252 bytes (kept so reads return what was written)
    logic  [7:0] k252 [16];

    // tile-RAM page select: regs[0x19] bits {4:3, 1:0}, or the external
    // linescroll page when regs[0] bit 1 is set (not fitted on this board)
    wire [3:0] vram_page = {k56regs[25][4:3], k56regs[25][1:0]};
    wire       vram_ext  = k56regs[0][1];
    wire [15:0] vram_cpu_addr = {vram_page, A[12:1]};

    always_ff @(posedge clk) begin
        wram_q      <= wram[A[15:1]];
        sram_cpu_q  <= sram[A[11:1]];
        oram_q      <= oram[oram_a];
        sram_q      <= sram[sram_raddr];
    end
    // xRGB888 across the two words: word0 = 00RR, word1 = GGBB
    assign pal_q = {pal_rd_q[0][7:0], pal_rd_q[1]};

    // the K053250's bus: a write is presented a clock after the step with its own address, data and
    // enables registered (the kernel's move on); otherwise the address follows the bus for the read
    logic [12:0] lvc_a_r;
    logic [15:0] lvc_d_r;
    logic  [1:0] lvc_b_r;
    assign lvc_addr  = lvc_we ? lvc_a_r : A[13:1];
    assign lvc_wdata = lvc_d_r;
    assign lvc_be    = lvc_b_r;
    logic  [7:0] lvc_regs [8];                           // the K053250's registers, a byte in the low half of a word

    // ------------------------------------------------- bus sequencer
    typedef enum logic [3:0] {
        B_IDLE, B_RAM_RD, B_WAIT_ROM, B_WAIT_TROM, B_SROM_PREP, B_WAIT_SROM, B_WAIT_VRAM, B_WAIT_VRAMW, B_WAIT_LROM
    } bst_t;
    bst_t bst;
    logic [5:0]  tok;
    logic        irq5_pend, irq6_pend;
    logic [15:0] rd_mux;
    logic [15:0] in1_word;

    // level 6 over level 5 (the IPL pins are active low)
    assign ipl_n = irq6_pend ? 3'b001 : irq5_pend ? 3'b010 : 3'b111;

    // K056832 readback (k056832_device::mw_rom_word_r). The bank is the low byte
    // of regs[0x1a] | regs[0x1b] << 16 (MAME takes it modulo the region's 640 banks;
    // only the first 256 hold ROM). A bank is 2048 groups, which is the window.
    /* verilator lint_off UNUSEDSIGNAL */
    wire  [7:0] tile_bank   = k56regs[26][7:0];
    wire [19:0] trom_g_w    = {1'b0, tile_bank, 11'd0} + {9'd0, A[12:2]};        // two words a group: group = offset >> 1
    wire [19:0] trom_g_p    = {1'b0, tile_bank, 11'd0} + {10'd0, A[12:3]};       // fifth plane: group = offset >> 2
    wire        tile_plane5 = k56regsb[2][3];
    // K055673 readback (4bpp): romofs from k053246 regs 6/7/4; window word o = A[3:1]:
    //   u16 index (romofs & ~3) + (o[2] ? 0 : 2) + o[1:0] of the sprite ROM
    wire [23:0] spr_romofs  = {k46regs[6], k46regs[7], k46regs[4]};
    /* verilator lint_on UNUSEDSIGNAL */
    logic [23:0] sr_idx;                // u16 index
    logic  [1:0] srom_sel;              // the word of the 64-bit row
    logic        srom_oor;              // outside the ROM: reads 0
    logic  [3:0] lrom_sel;              // byte of the 64-bit group
    assign dbg_irq5 = irq5_pend;
    assign dbg_irq6 = irq6_pend;
    // MAME's eeprom_r: a low-byte access reads IN1 (its bits 1:0 the EEPROM's DO and READY), otherwise 0
    assign in1_word = lds ? {8'h00, in1[7:2], eep_ready, eep_do} : 16'h0000;

    always_comb for (int i = 0; i < 8; i++) k50regs[i] = lvc_regs[i];

    // sources that answer in one cycle
    always_comb begin
        rd_mux = 16'h0000;
        if      (sel_wram)   rd_mux = wram_q;
        else if (sel_vram)   rd_mux = 16'h0000;            // only the external-linescroll mode reads here
        else if (sel_pal)    rd_mux = A[1] ? pal_cpu_q[1] : pal_cpu_q[0];
        else if (sel_sprram) rd_mux = sram_cpu_q;
        else if (sel_oram)   rd_mux = oram_q;
        else if (sel_lvcram) rd_mux = lvc_rq;
        else if (sel_lvcreg) rd_mux = {8'h00, lvc_regs[A[3:1]]};
        else if (sel_k252)   rd_mux = {8'h00, k252[A[4:1]]};
        else if (sel_p13)    rd_mux = in_p1_p3;
        else if (sel_p24)    rd_mux = in_p2_p4;
        else if (sel_in0)    rd_mux = {8'h00, in0};
        else if (sel_in1)    rd_mux = in1_word;
        else if (sel_k321)   rd_mux = {8'h00, snd_rdata};
        if (sel_tmrb)        rd_mux = 16'h0000;            // a group beyond the ROM
    end

    // the fifth plane's bits as mw_rom_word_r returns them: bit pairs of the byte
    // go to bits 12 and 4, one pair per word of the group
    function automatic logic [15:0] p5(input logic [7:0] t, input logic [1:0] b);
        logic [15:0] r;
        r = 16'h0000;
        case (b)
            2'd0: begin r[12] = t[7]; r[4] = t[6]; end   // (t & 0x80) << 5   | (t & 0x40) >> 2
            2'd1: begin r[12] = t[5]; r[4] = t[4]; end   // (t & 0x20) << 7   | (t & 0x10)
            2'd2: begin r[12] = t[3]; r[4] = t[2]; end   // (t & 0x08) << 9   | (t & 0x04) << 2
            2'd3: begin r[12] = t[1]; r[4] = t[0]; end   // (t & 0x02) << 11  | (t & 0x01) << 4
        endcase
        return r;
    endfunction

    // a CPU step is the 68000's bus cycle: the same sequencing as the Gaiapolis core
    wire cpu_step  = (bst == B_IDLE) && !lvc_dma_busy && (tok >= 6'(step_cost)) && !clkena && (step_gap == 3'd0);
    wire cpu_wr    = cpu_step && (fc != 3'b111) && !(busstate == 2'b01 || skipFetch) && is_wr;
    wire vram_wr   = sel_vram && !vram_ext;

    always_ff @(posedge clk) begin
        clkena   <= 1'b0;
        dbg_step <= 1'b0;
        dbg_spr_we <= 1'b0;
        snd_wr <= 1'b0; snd_rd <= 1'b0; snd_irq <= 1'b0; pal_we <= 1'b0; lvc_we <= 1'b0;
        step_gap <= {step_gap[1:0], clkena};

        if (reset) begin
            bst <= B_IDLE; tok <= '0; step_gap <= '0; irq5_pend <= 1'b0; irq6_pend <= 1'b0; vc_req <= 1'b0;
            rom_req <= 1'b0; trom_req <= 1'b0; srom_req <= 1'b0; lrom_req <= 1'b0;
            eep_di <= 1'b0; eep_cs <= 1'b0; eep_clk <= 1'b0;
            for (int i = 0; i < 32; i++) k56regs[i] <= '0;
            for (int i = 0; i < 4;  i++) k56regsb[i] <= '0;
            for (int i = 0; i < 48; i++) k55regs[i] <= '0;
            for (int i = 0; i < 16; i++) begin k38regs[i] <= '0; k252[i] <= '0; end
            for (int i = 0; i < 8;  i++) begin k46regs[i] <= '0; k47regs[i] <= '0; lvc_regs[i] <= '0; end
        end else begin
            if (cen_16m && tok < 6'd48) tok <= tok + 6'(STEP_GAIN);

            // IRQ6 at the first scanline (MAME line 24), IRQ5 at line 248 if the K053246 enables it:
            // each is asserted and held until the kernel's interrupt-acknowledge cycle (MAME's HOLD_LINE)
            if (irq6_set) irq6_pend <= 1'b1;
            if (irq5_set && k46regs[5][4]) irq5_pend <= 1'b1;

            // ------------------------------------------------ the CPU's step
            case (bst)
                B_IDLE: if (cpu_step) begin
                    if (fc == 3'b111) begin
                        // interrupt acknowledge: the level being served is on A3-A1; the step completes
                        clkena <= 1'b1; tok <= tok - 6'(STEP_COST_BUS); dbg_step <= 1'b1;
                        if (A[3:1] == 3'd6) irq6_pend <= 1'b0;
                        if (A[3:1] == 3'd5) irq5_pend <= 1'b0;
                    end else if (busstate == 2'b01 || skipFetch) begin
                        clkena <= 1'b1; tok <= tok - 6'(STEP_COST_INT); dbg_step <= 1'b1;
                    end else if (is_wr) begin
                        // writes are posted: complete immediately (the dispatch below
                        // turns this into a wait for the external tile RAM)
                        tok <= tok - 6'(STEP_COST_BUS); clkena <= 1'b1; dbg_step <= 1'b1;
                    end else begin
                        // reads
                        tok <= tok - 6'(STEP_COST_BUS);
                        if (sel_rom) begin
                            rom_addr <= A[22:1]; rom_req <= 1'b1; bst <= B_WAIT_ROM;
                        end else if (sel_vram && !vram_ext) begin
                            vc_req <= 1'b1; vc_we <= 1'b0; vc_addr <= vram_cpu_addr; bst <= B_WAIT_VRAM;
                        end else if (sel_lvcrb) begin
                            // a byte of the K053250's ROM at 0x80000 * regs[6] + 0x800 * regs[7] + offset / 2
                            // (regs[6] != 0 is beyond the ROM: MAME reads past its region there; this reads 0)
                            lrom_addr <= 15'(({lvc_regs[7], A[12:2]}) >> 3);
                            lrom_sel  <= {1'b0, A[4:2]};
                            lrom_req  <= (lvc_regs[6] == 8'd0);
                            bst       <= (lvc_regs[6] == 8'd0) ? B_WAIT_LROM : B_RAM_RD;
                        end else if (sel_tmrb) begin
                            if (tile_plane5) begin
                                trom_addr <= trom_g_p[18:0];
                                if (trom_g_p[19]) bst <= B_RAM_RD;           // outside the ROM: reads 0
                                else begin trom_req <= 1'b1; bst <= B_WAIT_TROM; end
                            end else begin
                                trom_addr <= trom_g_w[18:0];
                                if (trom_g_w[19]) bst <= B_RAM_RD;
                                else begin trom_req <= 1'b1; bst <= B_WAIT_TROM; end
                            end
                        end else if (sel_sprrb) begin
                            sr_idx <= {spr_romofs[23:2], 2'b00} + (A[3] ? 24'd0 : 24'd2) + {22'd0, A[2:1]};
                            bst <= B_SROM_PREP;
                        end else begin
                            if (sel_k321) snd_rd <= 1'b1;
                            snd_off <= A[4:1];
                            bst <= B_RAM_RD;
                        end
                    end
                end

                // the sprite ROM's u16 index becomes a row and a word of it
                B_SROM_PREP: begin
                    srom_addr <= sr_idx[21:2];
                    srom_sel  <= sr_idx[1:0];
                    srom_oor  <= (sr_idx[23:22] != 2'd0);
                    srom_req  <= 1'b1;
                    bst <= B_WAIT_SROM;
                end

                // block RAMs and latches answer one cycle after the live address
                B_RAM_RD: begin
                    data_in <= rd_mux; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_ROM: if (rom_ack) begin
                    rom_req <= 1'b0; data_in <= rom_q; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_VRAM: if (vc_ack) begin
                    vc_req <= 1'b0; data_in <= vc_q; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_VRAMW: if (vc_ack) begin
                    vc_req <= 1'b0; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_LROM: if (lrom_ack) begin
                    lrom_req <= 1'b0;
                    data_in <= {8'h00, lrom_q[63 - {lrom_sel[2:0], 3'b000} -: 8]};
                    clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_TROM: if (trom_ack) begin
                    trom_req <= 1'b0;
                    if (tile_plane5) data_in <= p5(trom_q[7:0], A[2:1]);
                    else             data_in <= A[1] ? trom_q[23:8] : trom_q[39:24];
                    clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_SROM: if (srom_oor || srom_ack) begin
                    srom_req <= 1'b0;
                    // (u16*) view on a little-endian host: the low byte is the even byte
                    case (srom_sel)
                        2'd0: data_in <= {srom_q[71:64], srom_q[79:72]};
                        2'd1: data_in <= {srom_q[55:48], srom_q[63:56]};
                        2'd2: data_in <= {srom_q[39:32], srom_q[47:40]};
                        default: data_in <= {srom_q[23:16], srom_q[31:24]};
                    endcase
                    if (srom_oor) data_in <= 16'h0000;
                    clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                default: bst <= B_IDLE;
            endcase

            // ------------------------------------------------ the write dispatch
            // A CPU write by the decode above. (A write the CPU posts has already been
            // completed; the external tile RAM is the exception, which holds the kernel
            // until its ack.)
            if (cpu_wr) begin
                if (sel_wram) begin
                    if (uds) wram[A[15:1]][1] <= wdat[15:8];
                    if (lds) wram[A[15:1]][0] <= wdat[7:0];
                end else if (sel_vram) begin
                    if (!vram_ext) begin
                        vc_req <= 1'b1; vc_we <= 1'b1; vc_addr <= vram_cpu_addr;
                        vc_be <= {uds, lds}; vc_wdata <= wdat;
                        clkena <= 1'b0; dbg_step <= 1'b0; bst <= B_WAIT_VRAMW;
                    end
                end else if (sel_pal) begin
                    pal_we <= 1'b1; pal_waddr <= A[12:2]; pal_wsel <= {A[1], ~A[1]};
                    pal_wbe <= {uds, lds}; pal_wdata <= wdat;
                end else if (sel_sprram) begin
                    dbg_spr_we <= 1'b1;
                    sram[A[11:1]] <= {uds ? wdat[15:8] : sram_cpu_q[15:8],
                                      lds ? wdat[7:0]  : sram_cpu_q[7:0]};
                end else if (sel_oram) begin
                    oram[oram_a] <= {uds ? wdat[15:8] : oram_q[15:8],
                                     lds ? wdat[7:0]  : oram_q[7:0]};
                end else if (sel_lvcram) begin
                    lvc_we <= 1'b1; lvc_a_r <= A[13:1]; lvc_d_r <= wdat; lvc_b_r <= {uds, lds};
                end else if (sel_lvcreg) begin
                    // reg_w: only the low byte (ACCESSING_BITS_0_7) writes
                    if (lds) lvc_regs[A[3:1]] <= wdat[7:0];
                end else if (sel_k46) begin
                    // k053246_w: byte pair per word
                    if (uds) k46regs[{A[2:1], 1'b0}] <= wdat[15:8];
                    if (lds) k46regs[{A[2:1], 1'b1}] <= wdat[7:0];
                end else if (sel_k47) begin
                    k47regs[A[3:1]] <= {uds ? wdat[15:8] : k47regs[A[3:1]][15:8],
                                        lds ? wdat[7:0]  : k47regs[A[3:1]][7:0]};
                end else if (sel_vacset) begin
                    k56regs[A[5:1]] <= {uds ? wdat[15:8] : k56regs[A[5:1]][15:8],
                                        lds ? wdat[7:0]  : k56regs[A[5:1]][7:0]};
                end else if (sel_vsccs) begin
                    k56regsb[A[2:1]] <= {uds ? wdat[15:8] : k56regsb[A[2:1]][15:8],
                                         lds ? wdat[7:0]  : k56regsb[A[2:1]][7:0]};
                end else if (sel_k252) begin
                    if (lds) k252[A[4:1]] <= wdat[7:0];
                end else if (sel_k555) begin
                    // K055555_word_w: low byte if only LDS, else the high byte
                    if (A[7:1] < 7'd48)
                        k55regs[A[6:1]] <= (lds && !uds) ? wdat[7:0] : wdat[15:8];
                end else if (sel_k321) begin
                    // umask16(0x00ff): the low byte
                    if (lds) begin snd_wr <= 1'b1; snd_off <= A[4:1]; snd_wdata <= wdat[7:0]; end
                end else if (sel_k338) begin
                    k38regs[A[4:1]] <= {uds ? wdat[15:8] : k38regs[A[4:1]][15:8],
                                        lds ? wdat[7:0]  : k38regs[A[4:1]][7:0]};
                end else if (sel_eep) begin
                    // mmeeprom_w: the low byte, DI / CS / CLK on its bits 0 / 1 / 2
                    if (lds) begin eep_di <= wdat[0]; eep_cs <= wdat[1]; eep_clk <= wdat[2]; end
                end else if (sel_sndirq) begin
                    snd_irq <= 1'b1;
                end
                // anything else is ignored
            end
        end
    end
endmodule
