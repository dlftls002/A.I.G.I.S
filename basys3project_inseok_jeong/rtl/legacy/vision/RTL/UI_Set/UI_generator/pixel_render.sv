`timescale 1ns / 1ps

module pixel_render #(
    parameter int IMG_W = 320,
    parameter int IMG_H = 240,
    parameter int FIFO_DEPTH = 32
) (
    input  logic clk,
    input  logic reset,

    // from instruction_generator
    input  logic       instr_valid,
    output logic       instr_ready,

    input  logic [1:0] instr_op,
    input  logic [8:0] instr_x_start,
    input  logic [7:0] instr_y_start,
    input  logic [8:0] instr_length,
    input  logic [3:0] instr_dash_on,
    input  logic [3:0] instr_dash_off,
    input  logic       instr_type,      // 0: enemy, 1: friend

    // to ui_framebuffer
    output logic       pix_valid,
    input  logic       pix_ready,

    output logic [8:0] pix_x,
    output logic [7:0] pix_y,
    output logic       pix_type         // 0: enemy, 1: friend
);

    // ================================
    // Instruction op code
    // 텍스트 렌더링(ENEMY/WARNING)은 제거했고 선만 그린다.
    // ================================
    localparam logic [1:0] OP_HLINE = 2'd0;
    localparam logic [1:0] OP_VLINE = 2'd1;

    localparam int INSTR_W = 37;

    // ================================
    // Instruction FIFO
    // ================================
    logic [INSTR_W-1:0] instr_fifo_wdata;
    logic [INSTR_W-1:0] instr_fifo_rdata;

    logic instr_fifo_wr_en;
    logic instr_fifo_rd_en;
    logic instr_fifo_full;
    logic instr_fifo_empty;

    assign instr_fifo_wdata = {
        instr_op,          // 2bit
        instr_x_start,     // 9bit
        instr_y_start,     // 8bit
        instr_length,      // 9bit
        instr_dash_on,     // 4bit
        instr_dash_off,    // 4bit
        instr_type         // 1bit
    };

    assign instr_ready = !instr_fifo_full;
    assign instr_fifo_wr_en = instr_valid && instr_ready;

    sync_fifo #(
        .DATA_WIDTH(INSTR_W),
        .DEPTH     (FIFO_DEPTH)
    ) U_INSTR_FIFO (
        .clk    (clk),
        .reset  (reset),
        .wr_en  (instr_fifo_wr_en),
        .wr_data(instr_fifo_wdata),
        .rd_en  (instr_fifo_rd_en),
        .rd_data(instr_fifo_rdata),
        .full   (instr_fifo_full),
        .empty  (instr_fifo_empty)
    );

    // ================================
    // FIFO output unpacking
    // ================================
    logic [1:0] fifo_op;
    logic [8:0] fifo_x_start;
    logic [7:0] fifo_y_start;
    logic [8:0] fifo_length;
    logic [3:0] fifo_dash_on;
    logic [3:0] fifo_dash_off;
    logic       fifo_type;

    assign {
        fifo_op,
        fifo_x_start,
        fifo_y_start,
        fifo_length,
        fifo_dash_on,
        fifo_dash_off,
        fifo_type
    } = instr_fifo_rdata;

    // ================================
    // Current instruction registers
    // ================================
    logic [1:0] op_reg;
    logic [8:0] x_start_reg;
    logic [7:0] y_start_reg;
    logic [8:0] length_reg;
    logic [3:0] dash_on_reg;
    logic [3:0] dash_off_reg;
    logic       type_reg;

    // ================================
    // Renderer FSM
    // ================================
    typedef enum logic [1:0] {
        S_IDLE,
        S_LINE
    } state_t;

    state_t state;

    // ================================
    // Line rendering counters
    // ================================
    logic [8:0] line_idx;
    logic [3:0] dash_count;
    logic       dash_draw;

    logic [9:0] line_x_calc;
    logic [8:0] line_y_calc;

    logic       line_in_bounds;
    logic       line_should_draw;
    logic       line_step;

    always_comb begin
        if (op_reg == OP_HLINE) begin
            line_x_calc = {1'b0, x_start_reg} + {1'b0, line_idx};
            line_y_calc = {1'b0, y_start_reg};
        end else begin
            line_x_calc = {1'b0, x_start_reg};
            line_y_calc = {1'b0, y_start_reg} + line_idx;
        end

        line_in_bounds =
            (line_x_calc < IMG_W) &&
            (line_y_calc < IMG_H);

        if (dash_off_reg == 4'd0) begin
            line_should_draw = 1'b1;
        end else begin
            line_should_draw = dash_draw;
        end

        line_step =
            (state == S_LINE) &&
            (
                !line_should_draw ||
                !line_in_bounds  ||
                (pix_valid && pix_ready)
            );
    end

    // ================================
    // Pixel output mux
    // ================================
    always_comb begin
        pix_valid = 1'b0;
        pix_x     = 9'd0;
        pix_y     = 8'd0;
        pix_type  = type_reg;

        case (state)
            S_LINE: begin
                pix_valid = line_should_draw && line_in_bounds;
                pix_x     = line_x_calc[8:0];
                pix_y     = line_y_calc[7:0];
                pix_type  = type_reg;
            end

            default: begin
                pix_valid = 1'b0;
                pix_x     = 9'd0;
                pix_y     = 8'd0;
                pix_type  = type_reg;
            end
        endcase
    end

    // ================================
    // FIFO read control
    // ================================
    assign instr_fifo_rd_en = (state == S_IDLE) && !instr_fifo_empty;

    // ================================
    // Sequential logic
    // ================================
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= S_IDLE;

            op_reg        <= OP_HLINE;
            x_start_reg   <= 9'd0;
            y_start_reg   <= 8'd0;
            length_reg    <= 9'd1;
            dash_on_reg   <= 4'd8;
            dash_off_reg  <= 4'd8;
            type_reg      <= 1'b0;

            line_idx      <= 9'd0;
            dash_count    <= 4'd0;
            dash_draw     <= 1'b1;
        end else begin
            case (state)
                S_IDLE: begin
                    line_idx      <= 9'd0;
                    dash_count    <= 4'd0;
                    dash_draw     <= 1'b1;

                    if (!instr_fifo_empty) begin
                        op_reg        <= fifo_op;
                        x_start_reg   <= fifo_x_start;
                        y_start_reg   <= fifo_y_start;
                        length_reg    <= (fifo_length == 9'd0) ? 9'd1 : fifo_length;
                        dash_on_reg   <= fifo_dash_on;
                        dash_off_reg  <= fifo_dash_off;
                        type_reg      <= fifo_type;

                        state <= S_LINE;
                    end
                end

                S_LINE: begin
                    if (line_step) begin
                        if (line_idx == length_reg - 9'd1) begin
                            state <= S_IDLE;
                        end else begin
                            line_idx <= line_idx + 9'd1;

                            if (dash_off_reg == 4'd0) begin
                                dash_draw  <= 1'b1;
                                dash_count <= 4'd0;
                            end else begin
                                if (dash_draw) begin
                                    if (dash_count == dash_on_reg - 4'd1) begin
                                        dash_count <= 4'd0;
                                        dash_draw  <= 1'b0;
                                    end else begin
                                        dash_count <= dash_count + 4'd1;
                                    end
                                end else begin
                                    if (dash_count == dash_off_reg - 4'd1) begin
                                        dash_count <= 4'd0;
                                        dash_draw  <= 1'b1;
                                    end else begin
                                        dash_count <= dash_count + 4'd1;
                                    end
                                end
                            end
                        end
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
