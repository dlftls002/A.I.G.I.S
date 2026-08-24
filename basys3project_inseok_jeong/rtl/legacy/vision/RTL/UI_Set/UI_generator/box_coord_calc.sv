`timescale 1ns / 1ps

module box_coord_calc #(
    parameter int IMG_W = 320,
    parameter int IMG_H = 240
) (
    input  logic clk,
    input  logic reset,

    // from detector_input_fifo
    input  logic       in_valid,
    output logic       in_ready,

    input  logic [8:0] in_cx,     // center x
    input  logic [7:0] in_cy,     // center y
    input  logic [8:0] in_w,      // box width
    input  logic [7:0] in_h,      // box height
    input  logic       in_type,   // 0: enemy, 1: friend

    // to instruction generator
    output logic       out_valid,
    input  logic       out_ready,

    output logic [8:0] out_x0,    // left
    output logic [7:0] out_y0,    // top
    output logic [8:0] out_x1,    // right
    output logic [7:0] out_y1,    // bottom
    output logic       out_type   // 0: enemy, 1: friend
);

    // 계산 결과 보관하는 출력 레지스터
    logic valid_reg;

    logic [8:0] x0_reg;
    logic [7:0] y0_reg;
    logic [8:0] x1_reg;
    logic [7:0] y1_reg;
    logic       type_reg;

    assign out_valid = valid_reg;

    assign out_x0   = x0_reg;
    assign out_y0   = y0_reg;
    assign out_x1   = x1_reg;
    assign out_y1   = y1_reg;
    assign out_type = type_reg;

    // output register가 비어 있거나,
    // 다음 모듈이 현재 데이터를 받아갈 수 있으면 새 입력을 받을 수 있음
    assign in_ready = !valid_reg || out_ready;

    // 계산용 signed 변수 (음수 값 처리)
    logic signed [10:0] x0_calc;
    logic signed [10:0] y0_calc;
    logic signed [10:0] x1_calc;
    logic signed [10:0] y1_calc;

    logic [8:0] w_eff;
    logic [7:0] h_eff;

    always_comb begin
        // width/height가 혹시 0으로 들어오면 최소 1로 보정
        w_eff = (in_w == 9'd0) ? 9'd1 : in_w;
        h_eff = (in_h == 8'd0) ? 8'd1 : in_h;

        // center 좌표 기준으로 왼쪽 위 좌표 계산
        x0_calc = $signed({1'b0, in_cx}) - $signed({1'b0, (w_eff >> 1)});
        y0_calc = $signed({1'b0, in_cy}) - $signed({1'b0, (h_eff >> 1)});

        // x1/y1은 x0/y0 + width/height - 1
        x1_calc = x0_calc + $signed({1'b0, w_eff}) - 1;
        y1_calc = y0_calc + $signed({1'b0, h_eff}) - 1;
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            valid_reg <= 1'b0;

            x0_reg   <= 9'd0;
            y0_reg   <= 8'd0;
            x1_reg   <= 9'd0;
            y1_reg   <= 8'd0;
            type_reg <= 1'b0;
        end else begin
            // 출력 데이터 전달되면 valid = 0
            if (out_ready) begin
                valid_reg <= 1'b0;
            end

            // 새 입력 받을 수 있을 때만 계산 결과 저장
            if (in_valid && in_ready) begin
                valid_reg <= 1'b1;

                // x0 clipping
                if (x0_calc < 0)                // 박스가 화면 왼쪽으로 넘어가 음수인 경우
                    x0_reg <= 9'd0;
                else if (x0_calc > IMG_W - 1)   // 화면 오른쪽으로 넘어간 경우
                    x0_reg <= IMG_W - 1;
                else                            // 정상 범위인 경우
                    x0_reg <= x0_calc[8:0];


                // y0 clipping
                if (y0_calc < 0)
                    y0_reg <= 8'd0;
                else if (y0_calc > IMG_H - 1)
                    y0_reg <= IMG_H - 1;
                else
                    y0_reg <= y0_calc[7:0];


                // x1 clipping
                if (x1_calc < 0)
                    x1_reg <= 9'd0;
                else if (x1_calc > IMG_W - 1)
                    x1_reg <= IMG_W - 1;
                else
                    x1_reg <= x1_calc[8:0];

                // y1 clipping
                if (y1_calc < 0)
                    y1_reg <= 8'd0;
                else if (y1_calc > IMG_H - 1)
                    y1_reg <= IMG_H - 1;
                else
                    y1_reg <= y1_calc[7:0];

                type_reg <= in_type;
            end
        end
    end

endmodule