`timescale 1ns / 1ps

// 서버 랙 유닛의 삼색 LED 상태를 픽셀 단위로 분류한다.
//   초록 LED = 정상 (pixel_ally)
//   빨강 LED = 이상 (pixel_enemy)
//
// LED는 반사체가 아니라 발광체다. 따라서 기존 드론(반사체) 검출용 HSV 조건을 그대로
// 쓰면 검출되지 않는다. 세 개의 게이트로 판정한다.
//   게이트 1 (조도)  : 발광체만 남긴다. 아래 두 게이트를 완화할 여유를 만든다.
//   게이트 2 (채도)  : 포화된 LED 코어에는 비율 조건을 면제한다.
//   게이트 3 (색상)  : 빨강/초록을 데드밴드를 두고 구분한다.
module Drone_Classification_Color #(
    // ---- 게이트 1: 조도 ----
    // 발광체 판정 하한 (6비트, 63 만점). 배경 최대 밝기보다 위로 잡는다.
    parameter logic [5:0] V_MIN_LED      = 6'd34,

    // ---- 게이트 2: 채도 ----
    // 이 값 이상은 센서가 포화된 LED 코어로 간주하고 채도 비율 조건을 면제한다.
    parameter logic [5:0] V_CLIP         = 6'd56,
    // 일반 픽셀의 최소 채널 격차
    parameter logic [5:0] DELTA_MIN      = 6'd4,
    // 포화 코어의 최소 채널 격차
    parameter logic [5:0] DELTA_MIN_CLIP = 6'd3,

    // ---- 게이트 3: 색상 ----
    // red/green 데드밴드.
    // RGB565의 R/B는 5비트를 MSB 복제로 6비트화하므로 실효 해상도가 2 계단이다.
    // 따라서 1은 양자화 잡음에 묻힌다. 최소 2여야 의미가 있다.
    parameter logic [5:0] HUE_MARGIN     = 6'd2,

    // 초록 판정에서 blue가 green을 얼마나 넘어서는 것까지 허용할지.
    //
    // [실측 반영] 보드 테스트에서 빨강 LED와 오른쪽 초록 LED는 잘 검출되는데
    // 과노출된 왼쪽 초록 LED들이 누락되었다. 원인은 베이어 센서 특성이다.
    // 초록 픽셀이 2배 많아 G 채널이 가장 먼저 포화되고, 이어서 청색 채널이
    // 초록 LED의 525nm 발광에 상당히 반응한다. 그 결과 과노출된 초록 LED의
    // 코어는 B가 G를 추월하여 청록/흰색으로 번지고, 엄격한 (G > B) 조건이 깨진다.
    //
    // 빨강 LED는 번져도 R이 최댓값을 유지하므로 (R > B)가 살아있다.
    // 즉 이 실패는 초록에만 나타나는 비대칭 현상이다.
    //
    // 청색 네온 스트립은 B=63, G=20 수준으로 격차가 크므로 이 허용치로는
    // 통과하지 못한다.
    parameter logic [5:0] GREEN_BLUE_TOL = 6'd4
) (
    // we는 현재 사용하지 않는다. 이 모듈은 wData에 대한 순수 조합 논리다.
    // 상위(Drone_detector)의 연결을 유지하기 위해 포트만 남겨 둔다.
    input  logic        we,
    input  logic [15:0] wData,

    output logic        pixel_ally,   // 1: 초록 LED = 정상
    output logic        pixel_enemy   // 1: 빨강 LED = 이상
);

    // =========================================================
    // 1. RGB565 -> 6비트 정규화
    //    R/B: 5비트를 MSB 복제로 6비트화 (31 -> 63, 30 -> 61)
    //    G  : 6비트 원본
    // =========================================================
    logic [5:0] color_red;
    logic [5:0] color_green;
    logic [5:0] color_blue;

    assign color_red   = {wData[15:11], wData[15]};
    assign color_green = {wData[10:5]};
    assign color_blue  = {wData[4:0], wData[4]};

    // =========================================================
    // 2. max / min / delta 추출
    // =========================================================
    logic [5:0] max_val;
    logic [5:0] min_val;
    logic [5:0] delta;

    always_comb begin
        if (color_red >= color_green && color_red >= color_blue)
            max_val = color_red;
        else if (color_green >= color_red && color_green >= color_blue)
            max_val = color_green;
        else
            max_val = color_blue;

        if (color_red <= color_green && color_red <= color_blue)
            min_val = color_red;
        else if (color_green <= color_red && color_green <= color_blue)
            min_val = color_green;
        else
            min_val = color_blue;
    end

    assign delta = max_val - min_val;

    // =========================================================
    // 3. 게이트 1 — 조도 (Value)
    //
    // 기존 조건은 max_val >= 10 으로, "어두운 그늘에서도 인식"을 노린 하한이라
    // 배경 대부분이 통과했다. LED는 발광체이므로 랙 표면/라벨/케이블 같은
    // 반사체보다 압도적으로 밝다. 문턱을 올리면 배경이 거의 전멸한다.
    //
    // 이 게이트의 목적은 그 자체로 LED를 찾는 것이 아니라, 아래 두 게이트를
    // 안전하게 완화할 수 있는 여유를 만드는 것이다.
    // =========================================================
    logic valid_v;

    assign valid_v = (max_val >= V_MIN_LED);

    // =========================================================
    // 4. 게이트 2 — 채도 (밝기 의존)
    //
    // 포화된 LED 코어를 죽이는 것은 절대 조건(delta >= 4)이 아니라
    // 비율 조건 (delta << 2) >= max_val 이다.
    // 예: 포화된 초록 LED가 G=63, R=57, B=52로 읽히면
    //     delta = 11 >= 4        -> 통과
    //     (11 << 2) = 44 >= 63   -> 실패
    // 따라서 V_CLIP 이상인 픽셀에는 비율 조건을 면제한다.
    // 이러면 halo가 거의 없는 아주 작은 LED도 코어만으로 검출된다.
    //
    // [원본 버그 수정] delta가 logic [5:0]이므로 (delta << 2)를 6비트 폭에서
    // 평가하면 잘린다. delta=32면 128이 되어야 하는데 6비트로 잘려 0이 되고,
    // 0 >= max_val 이 실패한다. 즉 채도가 높은 픽셀일수록(delta >= 16) 오히려
    // 탈락하는 구조였다. 8비트로 확장해 계산한다.
    // =========================================================
    logic [7:0] delta_x4;
    logic [7:0] max_val_ext;
    logic       valid_s;

    assign delta_x4    = {2'b00, delta} << 2;
    assign max_val_ext = {2'b00, max_val};

    always_comb begin
        if (max_val >= V_CLIP) begin
            // 포화된 LED 코어
            valid_s = (delta >= DELTA_MIN_CLIP);
        end else begin
            // 일반 픽셀
            valid_s = (delta_x4 >= max_val_ext) && (delta >= DELTA_MIN);
        end
    end

    // =========================================================
    // 5. 게이트 3 — 색상 (빨강 / 초록, 데드밴드 포함)
    //
    // 63 + HUE_MARGIN이 6비트를 넘칠 수 있으므로 7비트로 확장해 비교한다.
    //
    // 두 조건은 구조적으로 상호 배타적이다
    // (HUE_MARGIN >= 1 이면 R >= G+m 과 G >= R+m 이 동시에 성립 불가).
    //
    // 삼색 LED는 빨강/초록 다이가 물리적으로 붙어 있어 둘이 같이 켜지면 R ~= G인
    // 호박색이 된다. 데드밴드가 없으면 프레임마다 판정이 뒤집혀 박스 색이 깜빡인다.
    // 데드밴드에 걸린 색은 아예 판정하지 않는다. 의도된 동작이다.
    //
    // (max > color_blue) 조건은 청색/청보라 광원(네온 스트립)을 자연 탈락시킨다.
    // 단, 마젠타 쪽으로 치우친 보라(R=60 G=20 B=55)는 통과한다.
    // 이 경우는 drone_posit_size의 크기 필터(MAX_BLOB_CELLS)가 담당한다.
    // =========================================================
    logic [6:0] red_ext;
    logic [6:0] green_ext;
    logic [6:0] blue_ext;
    logic [6:0] margin_ext;
    logic [6:0] gb_tol_ext;

    assign red_ext    = {1'b0, color_red};
    assign green_ext  = {1'b0, color_green};
    assign blue_ext   = {1'b0, color_blue};
    assign margin_ext = {1'b0, HUE_MARGIN};
    assign gb_tol_ext = {1'b0, GREEN_BLUE_TOL};

    logic hue_is_red;
    logic hue_is_green;

    // 빨강은 blue 조건을 엄격하게 유지한다. 과노출되어도 R이 최댓값을 지키므로
    // 완화할 필요가 없고, 마젠타 계열 광원에 대한 방어를 약화시키지 않는다.
    assign hue_is_red   = (red_ext   >= (green_ext + margin_ext)) &&
                          (red_ext   >  blue_ext);

    // 초록의 blue 조건.
    //
    // [중요] 허용치는 포화된 코어에만 적용한다. 전역으로 적용하면 안 된다.
    //
    // 과노출된 LED 코어에서 B가 G를 살짝 넘는 것은 물리적으로 정당하다.
    // 그러나 중간 밝기의 배경 픽셀에서 B > G인 것은 LED가 아니라 그냥
    // 청록빛 표면이다. 청/보라 네온 조명 아래에서는 그런 표면이 많다.
    //
    // 이 허용치를 전역으로 적용했을 때 검출이 오히려 나빠졌다. 배경 셀이
    // 매칭되어 진짜 LED 셀과 병합되고, 합쳐진 blob이 MAX_BLOB_CELLS를
    // 넘겨 크기 필터에 폐기되면서 LED까지 같이 사라졌기 때문이다.
    // 완화에는 절벽이 있다.
    logic green_blue_ok;

    always_comb begin
        if (max_val >= V_CLIP) begin
            // 포화 코어: B가 G를 GREEN_BLUE_TOL만큼 넘어서는 것까지 허용
            green_blue_ok = ((green_ext + gb_tol_ext) >= blue_ext);
        end else begin
            // 일반 픽셀: 엄격하게 G > B를 요구
            green_blue_ok = (green_ext > blue_ext);
        end
    end

    assign hue_is_green = (green_ext >= (red_ext + margin_ext)) && green_blue_ok;

    // =========================================================
    // 6. 출력
    // =========================================================
    logic led_present;

    // "이 픽셀은 발광체다" — 조도 + 채도
    assign led_present = valid_v & valid_s;

    assign pixel_ally  = led_present & hue_is_green;  // 초록 = 정상
    assign pixel_enemy = led_present & hue_is_red;    // 빨강 = 이상

endmodule
