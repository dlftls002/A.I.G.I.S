`timescale 1ns / 1ps

module SCREEN_MUX (
    input  logic        ui_enable,
    input  logic [11:0] i_camera_rgb,
    input  logic [1:0]  i_bitmap_pixel,
    output logic [11:0] o_screen_rgb
);

    localparam logic [11:0] GREEN = 12'h0F0;
    localparam logic [11:0] RED   = 12'hF00;

    always_comb begin
        if (!ui_enable) begin
            o_screen_rgb = i_camera_rgb;
        end else begin
            case (i_bitmap_pixel)
                2'b00:   o_screen_rgb = i_camera_rgb;
                2'b01:   o_screen_rgb = GREEN;
                2'b10:   o_screen_rgb = RED;
                2'b11:   o_screen_rgb = RED;
                default: o_screen_rgb = i_camera_rgb;
            endcase
        end
    end

endmodule