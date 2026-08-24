module Drone_pixel_counter #(
    parameter int WIDTH = 320,
    parameter int HEIGHT = 240,
    parameter int DIVIDE_X = 16,
    parameter int DIVIDE_Y = 12,

    // 셀당 최소 매칭 픽셀 수.
    // 그리드 한 칸이 (WIDTH/DIVIDE_X) x (HEIGHT/DIVIDE_Y) = 20 x 20 = 400픽셀이므로
    // 기존 값 50은 약 7x7 크기를 요구했다. 이는 드론 기준이며 랙 LED는 그보다 작다.
    // 조도 게이트(Drone_Classification_Color의 V_MIN_LED)가 배경을 이미 제거하므로
    // 낮은 카운트가 안전해진다.
    // 실제 적용값은 UI_Set.sv의 LED_THRESHOLD가 덮어쓴다.
    parameter int THRESHOLD = 6,

    // =========================================================
    // 프레임 간 시간적 히스테리시스 (샘플링)
    //
    // 셀 매칭 여부가 THRESHOLD 근처에서 프레임마다 뒤집히면 박스가 깜빡인다.
    // ui_framebuffer는 매 표시 프레임마다 전체를 지우고 검출기가 다시 채우는
    // 구조라, 한 프레임만 놓쳐도 박스가 사라진다.
    //
    // 셀마다 신뢰도 카운터를 두고 비대칭으로 갱신한다.
    //   매칭됨   -> CONF_UP 만큼 증가 (빠르게 붙음)
    //   안 됨    -> CONF_DOWN 만큼 감소 (천천히 떨어짐)
    //   CONF_ON 이상이면 그 셀을 검출된 것으로 취급한다.
    //
    // 기본값 기준 동작:
    //   한 프레임 잡히면 0 -> 4 이므로 즉시 켜진다 (반응 지연 없음).
    //   꾸준히 잡히면 15까지 차오르고, 이후 연속 11프레임을 놓쳐야 꺼진다.
    //   30fps에서 약 0.37초 유지된다.
    //
    // blob 병합보다 상류에서 걸러지므로 박스 좌표와 blob 크기까지 안정화되고,
    // MAX_BLOB_CELLS 크기 필터의 경계 흔들림도 함께 줄어든다.
    // =========================================================
    parameter logic [3:0] CONF_MAX  = 4'd15,
    parameter logic [3:0] CONF_UP   = 4'd4,
    parameter logic [3:0] CONF_DOWN = 4'd1,
    parameter logic [3:0] CONF_ON   = 4'd4
) (
    input logic clk,
    input logic reset,
    input logic we,
    input logic [$clog2(WIDTH*HEIGHT)-1:0] wAddr,

    input logic drone_ally,  // 1이면 아군 픽셀
    input logic drone_enemy, // 1이면 적군 픽셀

    output logic out_type,  // 1: 아군, 0: 적군
    output logic [$clog2(DIVIDE_X * DIVIDE_Y)-1:0] out_area_addr,
    output logic out_valid,
    output logic frame_done // 프레임 출력이 끝났음을 알리는 펄스
);

    localparam int DIV_WIDTH = WIDTH / DIVIDE_X;
    localparam int DIV_HEIGHT = HEIGHT / DIVIDE_Y;
    localparam int TOTAL_AREAS = DIVIDE_X * DIVIDE_Y;
    localparam int MAX_PIXELS_PER_AREA = DIV_WIDTH * DIV_HEIGHT;

    logic [$clog2(
MAX_PIXELS_PER_AREA+1
)-1:0] ally_area_counter[0:TOTAL_AREAS-1];
    logic [$clog2(
MAX_PIXELS_PER_AREA+1
)-1:0] enemy_area_counter[0:TOTAL_AREAS-1];

    // 이번 프레임의 raw 관측 결과
    logic [TOTAL_AREAS-1:0] current_ally_met;
    logic [TOTAL_AREAS-1:0] current_enemy_met;

    // 히스테리시스를 통과한 안정화 결과. 스캔은 이 값을 쓴다.
    logic [TOTAL_AREAS-1:0] stable_ally_met;
    logic [TOTAL_AREAS-1:0] stable_enemy_met;

    // 셀별 신뢰도 카운터
    logic [3:0] ally_conf [0:TOTAL_AREAS-1];
    logic [3:0] enemy_conf[0:TOTAL_AREAS-1];

    // 프레임 경계에서 적용될 다음 신뢰도 / 안정화 결과 (조합)
    logic [3:0] ally_conf_next [0:TOTAL_AREAS-1];
    logic [3:0] enemy_conf_next[0:TOTAL_AREAS-1];
    logic [TOTAL_AREAS-1:0] next_stable_ally_met;
    logic [TOTAL_AREAS-1:0] next_stable_enemy_met;

    // ---------------------------------------------------------
    // 포화 가감산.
    // CONF_MAX - CONF_UP 을 넘으면 포화시키므로 4비트 오버플로가 없다.
    // ---------------------------------------------------------
    always_comb begin
        for (int c = 0; c < TOTAL_AREAS; c++) begin
            // ---- ally ----
            if (current_ally_met[c]) begin
                if (ally_conf[c] > (CONF_MAX - CONF_UP))
                    ally_conf_next[c] = CONF_MAX;
                else
                    ally_conf_next[c] = ally_conf[c] + CONF_UP;
            end else begin
                if (ally_conf[c] > CONF_DOWN)
                    ally_conf_next[c] = ally_conf[c] - CONF_DOWN;
                else
                    ally_conf_next[c] = 4'd0;
            end

            next_stable_ally_met[c] = (ally_conf_next[c] >= CONF_ON);

            // ---- enemy ----
            if (current_enemy_met[c]) begin
                if (enemy_conf[c] > (CONF_MAX - CONF_UP))
                    enemy_conf_next[c] = CONF_MAX;
                else
                    enemy_conf_next[c] = enemy_conf[c] + CONF_UP;
            end else begin
                if (enemy_conf[c] > CONF_DOWN)
                    enemy_conf_next[c] = enemy_conf[c] - CONF_DOWN;
                else
                    enemy_conf_next[c] = 4'd0;
            end

            next_stable_enemy_met[c] = (enemy_conf_next[c] >= CONF_ON);
        end
    end

    logic [$clog2(WIDTH)-1:0] pixel_x;
    logic [$clog2(HEIGHT)-1:0] pixel_y;
    logic [$clog2(TOTAL_AREAS)-1:0] grid_idx;

    assign pixel_x = wAddr % WIDTH;
    assign pixel_y = wAddr / WIDTH;
    assign grid_idx = (pixel_y / DIV_HEIGHT) * DIVIDE_X + (pixel_x / DIV_WIDTH);

    integer i;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            current_ally_met  <= '0;
            current_enemy_met <= '0;
            stable_ally_met   <= '0;
            stable_enemy_met  <= '0;

            for (i = 0; i < TOTAL_AREAS; i = i + 1) begin
                ally_area_counter[i]  <= 0;
                enemy_area_counter[i] <= 0;
                ally_conf[i]          <= 4'd0;
                enemy_conf[i]         <= 4'd0;
            end
        end else if (we) begin
            if (wAddr == 0) begin
                // 프레임 경계: 신뢰도를 갱신하고 안정화 결과를 확정한다.
                for (i = 0; i < TOTAL_AREAS; i = i + 1) begin
                    ally_conf[i]  <= ally_conf_next[i];
                    enemy_conf[i] <= enemy_conf_next[i];
                end

                stable_ally_met   <= next_stable_ally_met;
                stable_enemy_met  <= next_stable_enemy_met;

                current_ally_met  <= '0;
                current_enemy_met <= '0;

                for (i = 0; i < TOTAL_AREAS; i = i + 1) begin
                    ally_area_counter[i]  <= 0;
                    enemy_area_counter[i] <= 0;
                end

                if (drone_ally) begin
                    ally_area_counter[grid_idx] <= 1;
                    if (1 >= THRESHOLD) current_ally_met[grid_idx] <= 1'b1;
                end
                if (drone_enemy) begin
                    enemy_area_counter[grid_idx] <= 1;
                    if (1 >= THRESHOLD) current_enemy_met[grid_idx] <= 1'b1;
                end
            end else begin
                if (drone_ally) begin
                    ally_area_counter[grid_idx] <= ally_area_counter[grid_idx] + 1;
                    if (ally_area_counter[grid_idx] + 1 >= THRESHOLD) begin
                        current_ally_met[grid_idx] <= 1'b1;
                    end
                end
                if (drone_enemy) begin
                    enemy_area_counter[grid_idx] <= enemy_area_counter[grid_idx] + 1;
                    if (enemy_area_counter[grid_idx] + 1 >= THRESHOLD) begin
                        current_enemy_met[grid_idx] <= 1'b1;
                    end
                end
            end
        end
    end
    localparam ST_IDLE = 2'b00;
    localparam ST_ALLY = 2'b01;
    localparam ST_ENEMY = 2'b10;
    logic [1:0] state;

    logic [$clog2(TOTAL_AREAS+1)-1:0] scan_idx;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state         <= ST_IDLE;
            scan_idx      <= 0;
            out_type      <= 1'b0;
            out_area_addr <= 0;
            out_valid     <= 0;
            frame_done    <= 0;
        end else begin
            case (state)
                ST_IDLE: begin
                    out_valid  <= 0;
                    scan_idx   <= 0;
                    frame_done <= 0;

                    if (we && wAddr == 0) begin
                        // 히스테리시스를 통과한 결과로 분기한다.
                        // stable_*_met은 이 엣지에서 next_stable_*_met으로
                        // 갱신되므로, 분기 판단은 조합값을 봐야 스캔 대상과
                        // 일치한다.
                        if (next_stable_ally_met != '0) begin
                            // 아군이 1개라도 탐지되었으면 ST_ALLY로 이동
                            state <= ST_ALLY;
                        end else if (next_stable_enemy_met != '0) begin
                            // 아군은 없지만 적군이 탐지되었으면 ST_ENEMY로 직행 (시간 단축)
                            state <= ST_ENEMY;
                        end else begin
                            // 둘 다 없으면 스캔을 완전히 생략하고 프레임 종료 펄스만 출력
                            state <= ST_IDLE;
                            frame_done <= 1;
                        end
                    end
                end

                ST_ALLY: begin
                    if (scan_idx < TOTAL_AREAS) begin
                        if (stable_ally_met[scan_idx]) begin
                            out_valid     <= 1;
                            out_type      <= 1'b1;
                            out_area_addr <= scan_idx[$clog2(TOTAL_AREAS)-1:0];
                        end else begin
                            out_valid <= 0;
                        end
                        scan_idx <= scan_idx + 1;
                    end else begin
                        out_valid <= 0;
                        scan_idx  <= 0;

                        // [수정된 부분 2] 아군 스캔 완료 후 적군 데이터 유무에 따라 분기
                        if (stable_enemy_met != '0) begin
                            // 적군 데이터가 존재하면 ST_ENEMY로 전이
                            state <= ST_ENEMY;
                        end else begin
                            // 적군 데이터가 없으면 스킵하고 바로 ST_IDLE로 복귀
                            state <= ST_IDLE;
                            frame_done <= 1;
                        end
                    end
                end

                ST_ENEMY: begin
                    if (scan_idx < TOTAL_AREAS) begin
                        if (stable_enemy_met[scan_idx]) begin
                            out_valid     <= 1;
                            out_type      <= 1'b0;
                            out_area_addr <= scan_idx[$clog2(TOTAL_AREAS)-1:0];
                        end else begin
                            out_valid <= 0;
                        end
                        scan_idx <= scan_idx + 1;
                    end else begin
                        out_valid <= 0;
                        scan_idx <= 0;
                        state <= ST_IDLE;
                        frame_done <= 1; // 프레임 완료 신호 1사이클 방출
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
