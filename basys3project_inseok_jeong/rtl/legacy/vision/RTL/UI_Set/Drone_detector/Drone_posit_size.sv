module drone_posit_size #(
    parameter int WIDTH = 320,
    parameter int HEIGHT = 240,
    parameter int DIVIDE_X = 16,
    parameter int DIVIDE_Y = 12,
    parameter int MAX_DRONES = 8,

    // 크기 필터: 박스의 한 변이 이 칸 수를 넘으면 폐기한다.
    //
    // LED는 점광원이고 네온 스트립/모니터/비상구 표시등 같은 것은 대형 선광원 또는
    // 면광원이다. 색상 게이트는 청색계열 광원을 막아주지만 마젠타 쪽으로 치우친
    // 보라(R=60 G=20 B=55)는 빨강으로 통과한다. 색으로 구분할 수 없는 이 경우를
    // 크기로 막는다.
    //
    // 3칸 = 60 x 60 카메라픽셀. 근접 테스트 보드의 큰 LED는 통과하고
    // 프레임을 가로지르는 스트립은 탈락하는 값이다.
    parameter int MAX_BLOB_CELLS = 3
) (
    input logic clk,
    input logic reset,

    // Inputs from Drone_pixel_counter
    input logic in_valid,
    input logic in_type,
    input logic [$clog2(DIVIDE_X * DIVIDE_Y)-1:0] in_area_addr,
    input logic in_frame_done,

    // Final outputs
    output logic [$clog2(WIDTH)-1:0] center_x,
    output logic [$clog2(HEIGHT)-1:0] center_y,
    output logic [$clog2(WIDTH)-1:0] target_width,
    output logic [$clog2(HEIGHT)-1:0] target_height,
    output logic target_type,
    output logic target_valid,
    output logic frame_done
);
    localparam int TOTAL_AREAS = DIVIDE_X * DIVIDE_Y;
    localparam int DIV_WIDTH = WIDTH / DIVIDE_X;
    localparam int DIV_HEIGHT = HEIGHT / DIVIDE_Y;
    localparam int FIFO_DATA_WIDTH = 1 + 1 + $clog2(
        TOTAL_AREAS
    );  // {is_eof, type, addr}

    logic fifo_wr_en;
    logic [FIFO_DATA_WIDTH-1:0] fifo_wr_data;
    logic fifo_full;
    logic fifo_rd_en;
    logic [FIFO_DATA_WIDTH-1:0] fifo_rd_data;
    logic fifo_empty;

    assign fifo_wr_en = in_valid | in_frame_done;

    // is_eof 비트를 최상단에 추가. frame_done일 때 1이 됨.
    assign fifo_wr_data = in_frame_done ? {1'b1, {(FIFO_DATA_WIDTH-1){1'b0}}} : {1'b0, in_type, in_area_addr};

    pxc_sync_fifo #(
        .DATA_WIDTH(FIFO_DATA_WIDTH),
        .DEPTH(64)
    ) u_fifo (
        .clk(clk),
        .rst(reset),
        .wr_en(fifo_wr_en),
        .wr_data(fifo_wr_data),
        .full(fifo_full),
        .rd_en(fifo_rd_en),
        .rd_data(fifo_rd_data),
        .empty(fifo_empty)
    );

    // Active Drones Tracking Arrays
    logic is_active[0:MAX_DRONES-1];
    logic signed [7:0] box_min_x[0:MAX_DRONES-1];
    logic signed [7:0] box_max_x[0:MAX_DRONES-1];
    logic signed [7:0] box_min_y[0:MAX_DRONES-1];
    logic signed [7:0] box_max_y[0:MAX_DRONES-1];
    logic box_type[0:MAX_DRONES-1];

    localparam ST_IDLE = 2'd0;
    localparam ST_CALC = 2'd1;
    localparam ST_FLUSH = 2'd2;
    logic [1:0] state;

    logic [FIFO_DATA_WIDTH-1:0] current_data;
    logic is_eof;
    logic pop_type;
    logic [$clog2(TOTAL_AREAS)-1:0] pop_addr;
    logic signed [7:0] pop_x;
    logic signed [7:0] pop_y;

    assign is_eof = current_data[FIFO_DATA_WIDTH-1];
    assign pop_type = current_data[FIFO_DATA_WIDTH-2];
    assign pop_addr = current_data[FIFO_DATA_WIDTH-3:0];

    assign pop_x = pop_addr % DIVIDE_X;
    assign pop_y = pop_addr / DIVIDE_X;

    logic [MAX_DRONES-1:0] match_mask;
    logic [MAX_DRONES-1:0] empty_mask;

    // 병합 가능 여부 판단 (인접 여부 확인)
    always_comb begin
        for (int j = 0; j < MAX_DRONES; j++) begin
            match_mask[j] = is_active[j] && (pop_type == box_type[j]) &&
                            (pop_x >= box_min_x[j] - 1 && pop_x <= box_max_x[j] + 1) &&
                            (pop_y >= box_min_y[j] - 1 && pop_y <= box_max_y[j] + 1);
            empty_mask[j] = !is_active[j];
        end
    end

    logic match_found;
    logic [$clog2(MAX_DRONES)-1:0] match_idx;

    always_comb begin
        match_found = 0;
        match_idx   = 0;
        for (int j = MAX_DRONES - 1; j >= 0; j--) begin
            if (match_mask[j]) begin
                match_found = 1;
                match_idx   = j[$clog2(MAX_DRONES)-1:0];
            end
        end
    end

    logic empty_found;
    logic [$clog2(MAX_DRONES)-1:0] empty_idx;

    always_comb begin
        empty_found = 0;
        empty_idx   = 0;
        for (int j = MAX_DRONES - 1; j >= 0; j--) begin
            if (empty_mask[j]) begin
                empty_found = 1;
                empty_idx   = j[$clog2(MAX_DRONES)-1:0];
            end
        end
    end

    logic [$clog2(MAX_DRONES+1)-1:0] flush_idx;

    // ---------------------------------------------------------
    // 크기 필터
    // flush 중인 박스의 변 길이(그리드 칸 단위)가 MAX_BLOB_CELLS 이하인지 판정한다.
    // box_min/max는 signed [7:0]이고 항상 0 이상이므로 부호 문제는 없다.
    // ---------------------------------------------------------
    logic signed [8:0] flush_w_cells;
    logic signed [8:0] flush_h_cells;
    logic              flush_size_ok;
    logic [$clog2(MAX_DRONES)-1:0] flush_sel;

    assign flush_sel = flush_idx[$clog2(MAX_DRONES)-1:0];

    assign flush_w_cells = box_max_x[flush_sel] - box_min_x[flush_sel] + 9'sd1;
    assign flush_h_cells = box_max_y[flush_sel] - box_min_y[flush_sel] + 9'sd1;

    assign flush_size_ok = (flush_w_cells <= MAX_BLOB_CELLS) &&
                           (flush_h_cells <= MAX_BLOB_CELLS);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= ST_IDLE;
            fifo_rd_en <= 0;
            target_valid <= 0;
            center_x <= 0;
            center_y <= 0;
            target_width <= 0;
            target_height <= 0;
            target_type <= 0;
            frame_done <= 0;
            flush_idx <= 0;

            for (int k = 0; k < MAX_DRONES; k++) begin
                is_active[k] <= 0;
            end
        end else begin
            case (state)
                ST_IDLE: begin
                    frame_done <= 0;
                    target_valid <= 0;
                    if (!fifo_empty) begin
                        fifo_rd_en <= 1;  // 1사이클만 Read Enable
                        current_data <= fifo_rd_data; // FWFT가 아니더라도 0->1 변환 전 현재값을 캡처 (Read Next 구현)
                        state <= ST_CALC;
                    end else begin
                        fifo_rd_en <= 0;
                    end
                end

                ST_CALC: begin
                    fifo_rd_en <= 0;

                    if (is_eof) begin
                        // 프레임 종료: 수집된 모든 박스를 밖으로 밀어냄
                        state <= ST_FLUSH;
                        flush_idx <= 0;
                    end else begin
                        if (match_found) begin
                            if (pop_x < box_min_x[match_idx])
                                box_min_x[match_idx] <= pop_x;
                            if (pop_x > box_max_x[match_idx])
                                box_max_x[match_idx] <= pop_x;
                            if (pop_y < box_min_y[match_idx])
                                box_min_y[match_idx] <= pop_y;
                            if (pop_y > box_max_y[match_idx])
                                box_max_y[match_idx] <= pop_y;
                        end else if (empty_found) begin
                            // 새로운 박스 할당
                            is_active[empty_idx] <= 1;
                            box_min_x[empty_idx] <= pop_x;
                            box_max_x[empty_idx] <= pop_x;
                            box_min_y[empty_idx] <= pop_y;
                            box_max_y[empty_idx] <= pop_y;
                            box_type[empty_idx]  <= pop_type;
                        end
                        state <= ST_IDLE;
                    end
                end

                ST_FLUSH: begin
                    if (flush_idx < MAX_DRONES) begin
                        // 크기 필터: LED는 점광원이므로 큰 박스는 광원 오브젝트
                        // (네온 스트립, 모니터 등)로 보고 폐기한다.
                        if (is_active[flush_idx] && flush_size_ok) begin
                            target_valid <= 1;
                            target_type <= box_type[flush_idx];
                            center_x <= (($unsigned(
                                box_min_x[flush_idx]
                            ) + $unsigned(
                                box_max_x[flush_idx]
                            )) * DIV_WIDTH) / 2 + (DIV_WIDTH / 2);
                            center_y <= (($unsigned(
                                box_min_y[flush_idx]
                            ) + $unsigned(
                                box_max_y[flush_idx]
                            )) * DIV_HEIGHT) / 2 + (DIV_HEIGHT / 2);
                            target_width <= ($unsigned(
                                box_max_x[flush_idx]
                            ) - $unsigned(
                                box_min_x[flush_idx]
                            ) + 1) * DIV_WIDTH;
                            target_height <= ($unsigned(
                                box_max_y[flush_idx]
                            ) - $unsigned(
                                box_min_y[flush_idx]
                            ) + 1) * DIV_HEIGHT;
                        end else begin
                            target_valid <= 0;
                        end

                        // 크기 필터로 폐기된 박스도 반드시 비워야 한다.
                        // 그러지 않으면 stale 박스가 다음 프레임까지 남아
                        // 새 검출과 병합된다.
                        is_active[flush_idx] <= 0;

                        flush_idx <= flush_idx + 1;
                    end else begin
                        target_valid <= 1;
                        state <= ST_IDLE;
                        frame_done <= 1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule