`timescale 1ns/1ps
// Generic SPI master. MSB-first. Full-duplex (MISO captured into rx_data).
// SCLK half-period = CLK_DIV system clocks -> SCLK freq = clk/(2*CLK_DIV).
module spi_master #(
    parameter int DATA_WIDTH = 128,
    parameter bit CPOL       = 1'b0,
    parameter bit CPHA       = 1'b0,
    parameter int CLK_DIV    = 8
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  start,
    input  logic [DATA_WIDTH-1:0] tx_data,
    output logic                  busy,
    output logic                  done,
    output logic [DATA_WIDTH-1:0] rx_data,
    output logic                  rx_valid,
    output logic                  sclk,
    output logic                  cs_n,
    output logic                  mosi,
    input  logic                  miso
);
    localparam int HALF        = (CLK_DIV < 1) ? 1 : CLK_DIV;
    localparam int TOTAL_EDGES = 2 * DATA_WIDTH;

    typedef enum logic [1:0] {S_IDLE, S_XFER, S_TAIL} state_t;
    state_t state;

    integer div_cnt;
    integer edge_cnt;
    integer tail_cnt;
    integer tx_idx;
    logic   tick;
    logic [DATA_WIDTH-1:0] tx_shift;
    logic [DATA_WIDTH-1:0] rx_shift;

    // On the tick that creates edge index `edge_cnt`:
    //   even index -> leading (active) edge, odd -> trailing (idle) edge.
    // CPHA=0: sample on leading (even), change MOSI on trailing (odd).
    // CPHA=1: change MOSI on leading (even), sample on trailing (odd).
    wire is_sample_tick = (CPHA == 1'b0) ? (edge_cnt[0] == 1'b0)
                                         : (edge_cnt[0] == 1'b1);
    wire is_change_tick = (CPHA == 1'b0) ? (edge_cnt[0] == 1'b1)
                                         : (edge_cnt[0] == 1'b0);

    // clock divider: one tick every HALF system clocks during transfer
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 0;
            tick    <= 1'b0;
        end else if (state == S_XFER) begin
            if (div_cnt == HALF - 1) begin
                div_cnt <= 0;
                tick    <= 1'b1;
            end else begin
                div_cnt <= div_cnt + 1;
                tick    <= 1'b0;
            end
        end else begin
            div_cnt <= 0;
            tick    <= 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            sclk     <= CPOL;
            cs_n     <= 1'b1;
            mosi     <= 1'b0;
            busy     <= 1'b0;
            done     <= 1'b0;
            rx_valid <= 1'b0;
            rx_data  <= '0;
            edge_cnt <= 0;
            tail_cnt <= 0;
            tx_idx   <= 0;
            tx_shift <= '0;
            rx_shift <= '0;
        end else begin
            done     <= 1'b0;
            rx_valid <= 1'b0;
            case (state)
                S_IDLE: begin
                    sclk <= CPOL;
                    cs_n <= 1'b1;
                    if (start) begin
                        tx_shift <= tx_data;
                        rx_shift <= '0;
                        edge_cnt <= 0;
                        tx_idx   <= DATA_WIDTH - 1;
                        busy     <= 1'b1;
                        cs_n     <= 1'b0;
                        if (CPHA == 1'b0)
                            mosi <= tx_data[DATA_WIDTH-1];
                        state <= S_XFER;
                    end
                end
                S_XFER: begin
                    if (tick) begin
                        sclk <= ~sclk;
                        if (is_sample_tick)
                            rx_shift <= (rx_shift << 1) | miso;
                        if (is_change_tick) begin
                            if (CPHA == 1'b0) begin
                                if (tx_idx > 0) begin
                                    mosi   <= tx_shift[tx_idx-1];
                                    tx_idx <= tx_idx - 1;
                                end
                            end else begin
                                mosi <= tx_shift[tx_idx];
                                if (tx_idx > 0)
                                    tx_idx <= tx_idx - 1;
                            end
                        end
                        if (edge_cnt == TOTAL_EDGES - 1) begin
                            sclk  <= CPOL;
                            tail_cnt <= 0;
                            state <= S_TAIL;
                        end
                        edge_cnt <= edge_cnt + 1;
                    end
                end
                S_TAIL: begin
                    if (tail_cnt == HALF - 1) begin
                        cs_n     <= 1'b1;
                        busy     <= 1'b0;
                        done     <= 1'b1;
                        rx_data  <= rx_shift;
                        rx_valid <= 1'b1;
                        state    <= S_IDLE;
                    end else begin
                        tail_cnt <= tail_cnt + 1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
