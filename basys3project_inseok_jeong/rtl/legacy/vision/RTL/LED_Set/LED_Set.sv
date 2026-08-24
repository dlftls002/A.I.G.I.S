`timescale 1ns / 1ps

// 서버 랙 LED 상태 감시 파이프라인.
//
//   카메라 쓰기 스트림
//     -> Drone_Classification_Color  픽셀 단위 초록/빨강 판정
//     -> led_zone_monitor            고정 ROI 24개 카운트 + 히스테리시스
//     -> unit_status                 LED 2개 -> 유닛 상태
//     -> status_packer               SPI 페이로드 32바이트 조립
//
// 전부 cam_pclk 도메인에서 동작한다. SPI 슬레이브는 시스템 클럭 도메인이며
// TOP_sys에서 별도로 인스턴스화한다.
//
// 기존 UI_Set(blob 탐지)을 대체한다. LED 위치가 고정이므로 blob 병합/슬롯
// 배정/크기 필터가 필요 없고, 그 단계들이 오히려 오검출의 원인이었다.
module LED_Set
    import led_zone_pkg::*;
#(
    parameter int IMG_W  = 320,
    parameter int IMG_H  = 240,
    parameter int ADDR_W = $clog2(IMG_W * IMG_H),

    // ---- 픽셀 분류 임계값 (Drone_Classification_Color) ----
    // 보드 실측으로 확정한 값. 자세한 근거는 해당 파일 주석 참조.
    parameter logic [5:0] LED_V_MIN          = 6'd40,
    parameter logic [5:0] LED_V_CLIP         = 6'd58,
    parameter logic [5:0] LED_DELTA_MIN      = 6'd4,
    parameter logic [5:0] LED_DELTA_MIN_CLIP = 6'd3,
    parameter logic [5:0] LED_HUE_MARGIN     = 6'd2,
    parameter logic [5:0] LED_GREEN_BLUE_TOL = 6'd4,

    // ---- 구역 판정 ----
    // ROI 하나가 점등으로 인정되기 위한 최소 픽셀 수
    parameter int ZONE_THRESHOLD = 8,

    // ---- 깜빡임 억제 ----
    parameter logic [3:0] CONF_MAX  = 4'd15,
    parameter logic [3:0] CONF_UP   = 4'd4,
    parameter logic [3:0] CONF_DOWN = 4'd1,
    parameter logic [3:0] CONF_ON   = 4'd4
) (
    input logic reset,

    // 카메라 쓰기 스트림 (cam_pclk 도메인)
    input logic              cam_pclk,
    input logic              cam_we,
    input logic [ADDR_W-1:0] cam_wAddr,
    input logic [      15:0] cam_wData,

    // LED 상태 (화면 오버레이용)
    output logic [LED_FLAT_W-1:0]  led_flat,
    output logic [UNIT_FLAT_W-1:0] unit_flat,

    // SPI 페이로드
    output logic [PAYLOAD_W-1:0] payload
);

    logic pixel_green;   // 초록 LED = 정상
    logic pixel_red;     // 빨강 LED = 이상
    logic frame_tick;

    // 픽셀 단위 색 판정.
    // 모듈 이름은 드론 검출기 시절 그대로다. 동작은 LED 판정에 맞게
    // 재작성되어 있으며, 이름 정리는 별도 작업으로 남겨 두었다.
    Drone_Classification_Color #(
        .V_MIN_LED     (LED_V_MIN),
        .V_CLIP        (LED_V_CLIP),
        .DELTA_MIN     (LED_DELTA_MIN),
        .DELTA_MIN_CLIP(LED_DELTA_MIN_CLIP),
        .HUE_MARGIN    (LED_HUE_MARGIN),
        .GREEN_BLUE_TOL(LED_GREEN_BLUE_TOL)
    ) U_PIXEL_CLASS (
        .we         (cam_we),
        .wData      (cam_wData),
        .pixel_ally (pixel_green),
        .pixel_enemy(pixel_red)
    );

    led_zone_monitor #(
        .WIDTH         (IMG_W),
        .HEIGHT        (IMG_H),
        .ZONE_THRESHOLD(ZONE_THRESHOLD),
        .CONF_MAX      (CONF_MAX),
        .CONF_UP       (CONF_UP),
        .CONF_DOWN     (CONF_DOWN),
        .CONF_ON       (CONF_ON)
    ) U_ZONE_MONITOR (
        .clk        (cam_pclk),
        .reset      (reset),
        .we         (cam_we),
        .wAddr      (cam_wAddr),
        .pixel_green(pixel_green),
        .pixel_red  (pixel_red),
        .led_flat   (led_flat),
        .frame_tick (frame_tick)
    );

    unit_status U_UNIT_STATUS (
        .led_flat (led_flat),
        .unit_flat(unit_flat)
    );

    status_packer U_PACKER (
        .clk       (cam_pclk),
        .reset     (reset),
        .led_flat  (led_flat),
        .unit_flat (unit_flat),
        .frame_tick(frame_tick),
        .payload   (payload)
    );

endmodule
