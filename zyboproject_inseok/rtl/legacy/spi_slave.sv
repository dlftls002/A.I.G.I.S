`timescale 1ns/1ps
// Generic SPI slave with CDC synchronizers on sclk/cs_n/mosi.
// MSB-first. MISO is best-effort (tx_data, defaults unused).
module spi_slave #(
    parameter int DATA_WIDTH = 128,
    parameter bit CPOL       = 1'b0,
    parameter bit CPHA       = 1'b0
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  sclk,
    input  logic                  cs_n,
    input  logic                  mosi,
    output logic                  miso,
    output logic [DATA_WIDTH-1:0] rx_data,
    output logic                  rx_valid,
    input  logic [DATA_WIDTH-1:0] tx_data
);
    // --- 2-FF (+1 for edge detect) synchronizers ---
    logic sclk_s0, sclk_s1, sclk_s2;
    logic mosi_s0, mosi_s1;
    logic cs_s0,   cs_s1,   cs_s2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_s0 <= CPOL; sclk_s1 <= CPOL; sclk_s2 <= CPOL;
            mosi_s0 <= 1'b0; mosi_s1 <= 1'b0;
            cs_s0   <= 1'b1; cs_s1   <= 1'b1; cs_s2   <= 1'b1;
        end else begin
            sclk_s0 <= sclk;    sclk_s1 <= sclk_s0; sclk_s2 <= sclk_s1;
            mosi_s0 <= mosi;    mosi_s1 <= mosi_s0;
            cs_s0   <= cs_n;    cs_s1   <= cs_s0;   cs_s2   <= cs_s1;
        end
    end

    wire sclk_rise = sclk_s1 & ~sclk_s2;
    wire sclk_fall = ~sclk_s1 & sclk_s2;
    wire cs_active = ~cs_s1;
    wire cs_fall   = ~cs_s1 & cs_s2;   // CS just asserted

    wire leading     = (CPOL == 1'b0) ? sclk_rise : sclk_fall;
    wire trailing    = (CPOL == 1'b0) ? sclk_fall : sclk_rise;
    wire sample_edge = (CPHA == 1'b0) ? leading : trailing;
    wire shift_edge  = (CPHA == 1'b0) ? trailing : leading;

    logic [DATA_WIDTH-1:0] rx_shift;
    logic [DATA_WIDTH-1:0] tx_shift;
    wire  [DATA_WIDTH-1:0] tx_shift_next = tx_shift << 1;
    integer                bit_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_shift <= '0;
            tx_shift <= '0;
            bit_cnt  <= 0;
            rx_data  <= '0;
            rx_valid <= 1'b0;
            miso     <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            if (cs_fall) begin
                bit_cnt  <= 0;
                rx_shift <= '0;
                tx_shift <= tx_data;
                if (CPHA == 1'b0)
                    miso <= tx_data[DATA_WIDTH-1];
            end else if (cs_active) begin
                if (sample_edge) begin
                    rx_shift <= (rx_shift << 1) | mosi_s1;
                    if (bit_cnt == DATA_WIDTH-1) begin
                        rx_data  <= (rx_shift << 1) | mosi_s1;
                        rx_valid <= 1'b1;
                        bit_cnt  <= 0;
                    end else begin
                        bit_cnt <= bit_cnt + 1;
                    end
                end
                if (shift_edge) begin
                    if (CPHA == 1'b0)
                        miso <= tx_shift_next[DATA_WIDTH-1];
                    else
                        miso <= tx_shift[DATA_WIDTH-1];
                    tx_shift <= tx_shift_next;
                end
            end
        end
    end
endmodule
