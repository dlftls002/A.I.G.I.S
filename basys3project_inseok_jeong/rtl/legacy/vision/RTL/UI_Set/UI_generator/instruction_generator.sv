`timescale 1ns / 1ps

module instruction_generator (
    input logic clk,
    input logic reset,

    // from box_coord_calc
    input  logic box_valid,
    output logic box_ready,

    input logic [8:0] box_x0,   // left
    input logic [7:0] box_y0,   // top
    input logic [8:0] box_x1,   // right
    input logic [7:0] box_y1,   // bottom
    input logic       box_type, // 0: enemy, 1: friend

    // to instruction FIFO
    output logic instr_valid,
    input  logic instr_ready,

    output logic [1:0] instr_op,        // operation: 가로선, 세로선
    output logic [8:0] instr_x_start,
    output logic [7:0] instr_y_start,
    output logic [8:0] instr_length,
    output logic [3:0] instr_dash_on,
    output logic [3:0] instr_dash_off,
    output logic       instr_type       // 0: enemy, 1: friend
);

    // Instruction op code
    // 텍스트(ENEMY/WARNING) op는 제거하고 테두리 선만 생성한다.
    localparam logic [1:0] OP_HLINE = 2'd0;
    localparam logic [1:0] OP_VLINE = 2'd1;

    // Dash pattern
    localparam logic [3:0] DASH_ON = 4'd8;
    localparam logic [3:0] DASH_OFF = 4'd8;

    // Border thickness: 3 pixels
    // line_layer = 0, 1, 2 순서로 같은 테두리 명령을 3번 생성
    localparam logic [1:0] LAST_LINE_LAYER = 2'd2;

    // UI framebuffer size: 320 x 240
    // 바깥쪽 확장 시 화면 범위를 넘지 않도록 saturation 처리
    localparam logic [8:0] MAX_X = 9'd319;
    localparam logic [7:0] MAX_Y = 8'd239;

    // FSM state
    typedef enum logic [2:0] {
        S_IDLE,
        S_TOP,
        S_BOTTOM,
        S_LEFT,
        S_RIGHT
    } state_t;

    state_t       state;


    // Saved box information
    logic   [8:0] x0_reg;
    logic   [7:0] y0_reg;
    logic   [8:0] x1_reg;
    logic   [7:0] y1_reg;
    logic         type_reg;

    // 현재 테두리의 몇 번째 줄을 생성하는지 표시
    // 0: 첫 번째 줄, 1: 두 번째 줄, 2: 세 번째 줄
    logic   [1:0] line_layer;

    logic   [8:0] box_width;
    logic   [8:0] box_height;

    // width = x1 - x0 + 1
    assign box_width = (x1_reg >= x0_reg) ? (x1_reg - x0_reg + 9'd1) : 9'd1;

    // height = y1 - y0 + 1
    assign box_height =
        (y1_reg >= y0_reg)
        ? ({1'b0, y1_reg} - {1'b0, y0_reg} + 9'd1)
        : 9'd1;

    // IDLE일 때만 새로운 box 입력 가능
    assign box_ready = (state == S_IDLE);

    // IDLE이 아니면 instruction 출력 중
    assign instr_valid = (state != S_IDLE);


    // Output instruction logic
    always_comb begin
        // default
        instr_op       = OP_HLINE;
        instr_x_start  = 9'd0;
        instr_y_start  = 8'd0;
        instr_length   = 9'd1;
        instr_dash_on  = DASH_ON;
        instr_dash_off = DASH_OFF;
        instr_type     = type_reg;

        case (state)

            // 위쪽 점선 테두리: y0, y0-1, y0-2
            S_TOP: begin
                instr_op       = OP_HLINE;
                instr_x_start  = x0_reg;

                // y가 0보다 작아지는 underflow 방지
                if (y0_reg >= {{6{1'b0}}, line_layer})
                    instr_y_start = y0_reg - {{6{1'b0}}, line_layer};
                else
                    instr_y_start = 8'd0;
                instr_length   = box_width;
                instr_dash_on  = DASH_ON;
                instr_dash_off = DASH_OFF;
                instr_type     = type_reg;
            end

            // 아래쪽 점선 테두리: y1, y1+1, y1+2
            S_BOTTOM: begin
                instr_op       = OP_HLINE;
                instr_x_start  = x0_reg;

                // y가 화면 아래쪽 범위를 넘지 않도록 제한
                if (({1'b0, y1_reg} + {7'd0, line_layer}) <= {1'b0, MAX_Y})
                    instr_y_start = y1_reg + {{6{1'b0}}, line_layer};
                else
                    instr_y_start = MAX_Y;
                instr_length   = box_width;
                instr_dash_on  = DASH_ON;
                instr_dash_off = DASH_OFF;
                instr_type     = type_reg;
            end

            // 왼쪽 점선 테두리: x0, x0-1, x0-2
            S_LEFT: begin
                instr_op       = OP_VLINE;

                // x가 0보다 작아지는 underflow 방지
                if (x0_reg >= {{7{1'b0}}, line_layer})
                    instr_x_start = x0_reg - {{7{1'b0}}, line_layer};
                else
                    instr_x_start = 9'd0;

                instr_y_start  = y0_reg;
                instr_length   = box_height;
                instr_dash_on  = DASH_ON;
                instr_dash_off = DASH_OFF;
                instr_type     = type_reg;
            end

            // 오른쪽 점선 테두리: x1, x1+1, x1+2
            S_RIGHT: begin
                instr_op       = OP_VLINE;

                // x가 화면 오른쪽 범위를 넘지 않도록 제한
                if (({1'b0, x1_reg} + {8'd0, line_layer}) <= {1'b0, MAX_X})
                    instr_x_start = x1_reg + {{7{1'b0}}, line_layer};
                else
                    instr_x_start = MAX_X;

                instr_y_start  = y0_reg;
                instr_length   = box_height;
                instr_dash_on  = DASH_ON;
                instr_dash_off = DASH_OFF;
                instr_type     = type_reg;
            end

            default: begin
                instr_op       = OP_HLINE;
                instr_x_start  = 9'd0;
                instr_y_start  = 8'd0;
                instr_length   = 9'd1;
                instr_dash_on  = DASH_ON;
                instr_dash_off = DASH_OFF;
                instr_type     = type_reg;
            end
        endcase
    end


    // FSM sequential logic
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state      <= S_IDLE;
            x0_reg     <= 9'd0;
            y0_reg     <= 8'd0;
            x1_reg     <= 9'd0;
            y1_reg     <= 8'd0;
            type_reg   <= 1'b0;
            line_layer <= 2'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    // 새 박스의 첫 번째 선은 항상 layer 0부터 시작
                    line_layer <= 2'd0;

                    if (box_valid && box_ready) begin
                        x0_reg   <= box_x0;
                        y0_reg   <= box_y0;
                        x1_reg   <= box_x1;
                        y1_reg   <= box_y1;
                        type_reg <= box_type;
                        state    <= S_TOP;
                    end
                end

                // 같은 TOP 상태에서 y0, y0-1, y0-2를 순서대로 출력
                S_TOP: begin
                    if (instr_valid && instr_ready) begin
                        if (line_layer == LAST_LINE_LAYER) begin
                            line_layer <= 2'd0;
                            state      <= S_BOTTOM;
                        end else begin
                            line_layer <= line_layer + 2'd1;
                        end
                    end
                end

                // 같은 BOTTOM 상태에서 y1, y1+1, y1+2를 순서대로 출력
                S_BOTTOM: begin
                    if (instr_valid && instr_ready) begin
                        if (line_layer == LAST_LINE_LAYER) begin
                            line_layer <= 2'd0;
                            state      <= S_LEFT;
                        end else begin
                            line_layer <= line_layer + 2'd1;
                        end
                    end
                end

                // 같은 LEFT 상태에서 x0, x0-1, x0-2를 순서대로 출력
                S_LEFT: begin
                    if (instr_valid && instr_ready) begin
                        if (line_layer == LAST_LINE_LAYER) begin
                            line_layer <= 2'd0;
                            state      <= S_RIGHT;
                        end else begin
                            line_layer <= line_layer + 2'd1;
                        end
                    end
                end

                // 같은 RIGHT 상태에서 x1, x1+1, x1+2를 순서대로 출력
                S_RIGHT: begin
                    if (instr_valid && instr_ready) begin
                        if (line_layer == LAST_LINE_LAYER) begin
                            // 텍스트 단계 없이 박스 하나 처리 완료
                            line_layer <= 2'd0;
                            state      <= S_IDLE;
                        end else begin
                            line_layer <= line_layer + 2'd1;
                        end
                    end
                end

                default: begin
                    state      <= S_IDLE;
                    line_layer <= 2'd0;
                end
            endcase
        end
    end

endmodule
