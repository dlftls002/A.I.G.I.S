`timescale 1ns / 1ps

module bitmap_bram #(
    parameter int WIDTH  = 320,
    parameter int HEIGHT = 240,
    parameter int ADDR_W = $clog2(WIDTH * HEIGHT)
)(
    // Port A: input write side
    input  logic              clka,
    input  logic              wea,
    input  logic [ADDR_W-1:0] addra,
    input  logic [1:0]        dina,

    // Port B: VGA read / clear side
    input  logic              clkb,
    input  logic              web,
    input  logic [ADDR_W-1:0] addrb,
    input  logic [1:0]        dinb,
    output logic [1:0]        doutb
);

    (* ram_style = "block" *) logic [1:0] mem [0:WIDTH*HEIGHT-1];

    always_ff @(posedge clka) begin
        if (wea) begin
            mem[addra] <= dina;
        end
    end

    always_ff @(posedge clkb) begin
        doutb <= mem[addrb];

        if (web) begin
            mem[addrb] <= dinb;
        end
    end

endmodule