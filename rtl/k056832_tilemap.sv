//------------------------------------------------------------------------------
// K056832 tilemap layers for Metamorphic Force (Konami pre-GX / GX224).
//
// Derived from the Monster Maulers core's tilemap (itself the Gaiapolis core's):
// the same chip. The memory still hands over a tile row as a 40-bit word (four
// chunky bytes and the fifth plane's byte), but this board's tile ROM has no
// fifth plane, so that byte is 0 and a pixel is 4 bits. A pen is the palette entry
// itself, ((layer colour base | tile colour) * 16) + pixel, with the tile
// colour taken as `color >> 2 & 0xf` (MAME's viostorm_tile_callback).
//
// The callback's per-tile mix code (attribute bits 1:0, "category 1") selects a
// separate blend level only through the K055555's V_INMIX_ON, which the game sets
// to 0xff everywhere (every layer's code is then internal), so it is not modelled.
//
// Four layers of 8x8 4bpp tiles, each selecting a rectangle of pages from a
// 4x4 grid of 64x32-tile pages held in 128 KB of tile RAM. Semantics follow
// the Pocket repository's tools/render_model.py, which is pixel-exact against MAME across the
// frozen-state corpus; see docs/hardware.md section 6.
//
// Each display line is rendered into line buffers during the previous line and
// then scanned out, which decouples fetch scheduling from the pixel clock. One
// tile-row fetch serves 8 pixels. The fetch is a three-stage pipeline -- tile
// RAM (attribute and code), tile ROM (the 8-pixel row), emit -- so the two
// memories' latencies overlap each other and the emit; on the Pocket the tile
// RAM is the external SRAM and the ROM an SDRAM burst, ~5 and ~12 clocks. A
// layer then costs about max(RAM, ROM, 8) clocks per group, near 2,500
// clocks for four layers of the 6,144 a 64 us line gives at 96 MHz
// (docs/hardware.md section 11).
//
// Scroll modes: 3 (xy scroll) is what almost every captured frame uses; 0
// (line scroll) and 2 (row scroll) read the per-line/per-8-line X scroll from
// the scroll page in tile RAM. The Hall of Fame screen uses row scroll on two
// layers that are two pages high, with the global Y flip set (its title slides
// in with a different offset for every strip of eight rows): those frames are
// in the checked set, and the entry index for a layer more than one page high
// is the one MAME's loop over the page rows gives (see ls_idx below).
//
// `unsupported` is raised for configurations the model has not been checked
// against, rather than rendering something plausible and wrong:
//   * global screen X flip
//   * a page span of 3 (not a power of two, so the wrap cannot be a mask)
//------------------------------------------------------------------------------
`default_nettype none

module k056832_tilemap #(
    parameter int VIS_W  = 288,      // visible pixels per line
    parameter int VIS_X0 = 24,       // raster x of the first visible pixel
    parameter int LINE_OFS = 2,      // raster line of a picture row minus MAME's absolute y of it (17 - 15)
    parameter int LB_AW  = 9         // ceil(log2(VIS_W))
) (
    input  logic        clk,
    input  logic        reset,

    // Begin rendering the line that is displayed next. `line` is its raster y.
    input  logic        line_start,
    input  logic [ 8:0] line,
    output logic        busy,

    // K056832 VACSET registers and the K055555 per-layer palette bases
    input  logic [15:0] regs      [32],
    input  logic [ 7:0] colorbase [4],

    // Tile RAM: 16 pages x 4096 words. Request/ack: level request, one-cycle
    // ack with the word; a request withdrawn at line_start is dropped.
    output logic        vram_req,
    output logic [15:0] vram_addr,
    input  logic        vram_ack,
    input  logic [15:0] vram_q,

    // Tile ROM: 512K rows of 8 pixels. rom_q[39:32] is the lowest byte of the
    // four chunky ones, so the low four bits of pixel n are rom_q[39-4n -: 4];
    // rom_q[7:0] is the fifth plane, bit 4 of pixel n at rom_q[7-n]. Request/ack
    // so this can sit behind the memory arbiter.
    output logic        rom_req,
    output logic [18:0] rom_addr,
    input  logic        rom_ack,
    input  logic [39:0] rom_q,

    // Scan-out of the completed line.
    input  logic [LB_AW-1:0] px,
    output logic [10:0] pix    [4],      // palette entry
    output logic  [3:0] opaque,

    input  logic        clr_unsup,       // once a frame: the `unsupported` flag is per frame
    output logic        unsupported
);
    // ------------------------------------------------------------- registers
    // flip/palette bit split, k056832_device::get_tile_info
    wire [1:0] fbits = regs[3][7:6];
    logic [2:0] sm_flips;
    logic [5:0] sm_palm1, sm_palm2;
    logic [1:0] sm_pals2;
    always_comb begin
        case (fbits)
            2'd0: begin sm_flips = 3'd6; sm_palm1 = 6'h3f; sm_pals2 = 2'd0; sm_palm2 = 6'h00; end
            2'd1: begin sm_flips = 3'd4; sm_palm1 = 6'h0f; sm_pals2 = 2'd2; sm_palm2 = 6'h30; end
            2'd2: begin sm_flips = 3'd2; sm_palm1 = 6'h03; sm_pals2 = 2'd2; sm_palm2 = 6'h3c; end
            2'd3: begin sm_flips = 3'd0; sm_palm1 = 6'h00; sm_pals2 = 2'd2; sm_palm2 = 6'h3f; end
        endcase
    end

    // metamrph per-layer pixel offsets (mystwarr_v.cpp, VIDEO_START metamrph:
    // set_layer_offs(0, -2+4, 0), (1, 0+4, 0), (2, 2+4, 0), (3, 3+4, 0))
    localparam logic signed [9:0] OFFS_X [4] = '{ 10'sd2, 10'sd4, 10'sd6, 10'sd7 };
    localparam logic signed [9:0] OFFS_Y [4] = '{ 10'sd0, 10'sd0, 10'sd0, 10'sd0 };

    // Global flip (register 0 bits 5:4). Y is supported (this game runs with it set: its data are stored "software
    // Y-flipped"): MAME flips every page's tilemap, so a page's rows come out mirrored, its scroll is taken around
    // the visible area's centre and the K056832's register 0x1e adds a correction. X is not (nothing uses it).
    wire flip_y = regs[0][5];
    wire flip_x = regs[0][4];
    wire signed [10:0] corr_y = regs[30][10:0];            // 11-bit signed vertical offset when flipped
    // MAME's absolute y of the row being rendered (cliprect.min_y is 15 here)
    wire [8:0] line_a = line - 9'(LINE_OFS);

    // ---------------------------------------------------------- line buffers
    // bit 11 marks an opaque pixel; two banks, render one while scanning out
    //
    // One flat array a layer, a power of two deep, addressed {bank, x}. The obvious `lbuf [2][VIS_W]`
    // is 576 words, and Quartus 17 builds it 512 deep (WIDTHAD 9): bank 1's pixels 224..287 landed on
    // bank 0's pixels 0..63, which a simulator never shows -- on the board each text line's first eight
    // characters appeared again at the right edge on alternate lines, and the left edge was damaged.
    logic bank;
    logic [11:0] lbuf0 [2 << LB_AW];
    logic [11:0] lbuf1 [2 << LB_AW];
    logic [11:0] lbuf2 [2 << LB_AW];
    logic [11:0] lbuf3 [2 << LB_AW];

    logic [11:0] rd0, rd1, rd2, rd3;
    always_ff @(posedge clk) begin
        rd0 <= lbuf0[{~bank, px}];
        rd1 <= lbuf1[{~bank, px}];
        rd2 <= lbuf2[{~bank, px}];
        rd3 <= lbuf3[{~bank, px}];
    end
    assign pix[0] = rd0[10:0];
    assign pix[1] = rd1[10:0];
    assign pix[2] = rd2[10:0];
    assign pix[3] = rd3[10:0];
    assign opaque = {rd3[11], rd2[11], rd1[11], rd0[11]};

    // ------------------------------------------------------------------- FSM
    // Layer sequencing (st) wraps three stages that run together:
    //   V  reads the group's attribute and code words from tile RAM,
    //   R  fetches the tile row from ROM,
    //   E  writes the group's pixels into the line buffer.
    // A stage hands its group on when the next one is free, in order, so the
    // line buffer sees exactly the pixel sequence a serial fetch would write.
    typedef enum logic [2:0] { S_IDLE, S_SETUP, S_SCRL, S_SCRL2, S_RUN } state_t;
    state_t st;

    logic  [1:0] cur_l;
    logic [LB_AW-1:0] cur_x;         // E: next line-buffer x
    logic [11:0] vx;                 // E: source x of the pixel being emitted
    logic [10:0] vy;                 // source y, fixed for the line
    logic [11:0] fvx;                // V: source x of the group being fetched
    logic [LB_AW:0] fpx;             // V: first output x of that group
    logic        v_done;             // V: the layer's last group has been fetched

    typedef enum logic [2:0] { V_IDLE, V_ATTR, V_ATTRW, V_CODE, V_CODEW, V_HOLD } vst_t;
    typedef enum logic [1:0] { R_IDLE, R_REQ, R_WAIT, R_HOLD } rst_t;
    vst_t vst;
    rst_t rst;
    logic [15:0] attr_v, code_v;     // V's result
    logic  [3:0] npx_v;
    logic [15:0] attr, code;         // R's copy; attr feeds the decode below
    logic  [3:0] npx_r;
    logic [39:0] rowdata_r;
    logic  [7:0] color_r;
    logic        flipx_r;
    logic        e_busy;             // E
    logic  [3:0] e_cnt;
    logic [39:0] rowdata;
    logic  [7:0] color;
    logic        flipx;   // flipy is applied at fetch time via attr_fy

    wire [4:0] ly       = 5'd8  + {3'd0, cur_l};
    wire [4:0] lx       = 5'd12 + {3'd0, cur_l};
    wire [1:0] rowstart = regs[ly][4:3];
    wire [1:0] rowspan  = regs[ly][1:0];
    wire [1:0] colstart = regs[lx][4:3];
    wire [1:0] colspan  = regs[lx][1:0];

    // page index inside the 4x4 grid, wrapping on the layer's span: a page is 512 x 256
    // pixels, so the column is bits 10:9 of the source x and the row bits 9:8 of the source
    // y (spans of 1, 2 and 4 pages; the Gaiapolis core's expression was right only up to 2)
    wire [1:0] page_r = rowstart + vy[9:8];
    wire [1:0] page_c = colstart + fvx[10:9];
    wire [3:0] page   = {page_r, page_c};
    // word address: page * 4096 + (ty*64 + tx) * 2
    wire [15:0] vram_base = {page, vy[7:3], fvx[8:3], 1'b0};

    // decoded from the latched attribute word, used by R
    wire [3:0] flips4    = {1'b0, sm_flips};
    wire       attr_flip = attr[flips4];        // x flip; y flip feeds attr_fy
    wire [3:0] fliprsel  = {2'd0, cur_l} << 1;   // regs[1] bit pair for this layer
    /* verilator lint_off UNUSEDSIGNAL */
    // NB: the shift is taken on the whole attribute word, not the low six
    // bits -- for every fbits setting except 0 the palette field pulls in
    // attr[7:6], and masking first silently drops them.
    wire [15:0] attr_shifted = attr >> sm_pals2;
    wire [5:0] attr_col6 = (attr[5:0] & sm_palm1) | (attr_shifted[5:0] & sm_palm2);
    /* verilator lint_on UNUSEDSIGNAL */
    // viostorm_tile_callback (Metamorphic Force): color = layer colour base | (color >> 2 & 0x0f)
    wire [3:0] attr_color = attr_col6[5:2];
    wire [2:0] attr_fy   = attr[flips4 + 4'd1] ? ~vy[2:0] : vy[2:0];

    wire [2:0] fx = flipx ? ~vx[2:0] : vx[2:0];
    // the board's tiles are 4bpp (the fifth plane's ROM is not fitted: that byte of the row reads 0)
    wire [3:0] pixel = rowdata[39 - {fx, 2'b00} -: 4];
    // the palette entry: (unit * 16) + pixel, modulo the 2,048 entries
    wire [10:0] pen_e = {color[6:0], pixel};

    // scroll for the layer being set up. Only the low bits survive the page
    // wrap, so the sum is taken at the width the wrap mask needs.
    // Modes 0/2 replace the register X scroll with a word from the scroll
    // page: page regs[0x18] (bits {4:3,1:0}), word (layer << 11 >> 1) +
    // line*2 + 1 for line scroll, + (line >> 3)*16 + 1 for row scroll.
    wire  [3:0] smsel      = {2'd0, cur_l} << 1;
    wire  [1:0] scrollmode = regs[5][smsel +: 2];
    wire  [3:0] scrollbank = {regs[24][4:3], regs[24][1:0]};
    // (the word index, ls_word, is defined below, after scroll_y: it takes the layer's Y scroll)
    logic [15:0] scroll_word;
    wire  [15:0] scroll_reg = scrollmode[0] ? regs[sx_i] : scroll_word;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [4:0] sx_i = 5'd20 + {3'd0, cur_l};
    wire [4:0] sy_i = 5'd16 + {3'd0, cur_l};
    wire signed [16:0] scroll_x = $signed({scroll_reg[15], scroll_reg})
                                - $signed({{7{OFFS_X[cur_l][9]}}, OFFS_X[cur_l]});
    wire signed [16:0] scroll_y = $signed({regs[sy_i][15], regs[sy_i]})
                                + (flip_y ? 17'($signed(corr_y)) : 17'sd0)
                                - $signed({{7{OFFS_Y[cur_l][9]}}, OFFS_Y[cur_l]});
    // The scroll word of the row, a word inside the layer's 1,024-word area of the scroll page
    // (k056832_device::tilemap_draw_common, a layer one page high: its rows start at 0). The words are
    // SOURCE-oriented: a pair (high, low word) of entry `e` scrolls source line e, and only the low word
    // reaches the 512-pixel wrap.
    //   line scroll (mode 0), unflipped:  e = dy + y
    //   line scroll, Y flipped:           e = 255 - y     (the walk runs backwards from entry 255,
    //                                       whatever dy is: MAME's override for the "software flipped" games)
    //   row scroll (mode 2), unflipped:   e = (dy + y) & ~7, one entry for eight lines
    //   row scroll, Y flipped:            e = 248 - 8 * ((y + (dy & 7)) >> 3)
    // with y the absolute row and dy the layer's Y scroll register plus the flip correction (scroll_y).
    //
    // A layer more than one page high (rowspan 1 or 3: two or four pages, MAME's loop over the page rows) takes its entry
    // from the layer row instead: unflipped it is the same e = dy + y (the entries run on through the pages, 512 of them
    // in the layer's area, wrapping), flipped
    //   line scroll, Y flipped, 2/4 pages: e = scroll - 1 - y    (the page rows' walks join into one run, which starts
    //                                       wherever the scroll puts the layer's bottom edge)
    //   row scroll,  Y flipped, 2/4 pages: e = (scroll - 1 - y) & ~7
    // (everything modulo 512 entries). A span of 3 pages is not a power of two and stays unsupported (S_SETUP).
    // Checked against a transcription of MAME's loop (tools/ls_model.py): every row of 256, for 1 / 2 / 4 pages, flipped
    // or not, line or row scroll, scrolls -600..599, each drawn by exactly one page, 0 differences.
    wire        ls_multi = (rowspan != 2'd0);
    wire  [8:0] ls_sum   = scroll_y[8:0] + line_a;
    wire  [9:0] ls_n0    = {ls_sum, 1'b1};
    wire  [9:0] ls_n2    = {ls_sum[8:3], 3'd0, 1'b1};
    wire  [8:0] ls_f0v   = 9'd255 - line_a;
    wire  [9:0] ls_f0    = {ls_f0v, 1'b1};
    wire  [9:0] ls_sum2  = {1'b0, line_a} + {7'd0, scroll_y[2:0]};
    wire  [9:0] ls_f2    = (10'd496 - {ls_sum2[8:3], 4'd0}) | 10'd1;
    wire  [8:0] ls_rho   = scroll_y[8:0] - 9'd1 - line_a;
    wire  [9:0] ls_fm0   = {ls_rho, 1'b1};
    wire  [9:0] ls_fm2   = {ls_rho[8:3], 3'd0, 1'b1};
    wire  [9:0] ls_idx   = flip_y ? (ls_multi ? (scrollmode[1] ? ls_fm2 : ls_fm0) : (scrollmode[1] ? ls_f2 : ls_f0))
                                  : (scrollmode[1] ? ls_n2 : ls_n0);
    wire [11:0] ls_word  = {cur_l, 10'd0} + {2'd0, ls_idx};
    wire [15:0] scroll_vram_addr = {scrollbank, ls_word};
    wire [11:0] wrap_x = ({10'd0, colspan} + 12'd1) << 9;
    wire [10:0] wrap_y = ({ 9'd0, rowspan} + 11'd1) << 8;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [11:0] vx0 = $unsigned(scroll_x[11:0]) + 12'(VIS_X0);
    // source row: the layer's y, unflipped; flipped, the page is picked by the band the row falls in,
    // (scroll - y - 1) >> 8, and the row inside the page runs backwards from 253 + scroll (see above)
    wire [10:0] vy0_n = $unsigned(scroll_y[10:0]) + {2'd0, line_a};
    wire [10:0] band_f = $unsigned(scroll_y[10:0]) - {2'd0, line_a} - 11'd1;
    wire  [7:0] u_f    = scroll_y[7:0] + 8'd253 - line_a[7:0];
    wire [10:0] vy0_f  = {1'b0, band_f[9:8], u_f};
    wire [10:0] vy0    = flip_y ? vy0_f : vy0_n;

    // pixels the group at fvx contributes: to the end of its tile, or of the line
    wire [LB_AW:0] left    = (LB_AW+1)'(VIS_W) - fpx;
    wire [3:0]     to_tile = 4'd8 - {1'b0, fvx[2:0]};
    wire [3:0]     npx_now = (left < (LB_AW+1)'(to_tile)) ? left[3:0] : to_tile;
    wire [LB_AW:0] fpx_next = fpx + (LB_AW+1)'(npx_now);

    // stage handovers
    wire v_to_r = (vst == V_HOLD) && (rst == R_IDLE);
    wire r_to_e = (rst == R_HOLD) && !e_busy;
    wire layer_done = v_done && (vst == V_IDLE) && (rst == R_IDLE) && !e_busy;

    always_ff @(posedge clk) begin
        if (reset) begin
            st <= S_IDLE; busy <= 1'b0; bank <= 1'b0;
            rom_req <= 1'b0; vram_req <= 1'b0; unsupported <= 1'b0; cur_l <= 2'd0;
            vst <= V_IDLE; rst <= R_IDLE; e_busy <= 1'b0; v_done <= 1'b0;
        end else if (line_start && st != S_IDLE) begin
            if (clr_unsup) unsupported <= 1'b0;
            // the previous line overran its budget: abandon it and start this
            // one, as the hardware would -- whatever was drawn is what shows
            bank <= ~bank; busy <= 1'b1;
            rom_req <= 1'b0; vram_req <= 1'b0; cur_l <= 2'd0; st <= S_SETUP;
            vst <= V_IDLE; rst <= R_IDLE; e_busy <= 1'b0; v_done <= 1'b0;
        end else begin
            if (clr_unsup) unsupported <= 1'b0;
            case (st)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (line_start) begin
                        bank  <= ~bank;
                        busy  <= 1'b1;
                        cur_l <= 2'd0;
                        st    <= S_SETUP;
                        if (flip_x) unsupported <= 1'b1;
                    end
                end

                S_SETUP: begin
                    cur_x <= '0;
                    if (colspan == 2'd2 || rowspan == 2'd2) unsupported <= 1'b1;
                    if (scrollmode[0]) begin     // xy scroll (3, and the reserved 1: MAME's `default`)
                        vx  <= vx0 & (wrap_x - 12'd1);
                        fvx <= vx0 & (wrap_x - 12'd1);
                        vy  <= vy0 & (wrap_y - 11'd1);
                        fpx <= '0; v_done <= 1'b0; vst <= V_ATTR;
                        st  <= S_RUN;
                    end else begin
                        vram_addr <= scroll_vram_addr;   // line/row scroll word
                        vram_req  <= 1'b1;
                        st <= S_SCRL;
                    end
                end
                S_SCRL: if (vram_ack) begin
                    scroll_word <= vram_q; vram_req <= 1'b0; st <= S_SCRL2;
                end
                S_SCRL2: begin
                    vx  <= vx0 & (wrap_x - 12'd1);
                    fvx <= vx0 & (wrap_x - 12'd1);
                    vy  <= vy0 & (wrap_y - 11'd1);
                    fpx <= '0; v_done <= 1'b0; vst <= V_ATTR;
                    st  <= S_RUN;
                end

                S_RUN: begin
                    // ---- V: tile RAM, attribute then code
                    case (vst)
                        V_ATTR:  begin vram_addr <= vram_base;          vram_req <= 1'b1; vst <= V_ATTRW; end
                        V_ATTRW: if (vram_ack) begin attr_v <= vram_q;  vram_req <= 1'b0; vst <= V_CODE;  end
                        V_CODE:  begin vram_addr <= vram_base | 16'd1;  vram_req <= 1'b1; vst <= V_CODEW; end
                        V_CODEW: if (vram_ack) begin
                            code_v <= vram_q; vram_req <= 1'b0; npx_v <= npx_now; vst <= V_HOLD;
                        end
                        V_HOLD: if (v_to_r) begin
                            fpx <= fpx_next;
                            fvx <= ((fvx | 12'd7) + 12'd1) & (wrap_x - 12'd1);
                            if (fpx_next >= (LB_AW+1)'(VIS_W)) begin v_done <= 1'b1; vst <= V_IDLE; end
                            else vst <= V_ATTR;
                        end
                        default: ;
                    endcase

                    // ---- R: tile ROM row
                    case (rst)
                        R_IDLE: if (v_to_r) begin attr <= attr_v; code <= code_v; npx_r <= npx_v; rst <= R_REQ; end
                        R_REQ: begin
                            flipx_r  <= regs[1][fliprsel] & attr_flip;
                            color_r  <= colorbase[cur_l] | {4'd0, attr_color};
                            rom_addr <= {code, 3'd0} + {16'd0, attr_fy};
                            rom_req  <= 1'b1;
                            rst <= R_WAIT;
                        end
                        R_WAIT: if (rom_ack) begin rowdata_r <= rom_q; rom_req <= 1'b0; rst <= R_HOLD; end
                        R_HOLD: if (r_to_e) rst <= R_IDLE;
                        default: rst <= R_IDLE;
                    endcase

                    // ---- E: the group's pixels into the line buffer
                    if (r_to_e) begin
                        rowdata <= rowdata_r; color <= color_r; flipx <= flipx_r;
                        e_cnt <= npx_r; e_busy <= (npx_r != 4'd0);
                    end else if (e_busy) begin
                        case (cur_l)
                            2'd0: lbuf0[{bank, cur_x}] <= {|pixel, pen_e};
                            2'd1: lbuf1[{bank, cur_x}] <= {|pixel, pen_e};
                            2'd2: lbuf2[{bank, cur_x}] <= {|pixel, pen_e};
                            2'd3: lbuf3[{bank, cur_x}] <= {|pixel, pen_e};
                        endcase
                        vx    <= (vx + 12'd1) & (wrap_x - 12'd1);
                        cur_x <= cur_x + 1'd1;
                        e_cnt <= e_cnt - 4'd1;
                        if (e_cnt == 4'd1) e_busy <= 1'b0;
                    end

                    // ---- the layer is done when every stage has drained
                    if (layer_done) begin
                        if (cur_l == 2'd3) begin st <= S_IDLE; busy <= 1'b0; end
                        else begin cur_l <= cur_l + 2'd1; st <= S_SETUP; end
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
