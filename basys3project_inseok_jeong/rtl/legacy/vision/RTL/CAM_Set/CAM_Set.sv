`timescale 1ns / 1ps

module CAM_Set #(
    parameter int IMG_W  = 320,
    parameter int IMG_H  = 240,
    parameter int ADDR_W = $clog2(IMG_W * IMG_H)
) (
    input  logic              clk,
    input  logic              reset,

    // OV7670 camera side
    input  logic              pclk,
    input  logic              href,
    input  logic              vsync,
    input  logic [7:0]        pdata,
    output logic              xclk,

    // OV7670 SCCB side
    output logic              scl,
    inout  tri                sda,

    // System clocks for other top-level blocks
    output logic              clk_100M,
    output logic              clk_25M,

    // CAM framebuffer read side from VGA_Decoder
    input  logic              cam_fb_rclk,
    input  logic [9:0]        x_pixel,
    input  logic [9:0]        y_pixel,
    input  logic              de,
    output logic [11:0]       cam_rgb,

    // Raw camera pixel stream branch for UI_Set
    output logic              cam_pclk,
    output logic              cam_href,
    output logic              cam_vsync,
    output logic              cam_we,
    output logic [ADDR_W-1:0] cam_wAddr,
    output logic [15:0]       cam_wData
);

    logic [ADDR_W-1:0] cam_fb_rAddr;
    logic [15:0]       cam_fb_rData;

    assign xclk = clk_25M;

    assign cam_pclk  = pclk;
    assign cam_href  = href;
    assign cam_vsync = vsync;

    clk_wiz_0 U_CLK_WIZ (
        .clk_100M(clk_100M),
        .clk_25M (clk_25M),
        .reset   (reset),
        .clk_in1 (clk)
    );

    OV7670_attribute_setting #(
        .CLK_FREQ(100_000_000)
    ) U_OV7670_ATTRIBUTE_SETTING (
        .clk  (clk),
        .reset(reset),
        .scl  (scl),
        .sda  (sda)
    );

    OV7670MemController U_CAM_CTRL (
        .pclk (pclk),
        .reset(reset),
        .href (href),
        .vsync(vsync),
        .pdata(pdata),
        .we   (cam_we),
        .wAddr(cam_wAddr),
        .wData(cam_wData)
    );

    framebuffer U_CAM_FRAMEBUFFER (
        // Write side from OV7670MemController
        .wclk (pclk),
        .we   (cam_we),
        .wAddr(cam_wAddr),
        .wData(cam_wData),

        // Read side to Frame_Set / CAM&UI mux path
        .rclk (cam_fb_rclk),
        .rAddr(cam_fb_rAddr),
        .rData(cam_fb_rData)
    );

    UpScaleImgReader U_CAM_FB_READER (
        .de        (de),
        .x_pixel   (x_pixel),
        .y_pixel   (y_pixel),
        .addr      (cam_fb_rAddr),
        .imgPxlData(cam_fb_rData),
        .port_red  (cam_rgb[11:8]),
        .port_green(cam_rgb[7:4]),
        .port_blue (cam_rgb[3:0])
    );

endmodule
