`timescale 1ns / 1ps

module uart_rx #(
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD_RATE = 115200
)(
    input wire clk,
    input wire rst_n,
    input wire rx,
    output reg [7:0] rx_data,
    output reg rx_valid
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
    
    // Double synchronizer for RX pin to avoid metastability
    reg rx_sync1, rx_sync2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= rx;
            rx_sync2 <= rx_sync1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            rx_valid <= 1'b0;
            rx_data <= 8'd0;
            clk_cnt <= 0;
            bit_cnt <= 0;
            shift_reg <= 8'd0;
        end else begin
            rx_valid <= 1'b0; // Default is low, pulses high for 1 clock cycle
            
            case (state)
                IDLE: begin
                    clk_cnt <= 0;
                    bit_cnt <= 0;
                    if (rx_sync2 == 1'b0) begin // Start bit detected (falling edge)
                        state <= START;
                    end
                end
                
                START: begin
                    // Wait for middle of start bit
                    if (clk_cnt == (CLK_PER_BIT / 2) - 1) begin
                        if (rx_sync2 == 1'b0) begin
                            clk_cnt <= 0;
                            state <= DATA;
                        end else begin
                            state <= IDLE; // False start
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
                
                DATA: begin
                    // Wait for middle of data bit
                    if (clk_cnt < CLK_PER_BIT - 1) begin
                        clk_cnt <= clk_cnt + 1;
                    end else begin
                        clk_cnt <= 0;
                        shift_reg[bit_cnt] <= rx_sync2;
                        if (bit_cnt < 7) begin
                            bit_cnt <= bit_cnt + 1;
                        end else begin
                            state <= STOP;
                        end
                    end
                end
                
                STOP: begin
                    // Wait for middle of stop bit
                    if (clk_cnt < CLK_PER_BIT - 1) begin
                        clk_cnt <= clk_cnt + 1;
                    end else begin
                        clk_cnt <= 0;
                        if (rx_sync2 == 1'b1) begin
                            rx_data <= shift_reg;
                            rx_valid <= 1'b1;
                        end
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end
endmodule
