`timescale 1ns/1ps

// Serializes one 48-byte secure frame through the existing UART transmitter.
module secure_uart_frame_tx #(
    parameter integer CLK_FREQ  = 125_000_000,
    parameter integer BAUD_RATE = 115200
)(
    input  logic         clk,
    input  logic         rst_n,
    input  logic [383:0] packet,
    input  logic         packet_valid,
    output logic         packet_ready,
    output logic         uart_tx_out
);
    typedef enum logic [2:0] {
        IDLE, SEND, WAIT_LAST_BUSY, WAIT_LAST_DONE
    } state_t;
    state_t state;
    logic [383:0] packet_reg;
    logic [5:0]   byte_index;
    logic [7:0]   uart_data;
    logic         uart_start;
    logic         uart_busy;

    assign packet_ready = state == IDLE;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            packet_reg  <= 384'h0;
            byte_index  <= 6'd0;
            uart_data   <= 8'h00;
            uart_start  <= 1'b0;
        end else begin
            uart_start <= 1'b0;
            case (state)
                IDLE: begin
                    if (packet_valid) begin
                        packet_reg <= packet;
                        byte_index <= 6'd0;
                        state <= SEND;
                    end
                end

                SEND: begin
                    if (!uart_busy && !uart_start) begin
                        uart_data  <= packet_reg[383-(byte_index*8) -: 8];
                        uart_start <= 1'b1;
                        if (byte_index == 6'd47)
                            state <= WAIT_LAST_BUSY;
                        else
                            byte_index <= byte_index + 1'b1;
                    end
                end

                WAIT_LAST_BUSY: begin
                    if (uart_busy)
                        state <= WAIT_LAST_DONE;
                end

                WAIT_LAST_DONE: begin
                    if (!uart_busy)
                        state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    uart_tx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) u_uart_tx (
        .clk     (clk),
        .rst_n   (rst_n),
        .tx_start(uart_start),
        .tx_data (uart_data),
        .tx      (uart_tx_out),
        .tx_busy (uart_busy)
    );
endmodule

