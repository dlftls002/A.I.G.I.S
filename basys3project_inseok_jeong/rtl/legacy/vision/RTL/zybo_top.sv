`timescale 1ns / 1ps

// Zybo 관제 보드 — SPI 마스터 + UART 중계.
//
//   Basys3 (SPI Slave) --SPI--> Zybo (SPI Master) --UART--> CP2102 --USB--> PC
//
// 하는 일은 하나뿐이다: 주기적으로 Basys3에서 32바이트 상태 패킷을 읽어
// UART로 그대로 흘려보낸다.
//
// PS(ARM)를 쓰지 않고 PL만으로 구현했다. 이 정도 중계에 프로세서를 올리면
// Vitis/BSP/베어메탈 빌드가 따라붙는데 얻는 것이 없다.
//
// UART로 형식을 바꾸지 않고 32바이트를 그대로 보낸다. 그래서 이미 문서화되고
// 검증된 Python 파서가 수정 없이 동작한다.
// 패킷 형식: MATS_prj/docs/SPI_INTERFACE.md
module zybo_top #(
    parameter int CLK_FREQ     = 125_000_000,  // Zybo PL 클럭
    parameter int SCLK_FREQ    =   1_000_000,  // SPI 1MHz
    parameter int BAUDRATE     =     115_200,
    parameter int PACKET_BYTES = 16,

    // 폴링 주기. 카메라가 약 30fps이므로 50~100ms가 적당하다.
    // 더 빨리 읽으면 같은 SEQ가 반복해서 나온다.
    parameter int POLL_MS = 50
) (
    input logic clk,

    // Zybo Z7의 푸시버튼은 누르면 1이다 (active-high).
    // active-low로 두면 평상시에 리셋이 걸린 상태가 되므로 그대로 받는다.
    input logic reset,

    // SPI master -> Basys3 Pmod JA
    output logic spi_sclk,
    output logic spi_mosi,
    output logic spi_cs_n,
    input  logic spi_miso,

    // UART -> CP2102 RXD
    output logic uart_tx_pin,

    // 상태 표시 LED
    output logic [1:0] led
);

    // =========================================================
    // 폴링 타이머
    // =========================================================
    localparam int POLL_CYCLES = (CLK_FREQ / 1000) * POLL_MS;

    logic [$clog2(POLL_CYCLES+1)-1:0] poll_cnt;
    logic                             poll_pulse;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            poll_cnt   <= '0;
            poll_pulse <= 1'b0;
        end else begin
            if (poll_cnt == POLL_CYCLES - 1) begin
                poll_cnt   <= '0;
                poll_pulse <= 1'b1;
            end else begin
                poll_cnt   <= poll_cnt + 1;
                poll_pulse <= 1'b0;
            end
        end
    end

    // =========================================================
    // SPI 마스터
    // =========================================================
    logic                     spi_start;
    logic                     spi_busy;
    logic                     spi_done;
    logic [8*PACKET_BYTES-1:0] spi_rx;

    // UART 송출 중에 새 패킷을 읽으면 버퍼가 덮어써진다.
    // 둘 다 한가할 때만 시작한다.
    logic uart_sending;

    assign spi_start = poll_pulse && !spi_busy && !uart_sending;

    spi_master #(
        .CLK_FREQ    (CLK_FREQ),
        .SCLK_FREQ   (SCLK_FREQ),
        .PACKET_BYTES(PACKET_BYTES)
    ) U_SPI_MASTER (
        .clk  (clk),
        .reset(reset),

        .start(spi_start),
        .busy (spi_busy),
        .done (spi_done),

        .rx_data(spi_rx),

        .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi),
        .spi_cs_n(spi_cs_n),
        .spi_miso(spi_miso)
    );

    // =========================================================
    // UART 중계
    //
    // spi_done에서 수신 버퍼를 잠그고 바이트 0부터 순서대로 송출한다.
    // =========================================================
    logic [8*PACKET_BYTES-1:0]       tx_buf;
    logic [$clog2(PACKET_BYTES)-1:0] tx_idx;

    logic       uart_start;
    logic [7:0] uart_data;
    logic       uart_busy;
    logic       uart_busy_d;

    // busy 하강 = 한 바이트 송출 완료
    logic byte_done;
    assign byte_done = uart_busy_d && !uart_busy;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            uart_sending <= 1'b0;
            uart_start   <= 1'b0;
            uart_data    <= 8'h00;
            tx_buf       <= '0;
            tx_idx       <= '0;
            uart_busy_d  <= 1'b0;
        end else begin
            uart_busy_d <= uart_busy;
            uart_start  <= 1'b0;

            if (spi_done && !uart_sending) begin
                // 수신 완료 -> 송출 시작
                tx_buf       <= spi_rx;
                tx_idx       <= '0;
                uart_data    <= spi_rx[7:0];      // 바이트 0
                uart_start   <= 1'b1;
                uart_sending <= 1'b1;
            end else if (uart_sending && byte_done) begin
                if (tx_idx == PACKET_BYTES - 1) begin
                    uart_sending <= 1'b0;
                end else begin
                    tx_idx     <= tx_idx + 1;
                    uart_data  <= tx_buf[8*(tx_idx + 1) +: 8];
                    uart_start <= 1'b1;
                end
            end
        end
    end

    uart_tx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUDRATE(BAUDRATE)
    ) U_UART_TX (
        .clk  (clk),
        .reset(reset),

        .start(uart_start),
        .data (uart_data),
        .busy (uart_busy),
        .tx   (uart_tx_pin)
    );

    // =========================================================
    // 상태 LED
    //   led[0]: SPI 트랜잭션 중
    //   led[1]: UART 송출 중
    // 배선이 맞는지 눈으로 확인하는 용도다.
    // =========================================================
    assign led[0] = spi_busy;
    assign led[1] = uart_sending;

endmodule
