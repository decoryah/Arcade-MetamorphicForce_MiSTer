// K053250 bench: the line-scroll plane alone, its ROM behind a request/ack port of
// configurable latency, driven from C++ (tb_lvc.cpp) and compared with the transcription
// of MAME's draw routine (lvc_ref.h).
`default_nettype none

module tb_lvc_top (
    input  logic        clk,
    input  logic        reset,
    input  logic [63:0] regs_flat,          // the eight registers, byte i at [8 i +: 8]
    input  logic        cpu_we,
    input  logic [12:0] cpu_addr,
    input  logic  [1:0] cpu_be,
    input  logic [15:0] cpu_wdata,
    output logic [15:0] cpu_rq,
    output logic        dma_busy,
    input  logic        frame_tick,
    input  logic        latch,
    input  logic        line_start,
    input  logic  [8:0] line,
    output logic        busy,
    input  logic  [7:0] palbase,
    input  logic  [8:0] px,
    output logic [10:0] pix,
    output logic        opaque,
    // ROM load
    input  logic        rom_we,
    input  logic [14:0] rom_wa,
    input  logic [63:0] rom_wd,
    input  logic [7:0]  lat,                // clocks before the ack
    output logic [31:0] n_fetch
);
    logic [7:0] regs [8];
    always_comb for (int i = 0; i < 8; i++) regs[i] = regs_flat[8*i +: 8];

    logic [63:0] rom [32768];
    logic        rom_req, rom_ack;
    logic [14:0] rom_addr;
    logic [63:0] rom_q;
    logic  [7:0] cn;
    always_ff @(posedge clk) begin
        if (rom_we) rom[rom_wa] <= rom_wd;
        rom_ack <= 1'b0;
        if (!rom_req) cn <= 8'd0;
        else if (rom_ack) cn <= 8'd0;
        else if (cn >= lat) begin rom_ack <= 1'b1; rom_q <= rom[rom_addr]; cn <= 8'd0; n_fetch <= n_fetch + 32'd1; end
        else cn <= cn + 8'd1;
        if (reset) n_fetch <= 32'd0;
    end

    // +dbg=1: the normal orientation's first rows' parameters and the first pixels' evaluation
    int dbg;
    int nrow;
    initial begin
        if (!$value$plusargs("dbg=%d", dbg)) dbg = 0;
        nrow = 0;
    end
    always_ff @(posedge clk) if (dbg != 0) begin
        if (dut.m == 3'd5 && dut.r == 5'd5 && nrow < 2) begin
            $display("PRM row ry=%0d entry=%0d w0=%04x w1=%04x w2=%04x scrollword=%04x msx=%0d msy=%0d ctrl=%02x",
                     dut.ry, dut.n_entry, dut.w0, dut.w1, dut.w2, dut.fr_q, dut.msx, dut.msy, dut.ctrl);
        end
        if (dut.m == 3'd5 && dut.r == 5'd17 && dut.ux < 6 && nrow < 2)
            $display("  px %0d: scroll=%0d pos=%0d a=%0d prod=%0d nib=%05x grp=%04x sel=%0d ok=%0d pen=%0d",
                     dut.ux, dut.e_scroll, dut.e_pos, dut.e_a, dut.e_prod, dut.e_nib, dut.e_grp, dut.e_sel, dut.e_ok, dut.u_pen);
        if (dut.m == 3'd5 && dut.r == 5'd17 && dut.ux == 287) nrow <= nrow + 1;
    end

    k053250_lvc dut (
        .clk(clk), .reset(reset), .regs(regs),
        .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_be(cpu_be), .cpu_wdata(cpu_wdata), .cpu_rq(cpu_rq),
        .dma_busy(dma_busy), .frame_tick(frame_tick), .latch(latch),
        .line_start(line_start), .line(line), .busy(busy), .row_busy(),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_q(rom_q),
        .palbase(palbase), .px(px), .pix(pix), .opaque(opaque)
    );
endmodule
