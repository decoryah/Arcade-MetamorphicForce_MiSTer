//------------------------------------------------------------------------------
// K053250 "LVC" line-scroll / zoom plane (Metamorphic Force's SUB1 layer).
//
// Semantics are MAME's k053250.cpp (k053250_device::draw / pdraw_scanline32 /
// dma), which is the spec the benches compare with (sim/tb_lvc.cpp carries a
// transcription of it). In short:
//
//   * 16 KB of line RAM on the 68000 bus. A DMA (the falling edge of bit 1 of
//     register 4, at most once a frame) copies its first 2,048 words into one of
//     two buffers and flips the page; a picture is drawn from the buffer of the
//     page the NEXT DMA writes, i.e. the data of the DMA before the latest.
//   * A "scanline" is four words: colour, ROM offset (256 pixels a unit), zoom and
//     a signed scroll. Register 4 selects: bit 0 clear = the scanlines are
//     columns (X and Y swapped), bit 2 = no source clipping, bit 3 / bit 4 =
//     flip X / flip Y, bits 7:5 = the source size and wrap.
//   * Pixels are 4 bits (two to a ROM byte, high nibble first); 0 is transparent,
//     the palette entry is {palette base SUB1, colour, pixel}.
//
// The drawing is done a picture row at a time, as the other renderers here, into
// a line buffer the mixer scans out. In the normal orientation a row is one
// scanline; in the swapped orientation a row takes one pixel from each of the
// 288 columns, whose parameters (from the same buffer) are worked out once a
// frame into a table, and whose ROM groups are cached per column.
//
// One pixel is evaluated as (MAME: src_fx = HALF - flip + k * (zoom << 10),
// idx = src_fx >> 16, folded to 6-bit fractions):
//   clip   (source clipping on):  k = pos' + scroll, drawn while k >= 0 and
//          (k + 1) * zoom <= (clipmask + 1) << 6 (zoom 0: k <= clipmask),
//          idx = (k * zoom + 32 - flip) >> 6
//   noclip: idx = (((scroll + pos') * zoom + 32 - flip) >> 6) & wrapmask
// where pos' is the position along the scanline, mirrored when it is flipped.
//
// The 68000 is held (dma_busy) from the trigger until the copy is done, so the
// copy is the RAM as it was when the register was written.
//------------------------------------------------------------------------------
`default_nettype none

module k053250_lvc #(
    parameter int VIS_W  = 288,
    parameter int VIS_H  = 224,
    parameter int ABS_X0 = 24,       // MAME's absolute x of the first visible pixel (cliprect.min_x)
    parameter int ABS_Y0 = 15,       // ... y of the first visible row
    parameter int VIS_Y0 = 17,       // raster line of the first visible row
    parameter logic signed [15:0] OFFX = -16'sd7,   // K053250(config, ..., -7, 0)
    parameter logic signed [15:0] OFFY = 16'sd0
) (
    input  logic        clk,
    input  logic        reset,

    // the chip's registers as the 68000 wrote them (low bytes)
    input  logic  [7:0] regs [8],

    // 68000 side: the line RAM
    input  logic        cpu_we,
    input  logic [12:0] cpu_addr,        // word address, for the write and the read
    input  logic  [1:0] cpu_be,
    input  logic [15:0] cpu_wdata,
    output logic [15:0] cpu_rq,          // one clock after cpu_addr
    output logic        dma_busy,        // the 68000 waits while the RAM is copied

    input  logic        frame_tick,      // once a frame: re-arms the DMA's once-a-frame limiter
    input  logic        latch,           // the picture's instant: the buffer to draw from is selected

    // the picture row to render next
    input  logic        line_start,
    input  logic  [8:0] line,            // raster line
    output logic        busy,            // anything in progress (a DMA, a latch, a table build, a row)
    output logic        row_busy,        // a row is being drawn or waits: the overrun test

    // ROM: 64-bit groups (16 pixels), 32K of them
    output logic        rom_req,
    output logic [14:0] rom_addr,
    input  logic        rom_ack,
    input  logic [63:0] rom_q,

    input  logic  [7:0] palbase,         // K055555 PALBASE_SUB1

    // scan-out
    input  logic  [8:0] px,
    output logic [10:0] pix,
    output logic        opaque
);
    // ------------------------------------------------------------------ memories
    logic [11:0] cnt;                    // the copy engines' counter
    logic [1:0][7:0] lram [8192] /*verilator public_flat_rd*/;   // the 68000's 16 KB
    logic [15:0] dma_q;
    always_ff @(posedge clk) begin
        if (cpu_we) begin
            if (cpu_be[1]) lram[cpu_addr][1] <= cpu_wdata[15:8];
            if (cpu_be[0]) lram[cpu_addr][0] <= cpu_wdata[7:0];
        end
        cpu_rq <= lram[cpu_addr];
        dma_q  <= lram[{2'b00, cnt[10:0]}];
    end

    logic        wpage;                  // m_page: the buffer the next DMA writes (the picture is drawn from it)
    logic [15:0] dbuf [4096];            // {page, word}
    logic        dw_we;  logic [10:0] dw_a;
    logic [15:0] lt_q;
    always_ff @(posedge clk) begin
        if (dw_we) dbuf[{wpage, dw_a}] <= dma_q;
        lt_q <= dbuf[{wpage, cnt[10:0]}];
    end

    logic [15:0] fbuf [2048] /*verilator public_flat_rd*/;   // the picture's copy
    logic        fw_we;  logic [10:0] fw_a;
    logic [10:0] fr_a;   logic [15:0] fr_q;
    always_ff @(posedge clk) begin
        if (fw_we) fbuf[fw_a] <= lt_q;
        fr_q <= fbuf[fr_a];
    end

    // ------------------------------------------------------------ latched registers
    logic  [7:0] rg [8];
    wire  [7:0]  ctrl      = rg[4];
    wire         swap_c    = ~ctrl[0];
    wire         nosclip_c = ctrl[2];
    wire         fx_c      = ctrl[3];
    wire         fy_c      = ctrl[4];
    wire  [2:0]  mode_c    = ctrl[7:5];
    wire         wrap500_c = (mode_c == 3'd4);
    wire  [9:0]  wrapm_c   = (mode_c == 3'd0 || mode_c == 3'd4) ? 10'h0ff : (mode_c == 3'd1) ? 10'h1ff : 10'h3ff;
    wire  [9:0]  clipm_c   = nosclip_c ? 10'h000 : wrapm_c;
    wire  [9:0]  dsth_c    = (mode_c == 3'd0) ? 10'd256 : 10'd512;      // virtual bitmap height
    wire         clip_c    = (clipm_c != 10'd0);
    wire  [10:0] clipn_c   = {1'b0, clipm_c} + 11'd1;                   // clipmask + 1 (up to 1024)
    wire  [16:0] bound_c   = {clipn_c, 6'd0};                           // (clipmask + 1) << 6
    // map_scrollx = (short)(regs0 << 8 | regs1) - offx, map_scrolly likewise
    wire signed [19:0] msx = 20'($signed({rg[0], rg[1]})) - 20'(OFFX);
    wire signed [19:0] msy = 20'($signed({rg[2], rg[3]})) - 20'(OFFY);

    localparam int XMAX = ABS_X0 + VIS_W - 1;        // 311
    localparam int YMAX = ABS_Y0 + VIS_H - 1;        // 238

    // ------------------------------------------------------------------ control state
    typedef enum logic [2:0] { M_IDLE, M_DMA, M_LAT, M_TBL0, M_TBL, M_ROW } m_t;
    m_t  m;
    logic r4b1_q, dma_pend, dma_lim, lat_pend, row_pend;
    logic [8:0] row_line;
    wire        r4b1 = regs[4][1];

    // ---------------------------------------------------------------- column table
    // per column: valid, scroll (20 bits signed), zoom, offset block (11 bits), colour
    logic [52:0] ctab [512];
    logic [52:0] ctab_q;
    logic [8:0]  ct_ra, ct_wa;  logic ct_we; logic [52:0] ct_wd;
    always_ff @(posedge clk) begin
        if (ct_we) ctab[ct_wa] <= ct_wd;
        ctab_q <= ctab[ct_ra];
    end

    // ---------------------------------------------------------------- group cache
    // 288 entries, one per column ({valid, tag[14:0], 64 bits}); the normal orientation uses entry 0
    logic [79:0] gc [512];
    logic [79:0] gc_q;
    logic [8:0]  gc_ra, gc_wa; logic gc_we; logic [79:0] gc_wd;
    logic        gc_clr;             // clearing the valid bits after reset
    logic [8:0]  gc_ci;
    always_ff @(posedge clk) begin
        if (gc_we) gc[gc_wa] <= gc_wd;
        gc_q <= gc[gc_ra];
    end

    // ------------------------------------------------------------- line buffer
    logic bank;
    logic [8:0] lbuf [2 << 9];       // {colour[4:0], pixel[3:0]}
    logic [8:0] lb_rd;
    logic       lb_we; logic [8:0] lb_wa; logic [8:0] lb_wd;
    always_ff @(posedge clk) begin
        if (lb_we) lbuf[{bank, lb_wa}] <= lb_wd;
        lb_rd <= lbuf[{~bank, px}];
    end
    // palette entry: (palbase << 8) + (colour << 4) + pixel, modulo the 2,048 entries
    assign pix    = {palbase[2:0], 8'd0} + {2'd0, lb_rd[8:4], 4'd0} + {7'd0, lb_rd[3:0]};
    assign opaque = (lb_rd[3:0] != 4'd0);

    // ------------------------------------------------------------ row working state
    typedef enum logic [4:0] {
        R_E0, R_W0, R_W1, R_W2, R_W3, R_PRM,
        R_U0, R_U1, R_U2, R_UA, R_UB, R_UC, R_UD, R_UE, R_UF, R_UG, R_FD, R_FW
    } r_t;
    r_t  r;
    logic [8:0]  ry;                 // absolute row
    logic [8:0]  ux;                 // unit: pixel (normal) or column (swapped)
    logic        pass;               // 1 = the second pass of a column (drawn after the first, so it wins)
    logic        u_valid;
    logic signed [19:0] u_scroll;    // scanline parameters of the unit
    logic [15:0] u_zoom;
    logic [10:0] u_base;             // ROM offset block, (offset & 0x7ff)
    logic [4:0]  u_color;
    logic [3:0]  u_pen;
    logic        n_skip;             // the normal orientation's scanline is rejected
    logic signed [19:0] n_scroll;
    logic [15:0] n_zoom; logic [10:0] n_base; logic [4:0] n_color;
    logic [15:0] w0, w1, w2;

    logic signed [19:0] e_scroll, e_pos, e_a;
    logic        e_flip, e_ok;
    logic [31:0] e_prod;
    logic [18:0] e_nib;
    logic [14:0] e_grp;
    logic  [3:0] e_sel;

    // position along the scanline for the unit: normal = the pixel, swapped = the row; mirrored when flipped
    wire signed [19:0] pos_n = fx_c ? 20'(XMAX) - 20'($signed({11'd0, ux})) : 20'(ABS_X0) + 20'($signed({11'd0, ux}));
    wire signed [19:0] pos_s = fy_c ? 20'(ABS_Y0 + YMAX) - 20'($signed({11'd0, ry})) : 20'($signed({11'd0, ry}));

    // the table build
    logic [8:0] tc;                  // column
    logic signed [19:0] tcorr;       // swapped: map_scrolly, or 0x100 - map_scrolly - 2
    logic [2:0] tph;
    // (linedata_offs = map_scrollx, - 5 if flipped in Y, + 311 and walked backwards if flipped in X; the first
    // column is the one at x = 24)
    wire signed [19:0] t_base = msx - (fy_c ? 20'sd5 : 20'sd0);
    wire  [8:0] t_entry = fx_c ? 9'(t_base + 20'(XMAX - ABS_X0) - 20'($signed({11'd0, tc})))
                               : 9'(t_base + 20'(ABS_X0) + 20'($signed({11'd0, tc})));

    // the normal orientation's entry for the row
    wire signed [19:0] ry_s    = 20'($signed({11'd0, ry}));
    wire signed [19:0] n_rsign = fy_c ? (20'sd0 - ry_s) : ry_s;
    wire  [8:0] n_entry = 9'(msy + (fy_c ? 20'(YMAX) : 20'sd0) + n_rsign);

    assign busy = (m != M_IDLE) || row_pend;
    // a row not finished is what the video counts as an overrun; a DMA or a latch in progress at a line's start only
    // delays the row (rows go first, then these) and has the rest of the line to spare
    assign row_busy = (m == M_ROW) || row_pend;

    // the nibble of a group
    function automatic logic [3:0] nib_of(input logic [63:0] g, input logic [3:0] j);
        return g[63 - {j, 2'b00} -: 4];
    endfunction

    always_ff @(posedge clk) begin
        dw_we <= 1'b0; fw_we <= 1'b0; ct_we <= 1'b0; gc_we <= 1'b0; lb_we <= 1'b0;
        r4b1_q <= r4b1;
        if (reset) begin
            m <= M_IDLE; dma_busy <= 1'b0; dma_pend <= 1'b0; dma_lim <= 1'b0; lat_pend <= 1'b0;
            wpage <= 1'b0; bank <= 1'b0; rom_req <= 1'b0; row_pend <= 1'b0; r <= R_E0;
            gc_clr <= 1'b1; gc_ci <= '0; cnt <= '0;
            for (int i = 0; i < 8; i++) rg[i] <= 8'd0;
        end else begin
            // the once-a-frame limiter re-arms at the start of a frame
            if (frame_tick) dma_lim <= 1'b0;
            // the falling edge of register 4 bit 1 starts a DMA: the 68000 waits from here
            if (r4b1_q && !r4b1 && !dma_lim) begin dma_pend <= 1'b1; dma_busy <= 1'b1; end
            if (latch) lat_pend <= 1'b1;
            // the line buffers' banks flip at the line's start, as the other renderers' do: the scan-out of the row
            // being displayed reads the bank that is not written, and a row that has to wait for a DMA or a latch
            // must not move the scan-out to the bank it is about to write
            if (line_start) begin row_pend <= 1'b1; row_line <= line; bank <= ~bank; end

            // the group cache's valid bits are cleared once, after reset
            if (gc_clr) begin
                gc_we <= 1'b1; gc_wa <= gc_ci; gc_wd <= 80'd0;
                gc_ci <= gc_ci + 9'd1;
                if (gc_ci == 9'd511) gc_clr <= 1'b0;
            end

            case (m)
                M_IDLE: begin
                    cnt <= 12'd0;
                    if (gc_clr) begin
                        // wait
                    end else if (row_pend) begin
                        // a row has a deadline: it goes first
                        row_pend <= 1'b0; m <= M_ROW; r <= R_E0;
                        ry <= row_line - 9'(VIS_Y0 - ABS_Y0);
                    end else if (dma_pend) begin
                        dma_pend <= 1'b0; dma_lim <= 1'b1; m <= M_DMA;
                    end else if (lat_pend) begin
                        lat_pend <= 1'b0; m <= M_LAT;
                        for (int i = 0; i < 8; i++) rg[i] <= regs[i];       // the registers as of the picture's instant
                    end
                end

                // DMA: ram[0..0x7ff] -> dbuf[wpage]. cnt addresses the read; the word is back a clock later
                // and is written then (dw_we / dw_a registered with it).
                M_DMA: begin
                    cnt <= cnt + 12'd1;
                    if (cnt < 12'd2048) begin dw_we <= 1'b1; dw_a <= cnt[10:0]; end
                    if (cnt == 12'd2048) begin
                        dma_busy <= 1'b0;                   // (a second trigger cannot come before the next frame)
                        wpage <= ~wpage; m <= M_IDLE;
                    end
                end

                // latch: dbuf[wpage] -> fbuf (the picture's buffer)
                M_LAT: begin
                    cnt <= cnt + 12'd1;
                    if (cnt < 12'd2048) begin fw_we <= 1'b1; fw_a <= cnt[10:0]; end
                    if (cnt == 12'd2048) begin
                        m <= swap_c ? M_TBL0 : M_IDLE;
                        tc <= 9'd0; tph <= 3'd0;
                    end
                end

                // the column table (swapped orientation): four words a column
                M_TBL0: begin
                    tcorr <= fy_c ? (20'sd256 - msy - 20'sd2) : msy;
                    m <= M_TBL;
                end
                M_TBL: begin
                    case (tph)
                        3'd0: begin fr_a <= {t_entry, 2'd0}; tph <= 3'd1; end
                        3'd1: begin fr_a <= {t_entry, 2'd1}; tph <= 3'd2; end
                        3'd2: begin fr_a <= {t_entry, 2'd2}; w0 <= fr_q; tph <= 3'd3; end
                        3'd3: begin fr_a <= {t_entry, 2'd3}; w1 <= fr_q; tph <= 3'd4; end
                        3'd4: begin w2 <= fr_q; tph <= 3'd5; end
                        3'd5: begin : tbl_scroll
                            logic signed [19:0] sc;
                            // fr_q = the scroll word
                            sc = 20'($signed(fr_q));
                            if (wrap500_c && $signed(fr_q) >= 16'sh0500) sc = sc - 20'sd2048;
                            sc = sc + tcorr;
                            if (clip_c) sc = {10'd0, sc[9:0] & (dsth_c - 10'd1)};
                            ct_we <= 1'b1; ct_wa <= tc;
                            ct_wd <= { !(w0 == 16'hffff) && !(w0[7:0] == 8'd0 && w1 == 16'd0),
                                       sc, w2, w1[10:0], w0[4:0] };
                            tph <= 3'd0;
                            if (tc == 9'(VIS_W - 1)) m <= M_IDLE;
                            else tc <= tc + 9'd1;
                        end
                        default: tph <= 3'd0;
                    endcase
                end

                // a picture row
                M_ROW: begin
                    case (r)
                        R_E0: begin
                            ux <= 9'd0; pass <= 1'b0;
                            if (swap_c) r <= R_U0;
                            else begin fr_a <= {n_entry, 2'd0}; r <= R_W0; end
                        end
                        // normal orientation: the row's four words (a clock behind the address)
                        R_W0: begin fr_a <= {n_entry, 2'd1}; r <= R_W1; end
                        R_W1: begin fr_a <= {n_entry, 2'd2}; w0 <= fr_q; r <= R_W2; end
                        R_W2: begin fr_a <= {n_entry, 2'd3}; w1 <= fr_q; r <= R_W3; end
                        R_W3: begin w2 <= fr_q; r <= R_PRM; end
                        R_PRM: begin : prm
                            logic signed [19:0] sc;
                            // fr_q = the scroll word
                            sc = 20'($signed(fr_q));
                            if (wrap500_c && $signed(fr_q) >= 16'sh0500) sc = sc - 20'sd2048;
                            sc = sc + (fx_c ? -msx : msx);
                            n_scroll <= sc; n_zoom <= w2; n_base <= w1[10:0]; n_color <= w0[4:0];
                            n_skip <= (w0 == 16'hffff) || (w0[7:0] == 8'd0 && w1 == 16'd0);
                            r <= R_U1;
                        end

                        // unit start: the swapped orientation reads the column's table entry
                        R_U0: begin ct_ra <= ux; r <= R_U1; end
                        R_U1: begin
                            if (swap_c) r <= R_U2;          // the table word arrives one clock later
                            else begin
                                u_valid <= !n_skip; u_scroll <= n_scroll; u_zoom <= n_zoom;
                                u_base <= n_base; u_color <= n_color;
                                pass <= 1'b0;
                                r <= R_UA;
                            end
                        end
                        R_U2: begin
                            u_valid <= ctab_q[52]; u_scroll <= ctab_q[51:32]; u_zoom <= ctab_q[31:16];
                            u_base  <= ctab_q[15:5]; u_color <= ctab_q[4:0];
                            pass    <= clip_c;              // the second pass is drawn last, so it is tried first
                            r <= R_UA;
                        end

                        // evaluate the pass: a = k (clip) or scroll + pos' (noclip)
                        R_UA: begin
                            if (!u_valid) begin
                                u_pen <= 4'd0; r <= R_FW;
                            end else begin
                                e_scroll <= u_scroll - (pass ? 20'($signed({10'd0, dsth_c})) : 20'sd0);
                                e_pos    <= swap_c ? pos_s : pos_n;
                                e_flip   <= swap_c ? fy_c : fx_c;
                                r <= R_UB;
                            end
                        end
                        R_UB: begin e_a <= e_scroll + e_pos; r <= R_UC; end
                        R_UC: begin e_prod <= {16'd0, e_a[15:0]} * {16'd0, u_zoom}; r <= R_UD; end
                        R_UD: begin : ud
                            logic [32:0] kz;
                            logic [31:0] t;
                            logic [10:0] idx;
                            logic        ok;
                            kz = {1'b0, e_prod} + {17'd0, u_zoom};      // (k + 1) * zoom
                            if (clip_c) begin
                                // exact for k < 2^11, the only ones that can draw
                                ok = !e_a[19] && (e_a[18:11] == 8'd0) &&
                                     ((u_zoom == 16'd0) ? (e_a[10:0] <= {1'b0, clipm_c}) : (kz <= {16'd0, bound_c}));
                                t   = e_prod + 32'd32 - {31'd0, e_flip};
                                idx = t[16:6];
                            end else begin
                                ok  = 1'b1;
                                t   = {16'd0, e_prod[15:0] + 16'd32 - {15'd0, e_flip}};
                                idx = {1'b0, t[15:6] & wrapm_c};
                            end
                            e_ok  <= ok;
                            e_nib <= {u_base, 8'd0} + {8'd0, idx};
                            r <= R_UE;
                        end
                        // the group: cache read
                        R_UE: begin
                            e_grp <= e_nib[18:4]; e_sel <= e_nib[3:0];
                            gc_ra <= swap_c ? ux : 9'd0;
                            if (!e_ok) begin
                                if (pass) begin pass <= 1'b0; r <= R_UA; end
                                else begin u_pen <= 4'd0; r <= R_FW; end
                            end else r <= R_UF;
                        end
                        R_UF: r <= R_UG;                    // the cache's registered read
                        R_UG: begin
                            if (gc_q[79] && gc_q[78:64] == e_grp) begin
                                u_pen <= nib_of(gc_q[63:0], e_sel);
                                if (nib_of(gc_q[63:0], e_sel) == 4'd0 && pass) begin pass <= 1'b0; r <= R_UA; end
                                else r <= R_FW;
                            end else begin
                                rom_req <= 1'b1; rom_addr <= e_grp; r <= R_FD;
                            end
                        end
                        R_FD: if (rom_ack) begin
                            rom_req <= 1'b0;
                            gc_we <= 1'b1; gc_wa <= swap_c ? ux : 9'd0; gc_wd <= {1'b1, e_grp, rom_q};
                            u_pen <= nib_of(rom_q, e_sel);
                            if (nib_of(rom_q, e_sel) == 4'd0 && pass) begin pass <= 1'b0; r <= R_UA; end
                            else r <= R_FW;
                        end
                        // write the pixel, next unit
                        R_FW: begin
                            lb_we <= 1'b1; lb_wa <= ux; lb_wd <= {u_color, u_pen};
                            if (ux == 9'(VIS_W - 1)) m <= M_IDLE;
                            else begin
                                ux <= ux + 9'd1;
                                r <= swap_c ? R_U0 : R_U1;
                            end
                        end
                        default: m <= M_IDLE;
                    endcase
                end
                default: m <= M_IDLE;
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{e_a[19:16], 1'b0};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
