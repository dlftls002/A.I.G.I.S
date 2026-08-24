`timescale 1ns / 1ps

// VGA 최종 출력 단계 + LED 구역 격자 오버레이.
//
// 검출된 blob에 박스를 그리던 방식(ui_generator + ui_framebuffer)을 대체한다.
// LED 위치가 고정이므로 프레임버퍼가 필요 없고 조합 논리로 충분하다.
// 부수 효과로 "매 표시 프레임마다 지우고 다시 채우는" 경합이 사라져
// 박스 깜빡임의 구조적 원인이 없어졌다.
//
// 격자는 카메라 정렬용이기도 하다. 24칸을 항상 그려두고 LED가 칸 안에
// 들어오도록 카메라를 물리적으로 맞추면 캘리브레이션이 끝난다.
// 어긋나면 led_zone_pkg의 배치 파라미터를 조정한다.
//
// 칸 색:
//   초록 LED 감지 -> 초록 테두리
//   빨강 LED 감지 -> 빨강 테두리
//   꺼짐          -> 회색 테두리 (칸 위치는 계속 보여야 정렬할 수 있다)
module Frame_Set
    import led_zone_pkg::*;
#(
    parameter int IMG_W  = 320,
    parameter int IMG_H  = 240,
    parameter int ADDR_W = $clog2(IMG_W * IMG_H)
) (
    input  logic       clk_100M,
    input  logic       reset,

    // VGA timing from VGA_Decoder
    input  logic       h_sync_i,
    input  logic       v_sync_i,
    input  logic [9:0] x_pixel,
    input  logic [9:0] y_pixel,
    input  logic       de,

    // 카메라 영상
    input  logic [11:0] screen_rgb,

    // LED 상태 (LED_Set). LED z는 led_flat[2*z +: 2].
    input  logic [LED_FLAT_W-1:0] led_flat,

    // 격자 오버레이 enable (보드 스위치)
    input  logic overlay_en,

    // Final VGA side
    output logic       h_sync,
    output logic       v_sync,
    output logic [3:0] port_red,
    output logic [3:0] port_green,
    output logic [3:0] port_blue
);

    localparam logic [11:0] COLOR_GREEN = 12'h0F0;
    localparam logic [11:0] COLOR_RED   = 12'hF00;
    localparam logic [11:0] COLOR_GRAY  = 12'h888;

    // ---------------------------------------------------------
    // 좌표계
    //
    // 디스플레이 640x480, 카메라 320x240, UpScaleImgReader가 2배 확대한다.
    // 오버레이를 카메라 좌표로 기술하면 선 두께가 자동으로 화면 2픽셀이 되어
    // 모니터에서 잘 보인다.
    // ---------------------------------------------------------
    logic [8:0] cam_x;
    logic [7:0] cam_y;

    assign cam_x = x_pixel[9:1];
    assign cam_y = y_pixel[9:1];

    // ---------------------------------------------------------
    // ROI 테두리 판정
    //
    // 구역끼리 겹치지 않고 사이에 간격이 있으므로 (tb_led_zone이 전수 확인)
    // 한 픽셀이 두 구역의 테두리에 동시에 걸리는 일은 없다.
    // ---------------------------------------------------------
    // 검출과 동일한 회전을 적용한다.
    //
    // led_zone_monitor와 같은 변환을 써야 화면에 보이는 칸과 실제 판정
    // 영역이 일치한다. 둘이 어긋나면 정렬 자체가 무의미해진다.
    // 변환 함수는 led_zone_pkg에 하나만 두어 어긋날 수 없게 했다.
    //
    // 회전 각도는 led_zone_pkg의 ROT_COS/ROT_SIN이 정한다 (현재 90도).
    logic signed [11:0] rcam_x;
    logic signed [11:0] rcam_y;

    assign rcam_x = 12'(rot_x(int'(cam_x), int'(cam_y)));
    assign rcam_y = 12'(rot_y(int'(cam_x), int'(cam_y)));

    logic [NUM_ZONES-1:0] on_border;

    always_comb begin
        for (int z = 0; z < NUM_ZONES; z++) begin
            on_border[z] =
                (rcam_x >= 12'(zone_x0(z))) && (rcam_x <= 12'(zone_x1(z))) &&
                (rcam_y >= 12'(zone_y0(z))) && (rcam_y <= 12'(zone_y1(z))) &&
                ((rcam_x == 12'(zone_x0(z))) || (rcam_x == 12'(zone_x1(z))) ||
                 (rcam_y == 12'(zone_y0(z))) || (rcam_y == 12'(zone_y1(z))));
        end
    end

    logic        overlay_on;
    logic [11:0] overlay_rgb;

    always_comb begin
        overlay_on  = 1'b0;
        overlay_rgb = COLOR_GRAY;

        for (int z = 0; z < NUM_ZONES; z++) begin
            if (on_border[z]) begin
                overlay_on = 1'b1;

                case (led_flat[2*z +: 2])
                    LED_GREEN: overlay_rgb = COLOR_GREEN;
                    LED_RED:   overlay_rgb = COLOR_RED;
                    default:   overlay_rgb = COLOR_GRAY;
                endcase
            end
        end
    end

    // ---------------------------------------------------------
    // 합성. blank 구간에서는 반드시 0을 출력해야 한다.
    // ---------------------------------------------------------
    logic [11:0] final_rgb;

    always_comb begin
        if (!de)                            final_rgb = 12'h000;
        else if (overlay_en && overlay_on)  final_rgb = overlay_rgb;
        else                                final_rgb = screen_rgb;
    end

    assign h_sync = h_sync_i;
    assign v_sync = v_sync_i;
    assign {port_red, port_green, port_blue} = final_rgb;

endmodule
