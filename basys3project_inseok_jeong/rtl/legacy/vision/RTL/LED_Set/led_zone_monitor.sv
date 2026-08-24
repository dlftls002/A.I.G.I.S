`timescale 1ns / 1ps

// 고정 구역(ROI) 24개의 LED 상태를 판정한다.
//
// 기존 drone_detector는 위치를 모르는 물체를 찾는 구조라 blob 병합,
// 슬롯 배정, 크기 필터가 필요했다. LED 위치가 고정된 이 용도에서는
// 그 단계가 전부 불필요하고, 오히려 오검출의 원인이었다.
// (배경 셀이 진짜 LED 셀과 병합되어 크기 필터에 함께 폐기되는 문제)
//
// 여기서는 픽셀이 어느 ROI에 속하는지 24개 비교기로 병렬 판정하고,
// ROI마다 초록/빨강 픽셀을 센다. 병합이 없으므로 그 문제가 사라진다.
//
// 픽셀 분류는 Drone_Classification_Color를 그대로 쓴다.
module led_zone_monitor
    import led_zone_pkg::*;
#(
    parameter int WIDTH  = 320,
    parameter int HEIGHT = 240,

    // ROI 하나가 "점등"으로 판정되기 위한 최소 픽셀 수.
    // ROI는 수천 픽셀이고 LED는 그 일부만 차지하므로 작게 잡는다.
    // 조도 게이트가 배경을 이미 제거한다.
    parameter int ZONE_THRESHOLD = 8,

    // 프레임 간 히스테리시스. Drone_pixel_counter에서 검증된 방식을
    // LED 단위로 옮긴 것이다. 박스/상태 깜빡임을 억제한다.
    //   기본값 기준: 1프레임 잡히면 즉시 켜지고,
    //   지속 검출 후 신호가 끊기면 11프레임(30fps에서 약 366ms) 유지.
    parameter logic [3:0] CONF_MAX  = 4'd15,
    parameter logic [3:0] CONF_UP   = 4'd4,
    parameter logic [3:0] CONF_DOWN = 4'd1,
    parameter logic [3:0] CONF_ON   = 4'd4
) (
    input logic clk,     // cam_pclk
    input logic reset,

    // 카메라 쓰기 스트림
    input logic                             we,
    input logic [$clog2(WIDTH*HEIGHT)-1:0]  wAddr,

    // 픽셀 분류 결과 (Drone_Classification_Color)
    input logic pixel_green,   // = pixel_ally
    input logic pixel_red,     // = pixel_enemy

    // ROI별 LED 상태. LED z는 led_flat[2*z +: 2].
    output logic [LED_FLAT_W-1:0] led_flat,

    // 프레임 경계 펄스 (상태가 갱신된 시점)
    output logic       frame_tick
);

    localparam int MAX_ZONE_PIXELS = ZONE_MAX_PIXELS;
    localparam int CNT_W           = $clog2(MAX_ZONE_PIXELS + 1);

    // ---------------------------------------------------------
    // 픽셀 좌표
    //
    // wAddr을 WIDTH로 나누지 않고 카운터로 추적한다.
    // 320은 2의 거듭제곱이 아니라 나눗셈이 비싸다.
    // ---------------------------------------------------------
    logic [$clog2(WIDTH)-1:0]  px;
    logic [$clog2(HEIGHT)-1:0] py;

    logic frame_start;
    assign frame_start = we && (wAddr == '0);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            px <= '0;
            py <= '0;
        end else if (we) begin
            if (wAddr == '0) begin
                // 프레임 시작. 주소 0은 (0,0)이므로 다음 픽셀은 (1,0).
                px <= 1;
                py <= '0;
            end else if (px == WIDTH - 1) begin
                px <= '0;
                py <= py + 1;
            end else begin
                px <= px + 1;
            end
        end
    end

    // ---------------------------------------------------------
    // ROI 소속 판정 (24개 병렬 비교)
    //
    // 산술로 구역 인덱스를 계산하지 않는 이유:
    //   구역마다 좌표가 다른 불규칙 배치(원근 보정)를 그대로 수용할 수 있고,
    //   비교기 몇 개로 끝나기 때문이다. 산술 계산으로는 표현할 수 없다.
    // ---------------------------------------------------------
    // 현재 버스에 실린 픽셀의 좌표.
    // px/py 레지스터는 이 엣지에서 다음 좌표로 갱신되므로,
    // 프레임 시작(주소 0)에서는 레지스터가 아직 이전 프레임의 값을 들고 있다.
    // 주소 0은 정의상 (0,0)이므로 명시적으로 처리한다.
    logic [$clog2(WIDTH)-1:0]  cur_px;
    logic [$clog2(HEIGHT)-1:0] cur_py;

    assign cur_px = (wAddr == '0) ? '0 : px;
    assign cur_py = (wAddr == '0) ? '0 : py;

    // 화면 좌표를 회전 후 좌표계로 옮긴다.
    //
    // 브레드보드가 화면에서 대각선으로 누워 보이므로 구역도 기울어야 한다.
    // 구역 6개를 각각 회전시키지 않고 픽셀을 한 번만 역회전시킨 뒤
    // 축 정렬 비교를 한다. 곱셈이 6배로 늘지 않는다.
    //
    // 회전 후 좌표는 음수가 되거나 프레임 범위를 벗어날 수 있으므로
    // 부호 있는 넓은 폭으로 받는다.
    logic signed [11:0] rot_px;
    logic signed [11:0] rot_py;

    assign rot_px = 12'(rot_x(int'(cur_px), int'(cur_py)));
    assign rot_py = 12'(rot_y(int'(cur_px), int'(cur_py)));

    logic [NUM_ZONES-1:0] in_zone;

    always_comb begin
        for (int z = 0; z < NUM_ZONES; z++) begin
            in_zone[z] = (rot_px >= 12'(zone_x0(z))) && (rot_px <= 12'(zone_x1(z))) &&
                         (rot_py >= 12'(zone_y0(z))) && (rot_py <= 12'(zone_y1(z)));
        end
    end

    // ---------------------------------------------------------
    // ROI별 픽셀 카운터
    // ---------------------------------------------------------
    logic [CNT_W-1:0] green_cnt [NUM_ZONES];
    logic [CNT_W-1:0] red_cnt   [NUM_ZONES];

    // 이번 프레임 관측 결과
    logic [NUM_ZONES-1:0] obs_green;
    logic [NUM_ZONES-1:0] obs_red;

    always_comb begin
        for (int z = 0; z < NUM_ZONES; z++) begin
            obs_green[z] = (green_cnt[z] >= ZONE_THRESHOLD);
            obs_red[z]   = (red_cnt[z]   >= ZONE_THRESHOLD);
        end
    end

    // ---------------------------------------------------------
    // 히스테리시스 신뢰도
    // ---------------------------------------------------------
    logic [3:0] green_conf [NUM_ZONES];
    logic [3:0] red_conf   [NUM_ZONES];

    logic [3:0] green_conf_next [NUM_ZONES];
    logic [3:0] red_conf_next   [NUM_ZONES];

    always_comb begin
        for (int z = 0; z < NUM_ZONES; z++) begin
            // green
            if (obs_green[z]) begin
                if (green_conf[z] > (CONF_MAX - CONF_UP))
                    green_conf_next[z] = CONF_MAX;
                else
                    green_conf_next[z] = green_conf[z] + CONF_UP;
            end else begin
                if (green_conf[z] > CONF_DOWN)
                    green_conf_next[z] = green_conf[z] - CONF_DOWN;
                else
                    green_conf_next[z] = 4'd0;
            end

            // red
            if (obs_red[z]) begin
                if (red_conf[z] > (CONF_MAX - CONF_UP))
                    red_conf_next[z] = CONF_MAX;
                else
                    red_conf_next[z] = red_conf[z] + CONF_UP;
            end else begin
                if (red_conf[z] > CONF_DOWN)
                    red_conf_next[z] = red_conf[z] - CONF_DOWN;
                else
                    red_conf_next[z] = 4'd0;
            end
        end
    end

    // ---------------------------------------------------------
    // 상태 갱신
    //
    // 빨강 우선: 한 ROI에서 초록과 빨강이 동시에 안정화되는 일은
    // 물리적으로 없어야 하지만, 생기면 이상 쪽으로 판정한다 (fail-safe).
    // ---------------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            frame_tick <= 1'b0;
            for (int z = 0; z < NUM_ZONES; z++) begin
                green_cnt[z]  <= '0;
                red_cnt[z]    <= '0;
                green_conf[z] <= 4'd0;
                red_conf[z]   <= 4'd0;
                led_flat[2*z +: 2] <= LED_OFF;
            end
        end else begin
            frame_tick <= 1'b0;

            if (we) begin
                if (wAddr == '0) begin
                    // 프레임 경계: 직전 프레임 확정 후 카운터 초기화
                    frame_tick <= 1'b1;

                    for (int z = 0; z < NUM_ZONES; z++) begin
                        green_conf[z] <= green_conf_next[z];
                        red_conf[z]   <= red_conf_next[z];

                        if (red_conf_next[z] >= CONF_ON)
                            led_flat[2*z +: 2] <= LED_RED;
                        else if (green_conf_next[z] >= CONF_ON)
                            led_flat[2*z +: 2] <= LED_GREEN;
                        else
                            led_flat[2*z +: 2] <= LED_OFF;

                        // 카운터 초기화. 단 주소 0 픽셀 자신도 이번 프레임의
                        // 첫 픽셀이므로 ROI에 속하면 1부터 시작한다.
                        if (in_zone[z] && pixel_green) green_cnt[z] <= 1;
                        else                           green_cnt[z] <= '0;

                        if (in_zone[z] && pixel_red)   red_cnt[z] <= 1;
                        else                           red_cnt[z] <= '0;
                    end
                end else begin
                    for (int z = 0; z < NUM_ZONES; z++) begin
                        if (in_zone[z]) begin
                            if (pixel_green && (green_cnt[z] != MAX_ZONE_PIXELS))
                                green_cnt[z] <= green_cnt[z] + 1;
                            if (pixel_red && (red_cnt[z] != MAX_ZONE_PIXELS))
                                red_cnt[z] <= red_cnt[z] + 1;
                        end
                    end
                end
            end
        end
    end

endmodule
