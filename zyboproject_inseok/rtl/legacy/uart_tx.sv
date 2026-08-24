`timescale 1ns / 1ps

module uart_tx #(
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD_RATE = 115200
)(
    input wire clk,
    input wire rst_n,
    input wire tx_start,
    input wire [7:0] tx_data,
    output reg tx,
    output reg tx_busy
);

    localparam CLK_PER_BIT = CLK_FREQ / BAUD_RATE;
    
    typedef enum reg [1:0] {
        IDLE  = 2'b00,
        START = 2'b01,
        DATA  = 2'b10,
        STOP  = 2'b11
    } state_t;
    
    state_t state;
    
    integer clk_cnt;
    reg [2:0] bit_cnt;
    reg [7:0] shift_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            tx <= 1'b1;
            tx_busy <= 1'b0;
            clk_cnt <= 0;
            bit_cnt <= 0;
            shift_reg <= 8'd0;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1'b1;
                    clk_cnt <= 0;
                    bit_cnt <= 0;
                    if (tx_start) begin
                        tx_busy <= 1'b1;
                        shift_reg <= tx_data;
                        state <= START;
                    end else begin
                        tx_busy <= 1'b0;
                    end
                end
                
                START: begin
                    tx <= 1'b0; // Start bit
                    if (clk_cnt < CLK_PER_BIT - 1) begin
                        clk_cnt <= clk_cnt + 1;
                    end else begin
                        clk_cnt <= 0;
                        state <= DATA;
                    end
                end
                
                DATA: begin
                    tx <= shift_reg[bit_cnt];
                    if (clk_cnt < CLK_PER_BIT - 1) begin
                        clk_cnt <= clk_cnt + 1;
                    end else begin
                        clk_cnt <= 0;
                        if (bit_cnt < 7) begin
                            bit_cnt <= bit_cnt + 1;
                        end else begin
                            state <= STOP;
                        end
                    end
                end
                
                STOP: begin
                    tx <= 1'b1; // Stop bit
                    if (clk_cnt < CLK_PER_BIT - 1) begin
                        clk_cnt <= clk_cnt + 1;
                    end else begin
                        clk_cnt <= 0;
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end
endmodule
