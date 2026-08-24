module drone_detector #(
    parameter int WIDTH = 320,
    parameter int HEIGHT = 240,
    parameter int DIVIDE_X = 16,
    parameter int DIVIDE_Y = 12,

    // 셀당 최소 매칭 픽셀 수 (Drone_pixel_counter)
    parameter int THRESHOLD = 6,

    // 프레임 간 시간적 히스테리시스 (Drone_pixel_counter)
    // 박스 깜빡임을 줄인다. 자세한 설명은 Drone_pixel_counter.sv 참조.
    parameter logic [3:0] CONF_MAX  = 4'd15,
    parameter logic [3:0] CONF_UP   = 4'd4,
    parameter logic [3:0] CONF_DOWN = 4'd1,
    parameter logic [3:0] CONF_ON   = 4'd4,

    // 박스 최대 변 길이, 그리드 칸 단위 (drone_posit_size)
    parameter int MAX_BLOB_CELLS = 3,

    // LED 분류기 파라미터 (Drone_Classification_Color)
    parameter logic [5:0] V_MIN_LED      = 6'd34,
    parameter logic [5:0] V_CLIP         = 6'd56,
    parameter logic [5:0] DELTA_MIN      = 6'd4,
    parameter logic [5:0] DELTA_MIN_CLIP = 6'd3,
    parameter logic [5:0] HUE_MARGIN     = 6'd2,
    parameter logic [5:0] GREEN_BLUE_TOL = 6'd4
) (
    input logic clk,
    input logic reset,

    input logic we,
    input logic [$clog2(WIDTH*HEIGHT)-1:0] wAddr,
    input logic [15:0] wData,

    // Final outputs
    output logic [$clog2(WIDTH)-1:0] center_x,
    output logic [$clog2(HEIGHT)-1:0] center_y,
    output logic [$clog2(WIDTH)-1:0] target_width,
    output logic [$clog2(HEIGHT)-1:0] target_height,
    output logic target_type,  // 0: 빨강 LED(이상), 1: 초록 LED(정상)
    output logic target_valid,
    output logic frame_done
);

    logic                                   pixel_ally;
    logic                                   pixel_enemy;

    logic                                   pxc_type; // 1: 초록(정상), 0: 빨강(이상)
    logic [$clog2(DIVIDE_X * DIVIDE_Y)-1:0] pxc_area_addr;
    logic                                   pxc_valid;
    logic                                   pxc_frame_done;

    Drone_Classification_Color #(
        .V_MIN_LED     (V_MIN_LED),
        .V_CLIP        (V_CLIP),
        .DELTA_MIN     (DELTA_MIN),
        .DELTA_MIN_CLIP(DELTA_MIN_CLIP),
        .HUE_MARGIN    (HUE_MARGIN),
        .GREEN_BLUE_TOL(GREEN_BLUE_TOL)
    ) U_DCC (
        .we          (we),
        .wData       (wData),
        .pixel_ally  (pixel_ally),
        .pixel_enemy (pixel_enemy)
    );

    Drone_pixel_counter #(
        .WIDTH    (WIDTH),
        .HEIGHT   (HEIGHT),
        .DIVIDE_X (DIVIDE_X),
        .DIVIDE_Y (DIVIDE_Y),
        .THRESHOLD(THRESHOLD),
        .CONF_MAX (CONF_MAX),
        .CONF_UP  (CONF_UP),
        .CONF_DOWN(CONF_DOWN),
        .CONF_ON  (CONF_ON)
    ) U_DPC (
        .clk    (clk),
        .reset  (reset),
        .we     (we),
        .wAddr  (wAddr),

        .drone_ally  (pixel_ally),
        .drone_enemy (pixel_enemy),

        .out_type       (pxc_type),
        .out_area_addr  (pxc_area_addr),
        .out_valid      (pxc_valid),
        .frame_done     (pxc_frame_done)
    );

    drone_posit_size #(
        .WIDTH         (WIDTH),
        .HEIGHT        (HEIGHT),
        .DIVIDE_X      (DIVIDE_X),
        .DIVIDE_Y      (DIVIDE_Y),
        .MAX_BLOB_CELLS(MAX_BLOB_CELLS)
    ) U_DPS (
        .clk            (clk),
        .reset          (reset),
        .in_valid       (pxc_valid),
        .in_type        (pxc_type),
        .in_area_addr   (pxc_area_addr),
        .in_frame_done  (pxc_frame_done),
        .center_x       (center_x),
        .center_y       (center_y),
        .target_width   (target_width),
        .target_height  (target_height),
        .target_type    (target_type),
        .target_valid   (target_valid),
        .frame_done     (frame_done)
    );

endmodule
