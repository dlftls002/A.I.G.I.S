`timescale 1ns / 1ps

// 서버 랙 LED 상태 감시 시스템.
//
//   OV7670 -> CAM_Set -+-> cam_rgb ------------> Frame_Set -> VGA
//                      |                            ^ (구역 격자 오버레이)
//                      +-> cam write stream -> LED_Set -> payload -> spi_slave -> Zybo
//
// 이전의 드론 검출(blob 탐지 + UI 프레임버퍼) 경로는 제거했다.
// LED 위치가 고정이므로 고정 구역 판정으로 대체했고, 화면 박스도
// 프레임버퍼 없이 Frame_Set의 조합 오버레이로 그린다.
module TOP_sys
    import led_zone_pkg::*;
(
    input logic clk,
    input logic reset,

    // Board switches
    //   sw[0]: LED 구역 격자 오버레이 enable
    //   sw[1]: 예약
    input logic [1:0] sw,

    // OV7670 side
    input  logic       pclk,
    output logic       xclk,
    input  logic       href,
    input  logic       vsync,
    input  logic [7:0] pdata,

    // VGA side
    output logic       h_sync,
    output logic       v_sync,
    output logic [3:0] port_red,
    output logic [3:0] port_green,
    output logic [3:0] port_blue,

    // SCCB
    output logic scl,
    inout  tri   sda,

    // SPI slave (Pmod JA) — 관제 보드(Zybo)가 마스터
    input  logic spi_sclk,
    input  logic spi_mosi,
    input  logic spi_cs_n,
    output logic spi_miso,

    // 상태 표시 LED (동작 확인용)
    output logic [15:0] led
);
    localparam int IMG_W  = 320;
    localparam int IMG_H  = 240;
    localparam int ADDR_W = $clog2(IMG_W * IMG_H);

    // Clock signals
    logic clk_100M;
    logic clk_25M;
    logic rclk;

    // VGA timing
    logic        vga_h_sync;
    logic        vga_v_sync;
    logic [ 9:0] x_pixel;
    logic [ 9:0] y_pixel;
    logic        de;

    // 카메라 영상
    logic [11:0] cam_rgb;

    // 카메라 원본 쓰기 스트림 (검출용)
    logic              cam_pclk;
    logic              cam_we;
    logic [ADDR_W-1:0] cam_wAddr;
    logic [      15:0] cam_wData;

    // LED 상태
    logic [LED_FLAT_W-1:0]  led_flat;
    logic [UNIT_FLAT_W-1:0] unit_flat;
    logic [PAYLOAD_W-1:0]   payload;

    // SPI 디버그 관측
    logic spi_dbg_cs_active;
    logic spi_dbg_pkt_done;

    // =========================================================
    // Camera
    // =========================================================

    CAM_Set #(
        .IMG_W (IMG_W),
        .IMG_H (IMG_H),
        .ADDR_W(ADDR_W)
    ) U_CAM_SET (
        .clk  (clk),
        .reset(reset),

        .pclk (pclk),
        .href (href),
        .vsync(vsync),
        .pdata(pdata),
        .xclk (xclk),

        .scl(scl),
        .sda(sda),

        .clk_100M(clk_100M),
        .clk_25M (clk_25M),

        .cam_fb_rclk(rclk),
        .x_pixel    (x_pixel),
        .y_pixel    (y_pixel),
        .de         (de),
        .cam_rgb    (cam_rgb),

        .cam_pclk (cam_pclk),
        .cam_we   (cam_we),
        .cam_wAddr(cam_wAddr),
        .cam_wData(cam_wData)
    );

    // =========================================================
    // VGA timing generator
    // =========================================================

    VGA_Decoder U_VGA_DECODER (
        .clk  (clk_100M),
        .reset(reset),

        .rclk   (rclk),
        .h_sync (vga_h_sync),
        .v_sync (vga_v_sync),
        .x_pixel(x_pixel),
        .y_pixel(y_pixel),
        .de     (de)
    );

    // =========================================================
    // LED 상태 감시
    //
    // 튜닝 파라미터는 전부 LED_Set의 기본값을 쓴다.
    // 조정이 필요하면 여기서 오버라이드한다.
    // =========================================================

    LED_Set #(
        .IMG_W (IMG_W),
        .IMG_H (IMG_H),
        .ADDR_W(ADDR_W)
    ) U_LED_SET (
        .reset(reset),

        .cam_pclk (cam_pclk),
        .cam_we   (cam_we),
        .cam_wAddr(cam_wAddr),
        .cam_wData(cam_wData),

        .led_flat (led_flat),
        .unit_flat(unit_flat),
        .payload  (payload)
    );

    // =========================================================
    // SPI slave — 관제 보드로 상태 전송
    //
    // 시스템 클럭(100MHz)으로 SCLK를 오버샘플링한다.
    // 프로토콜은 docs/SPI_INTERFACE.md 참조.
    // =========================================================

    spi_slave U_SPI_SLAVE (
        .clk  (clk_100M),
        .reset(reset),

        .payload(payload),

        .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi),
        .spi_cs_n(spi_cs_n),
        .spi_miso(spi_miso),

        .dbg_cs_active(spi_dbg_cs_active),
        .dbg_pkt_done (spi_dbg_pkt_done)
    );

    // =========================================================
    // 보드 LED
    //
    // PC 없이 SPI가 실제로 오가는지 확인하기 위한 것이다.
    // SUMMARY 바이트는 페이로드 오프셋 5에 있다.
    // =========================================================

    status_leds #(
        .CLK_FREQ(100_000_000)
    ) U_STATUS_LEDS (
        .clk      (clk_100M),
        .reset    (reset),
        .cs_active(spi_dbg_cs_active),
        .pkt_done (spi_dbg_pkt_done),
        .summary  (payload[8*5 +: 4]),
        .led      (led)
    );

    // =========================================================
    // VGA 출력 + 구역 격자 오버레이
    // =========================================================

    Frame_Set #(
        .IMG_W (IMG_W),
        .IMG_H (IMG_H),
        .ADDR_W(ADDR_W)
    ) U_FRAME_SET (
        .clk_100M(clk_100M),
        .reset   (reset),

        .h_sync_i(vga_h_sync),
        .v_sync_i(vga_v_sync),
        .x_pixel (x_pixel),
        .y_pixel (y_pixel),
        .de      (de),

        .screen_rgb(cam_rgb),
        .led_flat  (led_flat),
        .overlay_en(sw[0]),

        .h_sync    (h_sync),
        .v_sync    (v_sync),
        .port_red  (port_red),
        .port_green(port_green),
        .port_blue (port_blue)
    );

endmodule
