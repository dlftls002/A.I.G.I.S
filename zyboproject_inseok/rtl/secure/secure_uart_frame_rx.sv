`timescale 1ns/1ps

// UART byte stream to a fixed 48-byte secure frame. Searches for A5 5A so a
// dropped/corrupt byte does not permanently destroy framing.
module secure_uart_frame_rx (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [7:0]   byte_data,
    input  logic         byte_valid,
    output logic [383:0] packet,
    output logic         packet_valid,
    input  logic         packet_ready
);
    typedef enum logic [1:0] {WAIT_A5, WAIT_5A, COLLECT, HOLD} state_t;
    state_t state;
    logic [5:0] byte_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= WAIT_A5;
            byte_count   <= 6'd0;
            packet       <= 384'h0;
            packet_valid <= 1'b0;
        end else begin
            case (state)
                WAIT_A5: begin
                    packet_valid <= 1'b0;
                    if (byte_valid && byte_data == 8'hA5) begin
                        packet[383:376] <= 8'hA5;
                        state <= WAIT_5A;
                    end
                end

                WAIT_5A: begin
                    if (byte_valid) begin
                        if (byte_data == 8'h5A) begin
                            packet[375:368] <= 8'h5A;
                            byte_count <= 6'd2;
                            state <= COLLECT;
                        end else if (byte_data == 8'hA5) begin
                            packet[383:376] <= 8'hA5;
                        end else begin
                            state <= WAIT_A5;
                        end
                    end
                end

                COLLECT: begin
                    if (byte_valid) begin
                        packet[383-(byte_count*8) -: 8] <= byte_data;
                        if (byte_count == 6'd47) begin
                            packet_valid <= 1'b1;
                            state <= HOLD;
                        end else begin
                            byte_count <= byte_count + 1'b1;
                        end
                    end
                end

                HOLD: begin
                    if (packet_valid && packet_ready) begin
                        packet_valid <= 1'b0;
                        state <= WAIT_A5;
                    end
                end

                default: state <= WAIT_A5;
            endcase
        end
    end
endmodule

