`timescale 1ns / 1ps

module UI_Set #(
    parameter int IMG_W   = 320,
    parameter int WIDTH_W = $clog2(IMG_W),
    parameter int IMG_H   = 240,
    parameter int WIDTH_H = $clog2(IMG_H),
    parameter int ADDR_W  = $clog2(IMG_W * IMG_H),

    // =========================================================
    // LED 검출 튜닝 파라미터 (단일 조정 지점)
    //
    // 서버 랙 유닛의 삼색 LED를 검출한다. 초록 = 정상, 빨강 = 이상.
    // LED는 발광체이므로 조도(V_MIN_LED)로 반사체 배경을 먼저 제거하고,
    // 그 여유로 채도/카운트 조건을 완화한다.
    //
    // 1차 보드 실측(브레드보드 LED 5개, 십자선 사진)을 반영한 값이다.
    // 정밀 확정은 tools/led_probe.py 실측 후에 한다.
    // =========================================================

    // 셀당 최소 매칭 픽셀 수. 셀 하나가 20x20 = 400픽셀이다.
    // 박스가 조각나서 나타나면 더 낮춘다.
    // [되돌림] 4로 낮췄더니 검출이 오히려 나빠져 6으로 복구했다.
    // 배경 셀이 매칭되면 진짜 LED 셀과 병합되어 blob이 커지고,
    // MAX_BLOB_CELLS 크기 필터에 폐기되면서 LED까지 사라진다.
    parameter int LED_THRESHOLD      = 6,

    // 박스 최대 변 길이(그리드 칸). 네온 스트립 등 대형 광원을 막는다.
    parameter int LED_MAX_BLOB_CELLS = 3,

    // =========================================================
    // 박스 깜빡임 억제 (프레임 간 히스테리시스)
    //
    // 셀마다 신뢰도 카운터를 두고 비대칭으로 갱신한다.
    // 잡히면 빨리 올리고(UP), 안 잡히면 천천히 내린다(DOWN).
    //
    // 유지 시간 조절법 (30fps 기준):
    //   더 오래 유지하고 싶으면 -> LED_CONF_DOWN을 낮추거나 CONF_MAX를 올린다
    //   LED가 꺼질 때 더 빨리 반응하려면 -> LED_CONF_DOWN을 올린다
    //   깜빡임이 남으면 -> LED_CONF_UP을 올려 더 빨리 차오르게 한다
    //
    // 기본값: 1프레임 잡히면 즉시 켜지고(0->4 >= ON),
    //         꾸준히 잡히면 15까지 차올라 연속 11프레임(약 0.37초) 유지.
    // =========================================================
    parameter logic [3:0] LED_CONF_MAX  = 4'd15,
    parameter logic [3:0] LED_CONF_UP   = 4'd4,
    parameter logic [3:0] LED_CONF_DOWN = 4'd1,
    parameter logic [3:0] LED_CONF_ON   = 4'd4,

    // 발광체 판정 조도 하한 (63 만점). 배경 최대 밝기보다 위로 잡는다.
    // [되돌림] 34 → 40. 완화하면 배경이 게이트를 통과해 위와 같은 병합 문제가 생긴다.
    parameter logic [5:0] LED_V_MIN          = 6'd40,
    // 이 값 이상은 포화된 LED 코어로 보고 채도 비율 조건을 면제한다.
    // [되돌림] 56 → 58.
    // 이 값은 "포화 코어" 판정 기준이며, GREEN_BLUE_TOL이 적용되는 조건이기도 하다.
    parameter logic [5:0] LED_V_CLIP         = 6'd58,
    parameter logic [5:0] LED_DELTA_MIN      = 6'd4,
    // 흰 브레드보드처럼 밝은 무채색 표면이 초록으로 오검출되면 이 값을 올린다.
    // 오검출을 막는 1차 방어선이다.
    parameter logic [5:0] LED_DELTA_MIN_CLIP = 6'd3,
    // red/green 데드밴드. RGB565의 R/B 양자화 계단이 2이므로 최소 2.
    parameter logic [5:0] LED_HUE_MARGIN     = 6'd2,
    // 과노출된 초록 LED가 청록으로 번져 B > G가 되는 것을 허용하는 폭.
    // 초록이 여전히 누락되면 6~8까지 올린다. 단, 청색 계열 광원 방어가 약해진다.
    parameter logic [5:0] LED_GREEN_BLUE_TOL = 6'd4
) (
    input logic reset,

    // Raw camera write stream from CAM_Set
    input logic              cam_pclk,
    input logic              cam_we,
    input logic [ADDR_W-1:0] cam_wAddr,
    input logic [      15:0] cam_wData,

    // VGA read/display domain from VGA_Decoder
    input logic       rclk,
    input logic [9:0] x_pixel,
    input logic [9:0] y_pixel,
    input logic       de,

    output logic       ui_en,
    output logic       friend_detect,
    output logic       enemy_detect,
    output logic [1:0] bitmap_pixel,

    // For UART_Set
    output logic               uart_out_valid,
    output logic               uart_out_type,
    output logic [WIDTH_W-1:0] uart_out_cx,
    output logic [WIDTH_H-1:0] uart_out_cy,
    output logic [WIDTH_W-1:0] uart_out_w,
    output logic [WIDTH_H-1:0] uart_out_h,
    output logic               frame_done
);

    // Detector output: 0 = enemy, 1 = friend
    logic       det_valid;
    logic       det_ready;
    logic [8:0] det_x;
    logic [7:0] det_y;
    logic [8:0] det_w;
    logic [7:0] det_h;
    logic       det_type;

    // Rendered UI pixel stream: 0 = enemy, 1 = friend
    logic       ui_pix_valid;
    logic       ui_pix_ready;
    logic [8:0] ui_pix_x;
    logic [7:0] ui_pix_y;
    logic       ui_pix_type;

    logic ui_done;

    // A zero bitmap pixel is transparent in SCREEN_MUX.
    assign ui_en = 1'b1;

    // UART Output
    assign uart_out_valid = det_valid;
    assign uart_out_type  = det_type;
    assign uart_out_cx    = det_x;
    assign uart_out_cy    = det_y;
    assign uart_out_w     = det_w;
    assign uart_out_h     = det_h;
    // assign frame_done     = cam_we & ( cam_wAddr == ((IMG_W * IMG_H) - 1) );

    drone_detector #(
        .WIDTH   (IMG_W),
        .HEIGHT  (IMG_H),
        .DIVIDE_X(16),
        .DIVIDE_Y(12),

        // LED 검출 튜닝 파라미터.
        // 초기값은 추정치이며, 보드 실측(단계 2 UART 프로브) 후 여기서 조정한다.
        .THRESHOLD     (LED_THRESHOLD),
        .MAX_BLOB_CELLS(LED_MAX_BLOB_CELLS),
        .CONF_MAX      (LED_CONF_MAX),
        .CONF_UP       (LED_CONF_UP),
        .CONF_DOWN     (LED_CONF_DOWN),
        .CONF_ON       (LED_CONF_ON),
        .V_MIN_LED     (LED_V_MIN),
        .V_CLIP        (LED_V_CLIP),
        .DELTA_MIN     (LED_DELTA_MIN),
        .DELTA_MIN_CLIP(LED_DELTA_MIN_CLIP),
        .HUE_MARGIN    (LED_HUE_MARGIN),
        .GREEN_BLUE_TOL(LED_GREEN_BLUE_TOL)
    ) U_DRONE_DETECTOR (
        .clk   (cam_pclk),
        .reset (reset),
        .we    (cam_we),
        .wAddr (cam_wAddr),
        .wData (cam_wData),

        .center_x     (det_x),
        .center_y     (det_y),
        .target_width (det_w),
        .target_height(det_h),
        .target_type  (det_type),
        .target_valid (det_valid),
        .frame_done   (frame_done)
    );

    // Hold detection status until the next camera frame begins.
    always_ff @(posedge cam_pclk or posedge reset) begin
        if (reset) begin
            friend_detect <= 1'b0;
            enemy_detect  <= 1'b0;
        end else begin
            if (cam_we && (cam_wAddr == '0)) begin
                friend_detect <= 1'b0;
                enemy_detect  <= 1'b0;
            end

            if (det_valid) begin
                if (det_type)
                    friend_detect <= 1'b1;
                else
                    enemy_detect <= 1'b1;
            end
        end
    end

    ui_generator #(
        .IMG_W(IMG_W),
        .IMG_H(IMG_H)
    ) U_UI_GENERATOR (
        .clk  (cam_pclk),
        .reset(reset),

        .det_valid(det_valid),
        .det_ready(det_ready),
        .det_x    (det_x),
        .det_y    (det_y),
        .det_w    (det_w),
        .det_h    (det_h),
        .det_type (det_type),

        .pix_valid(ui_pix_valid),
        .pix_ready(ui_pix_ready),
        .pix_x    (ui_pix_x),
        .pix_y    (ui_pix_y),
        .pix_type (ui_pix_type)
    );

    ui_framebuffer #(
        .WIDTH (IMG_W),
        .HEIGHT(IMG_H),
        .ADDR_W(ADDR_W)
    ) U_UI_FRAMEBUFFER (
        .write_clk(cam_pclk),
        .read_clk (rclk),
        .reset    (reset),

        .ready(ui_pix_ready),
        .done (ui_done),

        .valid      (ui_pix_valid),
        .target_type(ui_pix_type),
        .box_x      (ui_pix_x),
        .box_y      (ui_pix_y),

        .x_pixel(x_pixel),
        .y_pixel(y_pixel),
        .de     (de),

        .bitmap_pixel(bitmap_pixel)
    );

endmodule
