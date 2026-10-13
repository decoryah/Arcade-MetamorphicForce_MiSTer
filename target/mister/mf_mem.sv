//------------------------------------------------------------------------------
// MiSTer memory subsystem for the Metamorphic Force core: the ROM image behind the
// core's request/ack ports (docs/mister-memory.md describes this partition).
//
//   SDRAM  (32 MB, 16 bit)   tiles     2 words a row (the four chunky bytes), 2 MB,
//                                      2-word bursts
//                            sprites   4 words a row (the four planes), 8 MB, 4-word bursts
//                            K053250   256 KB, 4-word bursts (a group of 16 pixels)
//                            PCM       4 MB, single words
//                            68000 program 2 MB and Z80 program 256 KB:
//                                      behind a cache each, filled by 8-word
//                                      bursts on the same burst port
//   block RAM                K056832 tile RAM, 64K x 16, byte-enabled
//
// Derived from the Monster Maulers core's memory system (itself the Gaiapolis core's).
// Those games' tiles and sprites carried a fifth plane in the same burst, and the
// rotating plane's characters and map lived in the DDR3; this board has neither, so
// the bursts are shorter, and the K053250's ROM takes the place of the DDR3 client.
//
// Every memory holds big-endian 16-bit words: image byte 2k is the high byte
// of word k, byte 2k+1 the low byte (the packing the benches in sim/ use).
//
// The core's ports are level requests with a one-cycle ack that carries the
// data; a client may withdraw a request before its ack (a renderer restarting
// on a new line does), so every port here finishes the access it started and
// acks only if the same request is still standing.
//------------------------------------------------------------------------------
`default_nettype none

module mf_mem #(
    parameter int TEST_SHRINK = 0,      // the memory test reads 1/2^n of each region (benches)
    parameter [24:0] FL_BASE = 25'h0400000  // fast load: the DDR3 beat of the image in the client's window (byte 0x32000000)
) (
    input  logic        clk,            // 96 MHz
    input  logic        clk_sdram,      // 96 MHz, phase-shifted: drives the SDRAM clock pin
    input  logic        init,           // hardware reset: re-initialise the SDRAM
    input  logic        dl_start,       // an image is about to load: drop the caches
    output logic        ready,
    // the built-in memory test (mem_test): started by test_start while the
    // core is in reset; the platform keeps the core there while test_run
    input  logic        test_start,
    output logic        test_run, test_done,
    output logic  [5:0] test_ok,        // per region: prog, snd, tile, lvc, pcm, spr -- read back == loaded
    output logic  [5:0] test_stable,    // per region: the second pass read the same as the first
    output logic        vram_ok,
    output logic  [3:0] vram_bad,       // tile RAM words that read back wrong, saturating
    input  logic        rd_late,        // SDRAM read capture one clock later (OSD diagnostic)
    input  logic        burst_slow,     // SDRAM bursts at the slow spacing (OSD diagnostic)

    // the ROM image arriving from the HPS, a byte at an image offset
    input  logic        dl_we,          // one clock per byte
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    output logic        dl_wait,        // hold the next byte

    // fast load (the MRA's address= attribute): Main_MiSTer has put the whole image into DDR3 at FL_BASE in one
    // go and ended an empty download; `fl_go` (one clock) says so and `fl_len` is the image's length in bytes.
    // The image is read back and its words pushed into the loader's FIFO as if the HPS had streamed them;
    // `fl_done` (one clock) comes when the last of them has been written. The DDR3 client port is the arbiter's
    // (ddr_arb.sv c_*): plain Avalon-MM master, rd held until a clock where busy is low
    input  logic        fl_go,
    input  logic [24:0] fl_len,
    output logic        fl_done,
    output logic        ddr_rd,
    output logic [24:0] ddr_addr,       // 64-bit word address within the client's window
    output logic  [7:0] ddr_burst,
    input  logic        ddr_busy,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dready,

    // core ports
    input  logic        prog_req,  input  logic [22:1] prog_addr, output logic prog_ack, output logic [15:0] prog_q,
    input  logic        tile_req,  input  logic [18:0] tile_addr, output logic tile_ack, output logic [39:0] tile_q,
    input  logic        lvc_req,   input  logic [14:0] lvc_addr,  output logic lvc_ack,  output logic [63:0] lvc_q,
    input  logic        spr_req,   input  logic [19:0] spr_addr,  output logic spr_ack,  output logic [79:0] spr_q,
    input  logic        snd_req,   input  logic [17:0] snd_addr,  output logic snd_ack,  output logic  [7:0] snd_q,
    input  logic        pcm_req,   input  logic [21:0] pcm_addr,  output logic pcm_ack,  output logic  [7:0] pcm_q,
    // the tile RAM: the core's request/ack port, byte-enabled writes
    input  logic        vram_req,  input  logic        vram_we,   input  logic [15:0] vram_addr,
    input  logic  [1:0] vram_be,   input  logic [15:0] vram_wdata, output logic vram_ack, output logic [15:0] vram_q,

    // SDRAM pins
    inout  wire  [15:0] dram_dq,
    output logic [12:0] dram_a,
    output logic  [1:0] dram_ba,
    output logic  [1:0] dram_dqm,
    output logic        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n
);
    // image layout (byte offsets), mra/*.mra
    localparam [24:0] IMG_PROG = 25'h0000000, IMG_SND  = 25'h0200000, IMG_TILE = 25'h0240000, IMG_LVC = 25'h0440000;
    localparam [24:0] IMG_PCM  = 25'h0480000, IMG_SPR  = 25'h0880000, IMG_END  = 25'h1080000;
    // SDRAM word addresses
    localparam [24:1] SD_TILE = 24'h000000, SD_PCM = 24'h100000, SD_SPR = 24'h300000,
                      SD_PROG = 24'h700000, SD_SND = 24'h800000, SD_LVC = 24'h820000;

    // the caches are cleared by a hardware reset and whenever an image loads
    wire cinv = init | dl_start;

    // ------------------------------------------------------------ download
    // The HPS delivers a byte at a time, at most one every few clocks. A
    // consecutive even/odd pair is merged into one 16-bit word before a small
    // FIFO; the dispatcher behind it routes each entry to its memory as a
    // byte-enabled word write. A lone even byte waits for its partner (the
    // next byte) and is flushed alone if none arrives.
    logic        pend_v;
    logic [24:0] pend_a;
    logic  [7:0] pend_d, pend_age;
    wire         nb = dl_we;                                // a new byte this clock
    logic        wf_push;
    logic [41:0] wf_in;                                     // {word addr[24:1], be[1:0], data[15:0]}
    always_comb begin
        wf_push = 1'b0; wf_in = '0;
        if (nb && pend_v && dl_addr == {pend_a[24:1], 1'b1}) begin
            wf_push = 1'b1; wf_in = {pend_a[24:1], 2'b11, pend_d, dl_data};
        end else if (pend_v && (nb || pend_age == 8'hff)) begin
            wf_push = 1'b1; wf_in = {pend_a[24:1], pend_a[0] ? 2'b01 : 2'b10, pend_d, pend_d};
        end
    end

    // a fast load's word, produced by the DDR3 block reader below, one clock before it is pushed
    logic        fl_wv;
    logic [23:0] fl_wa;
    logic [15:0] fl_word;

    (* ramstyle = "no_rw_check" *) logic [41:0] wfifo [64];   // the head is never the entry being written
    logic  [6:0] wf_wp, wf_rp;
    wire         wf_empty = (wf_wp == wf_rp);
    wire [41:0]  wf_head  = wfifo[wf_rp[5:0]];
    assign dl_wait = ((wf_wp - wf_rp) >= 7'd32);
    // the head is taken into a register before it is decoded
    logic [41:0] hd;
    wire [24:1]  wa       = hd[41:18];
    wire  [1:0]  wbe      = hd[17:16];
    wire [15:0]  wd       = hd[15:0];

    typedef enum logic [2:0] { W_IDLE, W_DEC, W_ADDR, W_SDRAM } wst_t;
    wst_t wst;
    // the region the word belongs to, and its word index inside it
    typedef enum logic [2:0] { G_PROG, G_SND, G_TILE, G_LVC, G_PCM, G_SPR, G_NONE } reg_t;
    reg_t        wreg;
    logic [21:0] wrel;

    // SDRAM write client (client 1)
    logic        sd_wr_req, sd_wr_ack;
    logic [24:1] sd_wr_addr;

    always_ff @(posedge clk) begin
        if (init) begin
            wf_wp <= '0; wf_rp <= '0; wst <= W_IDLE; pend_v <= 1'b0; pend_age <= '0;
            sd_wr_req <= 1'b0;
        end else begin
            // pairing stage
            if (nb) begin
                if (pend_v && dl_addr == {pend_a[24:1], 1'b1}) pend_v <= 1'b0;
                else begin pend_v <= 1'b1; pend_a <= dl_addr; pend_d <= dl_data; pend_age <= '0; end
            end else if (pend_v) begin
                if (pend_age == 8'hff) pend_v <= 1'b0; else pend_age <= pend_age + 8'd1;
            end
            if (wf_push || fl_wv) begin     // not full: the HPS stops at dl_wait with 32 queued, a fast load waits for room
                wfifo[wf_wp[5:0]] <= fl_wv ? {fl_wa, 2'b11, fl_word} : wf_in;
                wf_wp <= wf_wp + 7'd1;
            end
            case (wst)
                W_IDLE: if (!wf_empty) begin hd <= wf_head; wst <= W_DEC; end
                W_DEC: begin
                    if (wa < IMG_SND[24:1])       begin wreg <= G_PROG; wrel <= 22'(wa - IMG_PROG[24:1]); end
                    else if (wa < IMG_TILE[24:1]) begin wreg <= G_SND;  wrel <= 22'(wa - IMG_SND[24:1]); end
                    else if (wa < IMG_LVC[24:1])  begin wreg <= G_TILE; wrel <= 22'(wa - IMG_TILE[24:1]); end
                    else if (wa < IMG_PCM[24:1])  begin wreg <= G_LVC;  wrel <= 22'(wa - IMG_LVC[24:1]); end
                    else if (wa < IMG_SPR[24:1])  begin wreg <= G_PCM;  wrel <= 22'(wa - IMG_PCM[24:1]); end
                    else if (wa < IMG_END[24:1])  begin wreg <= G_SPR;  wrel <= 22'(wa - IMG_SPR[24:1]); end
                    else                          begin wreg <= G_NONE; wrel <= '0; end
                    wst <= W_ADDR;
                end
                // every region is stored as it comes: a tile row is 2 consecutive words, a sprite row 4
                W_ADDR: begin
                    case (wreg)
                        G_PROG: begin sd_wr_addr <= SD_PROG + 24'(wrel); sd_wr_req <= 1'b1; wst <= W_SDRAM; end
                        G_SND:  begin sd_wr_addr <= SD_SND  + 24'(wrel); sd_wr_req <= 1'b1; wst <= W_SDRAM; end
                        G_TILE: begin sd_wr_addr <= SD_TILE + 24'(wrel); sd_wr_req <= 1'b1; wst <= W_SDRAM; end
                        G_LVC:  begin sd_wr_addr <= SD_LVC  + 24'(wrel); sd_wr_req <= 1'b1; wst <= W_SDRAM; end
                        G_PCM:  begin sd_wr_addr <= SD_PCM  + 24'(wrel); sd_wr_req <= 1'b1; wst <= W_SDRAM; end
                        G_SPR:  begin sd_wr_addr <= SD_SPR  + 24'(wrel); sd_wr_req <= 1'b1; wst <= W_SDRAM; end
                        default: begin wf_rp <= wf_rp + 7'd1; wst <= W_IDLE; end    // beyond the image: dropped
                    endcase
                end
                // the ack pops the entry
                W_SDRAM: if (sd_wr_ack) begin sd_wr_req <= 1'b0; wf_rp <= wf_rp + 7'd1; wst <= W_IDLE; end
                default: wst <= W_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------ fast load
    // The image is read back from the DDR3 a 256-byte block at a time (a 32-beat burst into a small buffer) and its
    // 128 words go into the loader's FIFO as room allows, one word every three clocks, so the layout, the cache sweep
    // and the memory test are those of a streamed load; the memory test is given the same bytes the HPS would have
    // streamed (high byte, low byte), so its sums are those of the image. The loader takes about a word per ten clocks:
    // that, not the DDR3, sets the time of the load.
    typedef enum logic [2:0] { F_IDLE, F_REQ, F_BEATS, F_PUSH, F_FIN } fst_t;
    fst_t        fst;
    (* ramstyle = "MLAB" *) logic [63:0] fbuf [32];
    logic        fl_pend, fl_ok, fl_bw;
    logic [24:0] fl_off_w, fl_end_w;    // the block's first word, the image's length in words
    logic [24:0] fl_ba;                 // the memory test's byte address, data
    logic  [7:0] fl_bd, fw;
    logic  [5:0] fbn;                   // beats of the block stored
    logic  [1:0] fph;                   // 0 take the word (room in the FIFO), 1 push it and its high byte, 2 low byte
    logic  [8:0] fowed;                 // read beats still to come
    wire         fl_room = ((wf_wp - wf_rp) < 7'd56);   // room for this word and the one in flight

    always_ff @(posedge clk) begin
        fl_wv <= 1'b0; fl_bw <= 1'b0; fl_done <= 1'b0;
        if (init) fowed <= '0;
        else fowed <= fowed + ((ddr_rd && !ddr_busy) ? 9'(ddr_burst) : 9'd0) - (ddr_dready ? 9'd1 : 9'd0);
        if (ddr_rd && !ddr_busy) ddr_rd <= 1'b0;                // taken (cleared first: a state may present the next one below)
        if (fl_go) fl_pend <= 1'b1;
        if (cinv) begin
            fst <= F_IDLE; ddr_rd <= 1'b0; fl_pend <= 1'b0;
        end else case (fst)
            F_IDLE: if (fl_pend && fowed == 9'd0) begin         // after any burst of an aborted load has come back
                fl_pend <= 1'b0;
                fl_off_w <= '0; fl_end_w <= {1'b0, fl_len[24:1]} + {24'd0, fl_len[0]};
                fst <= F_REQ;
            end
            F_REQ: begin
                if (fl_off_w >= fl_end_w) fst <= F_FIN;
                else if (!ddr_rd) begin
                    ddr_rd <= 1'b1; ddr_addr <= FL_BASE + 25'(fl_off_w[24:2]); ddr_burst <= 8'd32;
                    fbn <= '0; fst <= F_BEATS;
                end
            end
            F_BEATS: if (ddr_dready) begin
                fbuf[fbn[4:0]] <= ddr_dout; fbn <= fbn + 6'd1;
                if (fbn == 6'd31) begin fw <= '0; fph <= 2'd0; fst <= F_PUSH; end
            end
            F_PUSH: case (fph)
                2'd0: if (fl_room) begin
                    // the beat's little-endian halfword, as the image's big-endian word
                    fl_word <= {fbuf[fw[6:2]][16 * fw[1:0] +: 8], fbuf[fw[6:2]][16 * fw[1:0] + 8 +: 8]};
                    fl_wa   <= {fl_off_w[23:7], fw[6:0]};
                    fl_ok   <= ({fl_off_w[24:7], fw[6:0]} < fl_end_w);
                    fph <= 2'd1;
                end
                2'd1: begin
                    fl_wv <= fl_ok; fl_bw <= fl_ok; fl_ba <= {fl_wa, 1'b0}; fl_bd <= fl_word[15:8];
                    fph <= 2'd2;
                end
                default: begin
                    fl_bw <= fl_ok; fl_ba <= {fl_wa, 1'b1}; fl_bd <= fl_word[7:0];
                    fph <= 2'd0;
                    if (fw == 8'd127) begin fl_off_w <= fl_off_w + 25'd128; fst <= F_REQ; end
                    else fw <= fw + 8'd1;
                end
            endcase
            // done when the loader has written every word (an entry leaves the FIFO when its write is acknowledged)
            F_FIN: if (wf_empty && wst == W_IDLE && !fl_wv) begin fl_done <= 1'b1; fst <= F_IDLE; end
            default: fst <= F_IDLE;
        endcase
    end

    // ---------------------------------------------- the test drives the ports
    logic        t_prog_req, t_snd_req, t_tile_req, t_lvc_req, t_pcm_req, t_spr_req;
    logic [22:1] t_prog_addr; logic [17:0] t_snd_addr; logic [18:0] t_tile_addr; logic [14:0] t_lvc_addr;
    logic [21:0] t_pcm_addr;  logic [19:0] t_spr_addr;
    logic        t_vram_req, t_vram_we; logic [15:0] t_vram_addr, t_vram_wdata;
    wire         prog_req_i  = test_run ? t_prog_req  : prog_req;
    wire [22:1]  prog_addr_i = test_run ? t_prog_addr : prog_addr;
    wire         snd_req_i   = test_run ? t_snd_req   : snd_req;
    wire [17:0]  snd_addr_i  = test_run ? t_snd_addr  : snd_addr;
    wire         tile_req_i  = test_run ? t_tile_req  : tile_req;
    wire [18:0]  tile_addr_i = test_run ? t_tile_addr : tile_addr;
    wire         lvc_req_i   = test_run ? t_lvc_req   : lvc_req;
    wire [14:0]  lvc_addr_i  = test_run ? t_lvc_addr  : lvc_addr;
    wire         pcm_req_i   = test_run ? t_pcm_req   : pcm_req;
    wire [21:0]  pcm_addr_i  = test_run ? t_pcm_addr  : pcm_addr;
    wire         spr_req_i   = test_run ? t_spr_req   : spr_req;
    wire [19:0]  spr_addr_i  = test_run ? t_spr_addr  : spr_addr;
    wire         vram_req_i  = test_run ? t_vram_req  : vram_req;
    wire         vram_we_i   = test_run ? t_vram_we   : vram_we;
    wire [15:0]  vram_addr_i = test_run ? t_vram_addr : vram_addr;
    wire  [1:0]  vram_be_i   = test_run ? 2'b11       : vram_be;
    wire [15:0]  vram_wdata_i = test_run ? t_vram_wdata : vram_wdata;

    logic        mem_ready;
    mem_test #(.SHRINK(TEST_SHRINK)) u_test (
        .clk(clk), .init(init), .ready(mem_ready), .start(test_start), .run(test_run), .done(test_done),
        .ok(test_ok), .stable(test_stable), .vram_ok(vram_ok), .vram_bad(vram_bad),
        .dl_we(dl_we || fl_bw), .dl_addr(fl_bw ? fl_ba : dl_addr), .dl_data(fl_bw ? fl_bd : dl_data),
        .prog_req(t_prog_req), .prog_addr(t_prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
        .snd_req(t_snd_req), .snd_addr(t_snd_addr), .snd_ack(snd_ack), .snd_q(snd_q),
        .tile_req(t_tile_req), .tile_addr(t_tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .lvc_req(t_lvc_req), .lvc_addr(t_lvc_addr), .lvc_ack(lvc_ack), .lvc_q(lvc_q),
        .pcm_req(t_pcm_req), .pcm_addr(t_pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .spr_req(t_spr_req), .spr_addr(t_spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
        .vram_req(t_vram_req), .vram_we(t_vram_we), .vram_addr(t_vram_addr), .vram_wdata(t_vram_wdata),
        .vram_ack(vram_ack), .vram_q(vram_q)
    );

    // --------------------------------------------------------------- SDRAM
    logic [24:1] c_addr  [2];
    logic        c_req   [2];
    logic        c_we    [2];
    logic [15:0] c_wdata [2];
    logic  [1:0] c_be    [2];
    logic        c_ack   [2];
    logic [15:0] sd_rdata;
    logic [24:1] b_addr;
    logic  [9:0] b_len, b_idx;
    logic        b_req, b_done;
    logic        b_wr;
    logic [15:0] b_data;
    logic  [9:0] b_widx;
    logic        sd_ready;

    // client 0: PCM byte reads, behind a registered stage: the request comes
    // from the K054539s through two arbiters, and the stage acks only a
    // request still standing with the same address.
    typedef enum logic [1:0] { Q_IDLE, Q_BUSY, Q_ACK } qst_t;
    qst_t        qst;
    logic [21:0] pcm_addr_l;
    logic [15:0] pcm_word;
    always_ff @(posedge clk) begin
        pcm_ack <= 1'b0;
        if (init) begin qst <= Q_IDLE; c_req[0] <= 1'b0; end
        else case (qst)
            Q_IDLE: if (pcm_req_i && !pcm_ack) begin
                pcm_addr_l <= pcm_addr_i; c_addr[0] <= SD_PCM + 24'(pcm_addr_i[21:1]); c_req[0] <= 1'b1; qst <= Q_BUSY;
            end
            Q_BUSY: if (c_ack[0]) begin pcm_word <= sd_rdata; c_req[0] <= 1'b0; qst <= Q_ACK; end
            Q_ACK: begin
                if (pcm_req_i && pcm_addr_i == pcm_addr_l) pcm_ack <= 1'b1;
                qst <= Q_IDLE;
            end
            default: qst <= Q_IDLE;
        endcase
    end
    assign c_we[0]   = 1'b0; assign c_wdata[0] = '0; assign c_be[0] = 2'b11;
    assign pcm_q     = pcm_addr_l[0] ? pcm_word[7:0] : pcm_word[15:8];
    // client 1: the loader
    assign c_addr[1] = sd_wr_addr;
    assign c_req[1]  = sd_wr_req;
    assign c_we[1]   = 1'b1; assign c_wdata[1] = wd; assign c_be[1] = wbe;
    assign sd_wr_ack = c_ack[1];

    // The burst port serves the tilemap's 2-word, the K053250's and the sprite renderer's 4-word fetches (all
    // have a line to finish) and the two program caches' 8-word line fills. A fill that has waited long
    // enough goes first, so the 68000 and the Z80 are never starved by the renderers' back-to-back
    // requests: the renderers use about half of the port, so the interruptions cost them nothing the line
    // budget does not have.
    localparam int PW_URG = 40, SW_URG = 120;
    typedef enum logic [1:0] { B_IDLE, B_RUN, B_ACK } bst_t;
    bst_t  bst;
    logic  [2:0] bsel;                  // 0 tiles, 1 sprites, 2 68000 program fill, 3 Z80 program fill, 4 K053250
    logic [18:0] tile_addr_l;
    logic [19:0] spr_addr_l;
    logic [14:0] lvc_addr_l;
    logic [15:0] bw [8];
    logic        pf_req, sf_req;        // the caches' fill requests
    logic [21:3] pf_addr;
    logic [16:3] sf_addr;
    logic  [7:0] pw, sw;                // clocks a fill has waited
    always_ff @(posedge clk) begin
        pw <= (pf_req && !(bst == B_RUN && bsel == 3'd2)) ? ((pw == 8'hff) ? pw : pw + 8'd1) : 8'd0;
        sw <= (sf_req && !(bst == B_RUN && bsel == 3'd3)) ? ((sw == 8'hff) ? sw : sw + 8'd1) : 8'd0;
    end
    wire pf_go = pf_req && (pw >= 8'(PW_URG));
    wire sf_go = sf_req && (sw >= 8'(SW_URG));
    // a tile row is 2 words from 2 * row, a sprite row or a K053250 group 4 words from 4 * index
    wire [23:0] tile_base = {4'd0, tile_addr_i, 1'b0};
    wire [23:0] spr_base  = {2'd0, spr_addr_i, 2'b00};
    wire [23:0] lvc_base  = {7'd0, lvc_addr_i, 2'b00};
    always_ff @(posedge clk) begin
        if (init) begin bst <= B_IDLE; b_req <= 1'b0; tile_ack <= 1'b0; spr_ack <= 1'b0; lvc_ack <= 1'b0; end
        else begin
            tile_ack <= 1'b0; spr_ack <= 1'b0; lvc_ack <= 1'b0;
            case (bst)
                B_IDLE: begin               // not a request being acked right now
                    if (pf_go) begin
                        bsel <= 3'd2; b_addr <= SD_PROG + {2'd0, pf_addr, 3'd0}; b_len <= 10'd8; b_req <= 1'b1; bst <= B_RUN;
                    end else if (sf_go) begin
                        bsel <= 3'd3; b_addr <= SD_SND + {7'd0, sf_addr, 3'd0}; b_len <= 10'd8; b_req <= 1'b1; bst <= B_RUN;
                    end else if (tile_req_i && !tile_ack) begin
                        bsel <= 3'd0; tile_addr_l <= tile_addr_i;
                        b_addr <= SD_TILE + tile_base; b_len <= 10'd2; b_req <= 1'b1; bst <= B_RUN;
                    end else if (lvc_req_i && !lvc_ack) begin
                        bsel <= 3'd4; lvc_addr_l <= lvc_addr_i;
                        b_addr <= SD_LVC + lvc_base; b_len <= 10'd4; b_req <= 1'b1; bst <= B_RUN;
                    end else if (spr_req_i && !spr_ack) begin
                        bsel <= 3'd1; spr_addr_l <= spr_addr_i;
                        b_addr <= SD_SPR + spr_base; b_len <= 10'd4; b_req <= 1'b1; bst <= B_RUN;
                    end else if (pf_req) begin
                        bsel <= 3'd2; b_addr <= SD_PROG + {2'd0, pf_addr, 3'd0}; b_len <= 10'd8; b_req <= 1'b1; bst <= B_RUN;
                    end else if (sf_req) begin
                        bsel <= 3'd3; b_addr <= SD_SND + {7'd0, sf_addr, 3'd0}; b_len <= 10'd8; b_req <= 1'b1; bst <= B_RUN;
                    end
                end
                B_RUN: begin
                    if (b_wr) bw[b_idx[2:0]] <= b_data;
                    if (b_done) begin b_req <= 1'b0; bst <= B_ACK; end
                end
                B_ACK: begin
                    // ack only the request that is still standing
                    if (bsel == 3'd0 && tile_req_i && tile_addr_i == tile_addr_l) tile_ack <= 1'b1;
                    if (bsel == 3'd1 && spr_req_i  && spr_addr_i  == spr_addr_l)  spr_ack  <= 1'b1;
                    if (bsel == 3'd4 && lvc_req_i  && lvc_addr_i  == lvc_addr_l)  lvc_ack  <= 1'b1;
                    bst <= B_IDLE;
                end
                default: bst <= B_IDLE;
            endcase
        end
    end
    assign tile_q = {bw[0], bw[1], 8'h00};
    assign spr_q  = {bw[0], bw[1], bw[2], bw[3], 16'h0000};
    assign lvc_q  = {bw[0], bw[1], bw[2], bw[3]};

    // the caches: 68000 program 16 KB, Z80 program 4 KB; direct mapped, 16-byte lines
    logic        pc_ready, sc_ready;
    logic [15:0] snd_word;
    rom_cache #(.AW(22), .IDX(10)) u_pcache (
        .clk(clk), .reset(cinv), .ready(pc_ready),
        .req(prog_req_i), .addr(prog_addr_i), .ack(prog_ack), .q(prog_q),
        .fill_req(pf_req), .fill_addr(pf_addr),
        .fill_wr(b_wr && bst == B_RUN && bsel == 3'd2), .fill_idx(b_idx[2:0]), .fill_data(b_data),
        .fill_done(bst == B_ACK && bsel == 3'd2)
    );
    rom_cache #(.AW(17), .IDX(8)) u_scache (
        .clk(clk), .reset(cinv), .ready(sc_ready),
        .req(snd_req_i), .addr(snd_addr_i[17:1]), .ack(snd_ack), .q(snd_word),
        .fill_req(sf_req), .fill_addr(sf_addr),
        .fill_wr(b_wr && bst == B_RUN && bsel == 3'd3), .fill_idx(b_idx[2:0]), .fill_data(b_data),
        .fill_done(bst == B_ACK && bsel == 3'd3)
    );
    assign snd_q = snd_addr_i[0] ? snd_word[7:0] : snd_word[15:8];
    assign mem_ready = sd_ready && pc_ready && sc_ready;
    assign ready     = mem_ready;

    sdram_ctrl #(.NCLI(2)) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init), .rd_late(rd_late), .burst_slow(burst_slow), .ready(sd_ready),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_DQML(dram_dqm[0]), .SDRAM_DQMH(dram_dqm[1]), .SDRAM_BA(dram_ba),
        .SDRAM_nCS(), .SDRAM_nWE(dram_we_n), .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata), .c_be(c_be), .c_ack(c_ack), .rdata(sd_rdata),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_abort(1'b0), .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(1'b0), .b_wdata(16'd0), .b_be(2'b00), .b_widx(b_widx)
    );

    // ---------------------------------------------------------- tile RAM
    vram_bram u_vram (
        .clk(clk),
        .req(vram_req_i), .we(vram_we_i), .addr(vram_addr_i), .be(vram_be_i), .wdata(vram_wdata_i),
        .ack(vram_ack), .q(vram_q)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{b_widx, b_idx[9:3], wbe[0], IMG_PROG, dl_addr[0], wrel[21]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule


//------------------------------------------------------------------------------
// The K056832's tile RAM, 64K x 16 with byte enables, in block RAM behind one
// request/ack port (the Pocket's SRAM took this job there). The address and
// write data go to the RAM in the clock the request is seen; the read data is
// back a clock later and is acked then, if the same request is still standing
// (a renderer withdraws at line start). A write is performed whether or not
// the client is still there to hear the ack.
//------------------------------------------------------------------------------
module vram_bram (
    input  logic        clk,
    input  logic        req,
    input  logic        we,
    input  logic [15:0] addr,
    input  logic  [1:0] be,
    input  logic [15:0] wdata,
    output logic        ack,
    output logic [15:0] q
);
    (* ramstyle = "M10K,no_rw_check" *) logic [7:0] ram_lo [65536] /*verilator public_flat_rd*/;
    (* ramstyle = "M10K,no_rw_check" *) logic [7:0] ram_hi [65536] /*verilator public_flat_rd*/;
    logic        busy, busy_d, we_l;
    logic [15:0] addr_l;
    logic  [7:0] rq_lo, rq_hi;
    wire         take = req && !busy && !busy_d && !ack;     // not the request being acked right now

    always_ff @(posedge clk) begin
        if (take && we && be[0]) ram_lo[addr] <= wdata[7:0];
        if (take && we && be[1]) ram_hi[addr] <= wdata[15:8];
        rq_lo <= ram_lo[addr];
        rq_hi <= ram_hi[addr];
    end
    always_ff @(posedge clk) begin
        ack <= 1'b0;
        busy_d <= busy;
        if (take) begin busy <= 1'b1; addr_l <= addr; we_l <= we; end
        else if (busy) begin
            busy <= 1'b0;
            q <= {rq_hi, rq_lo};
            if (req && addr == addr_l && we == we_l) ack <= 1'b1;
        end
    end
endmodule
