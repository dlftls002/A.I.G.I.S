`timescale 1ns / 1ps

module ui_framebuffer #(
    parameter int WIDTH  = 320,
    parameter int HEIGHT = 240,
    parameter int ADDR_W = $clog2(WIDTH * HEIGHT)
) (
    input logic write_clk,
    input logic read_clk,
    input logic reset,

    output logic ready,
    output logic done,

    input logic       valid,
    input logic       target_type,  // 0: enemy, 1: friend
    input logic [8:0] box_x,
    input logic [7:0] box_y,

    input logic [9:0] x_pixel,
    input logic [9:0] y_pixel,
    input logic       de,

    output logic [1:0] bitmap_pixel
);

    localparam logic [1:0] UI_NONE = 2'b00;
    localparam logic [1:0] UI_GREEN = 2'b01;
    localparam logic [1:0] UI_RED = 2'b10;

    typedef enum logic [1:0] {
        S_IDLE,
        S_WRITE,
        S_DONE
    } state_t;

    state_t              state;

    logic   [ADDR_W-1:0] input_addr_q;
    logic   [       1:0] input_data_q;
    logic                input_in_range_q;

    logic   [       8:0] read_x;
    logic   [       7:0] read_y;
    logic   [ADDR_W-1:0] read_addr;

    logic                input_write_en;
    logic                clear_write_en;
    logic   [       1:0] bram_pixel;

    assign ready = (state == S_IDLE);
    assign done  = (state == S_DONE);

    assign read_x    = x_pixel[9:1];
    assign read_y    = y_pixel[8:1];
    assign read_addr = WIDTH * read_y + read_x;

    assign input_write_en = (state == S_WRITE) && input_in_range_q;

    // assign clear_write_en =
    //     de && !(input_write_en && (input_addr_q == read_addr));
    logic ui_clear_phase;
    assign ui_clear_phase = x_pixel[0] && y_pixel[0];
    assign clear_write_en =
    de && ui_clear_phase &&
    !(input_write_en && (input_addr_q == read_addr));

    bitmap_bram #(
        .WIDTH (WIDTH),
        .HEIGHT(HEIGHT),
        .ADDR_W(ADDR_W)
    ) U_bitmap_bram (
        .clka (write_clk),
        .wea  (input_write_en),
        .addra(input_addr_q),
        .dina (input_data_q),

        .clkb (read_clk),
        .web  (clear_write_en),
        .addrb(read_addr),
        .dinb (UI_NONE),
        .doutb(bram_pixel)
    );

    always_ff @(posedge write_clk or posedge reset) begin
        if (reset) begin
            state            <= S_IDLE;
            input_addr_q     <= '0;
            input_data_q     <= UI_NONE;
            input_in_range_q <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (valid && ready) begin
                        input_addr_q <= WIDTH * box_y + box_x;
                        input_data_q <= target_type ? UI_GREEN : UI_RED;
                        input_in_range_q <= (box_x < WIDTH) && (box_y < HEIGHT);
                        state <= S_WRITE;
                    end
                end

                S_WRITE: begin
                    state <= S_DONE;
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

    always_ff @(posedge read_clk or posedge reset) begin
        if (reset) begin
            bitmap_pixel <= UI_NONE;
        end else if (!de) begin
            bitmap_pixel <= UI_NONE;
        end else begin
            bitmap_pixel <= bram_pixel;
        end
    end

endmodule
