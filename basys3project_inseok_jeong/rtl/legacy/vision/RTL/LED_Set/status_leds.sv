`timescale 1ns / 1ps

// Basys3 보드 LED 16개로 동작 상태를 표시한다.
//
// SPI가 실제로 오가는지 PC 없이 눈으로 확인하는 것이 주 목적이다.
// SPI 이벤트는 마이크로초 단위라 그대로 LED에 연결하면 보이지 않는다.
// 펄스를 사람이 볼 수 있는 길이로 늘려서 표시한다.
//
//   LD0        마스터가 CS를 내리는 중 (폴링 주기로 깜빡임)
//   LD1        32바이트 송출 완료
//   LD3~LD2    (미사용)
//   LD7~LD4    요약 상태 - PC 없이도 서버 상태를 볼 수 있다
//                LD4 정상(all normal)  LD5 비활성  LD6 이상  LD7 비상
//   LD14~LD8   (미사용)
//   LD15       하트비트 약 1Hz - 설계가 살아 있고 클럭이 돈다는 증거
module status_leds #(
    parameter int CLK_FREQ = 100_000_000,

    // 펄스를 늘릴 길이 (ms). 폴링이 50ms 주기이므로 그보다 짧아야
    // 깜빡임으로 보인다. 같거나 길면 계속 켜진 것처럼 보인다.
    parameter int STRETCH_MS = 20
) (
    input logic clk,
    input logic reset,

    input logic cs_active,
    input logic pkt_done,

    // status_packer의 SUMMARY 바이트 하위 4비트
    //   [3] 비상  [2] 이상  [1] 비활성  [0] 정상
    input logic [3:0] summary,

    output logic [15:0] led
);

    localparam int STRETCH_CYCLES = (CLK_FREQ / 1000) * STRETCH_MS;
    localparam int HEARTBEAT_HALF = CLK_FREQ / 2;   // 약 1Hz

    // ---------------------------------------------------------
    // 펄스 늘리기
    // ---------------------------------------------------------
    logic [$clog2(STRETCH_CYCLES+1)-1:0] cs_cnt;
    logic [$clog2(STRETCH_CYCLES+1)-1:0] done_cnt;

    logic cs_led;
    logic done_led;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            cs_cnt   <= '0;
            done_cnt <= '0;
            cs_led   <= 1'b0;
            done_led <= 1'b0;
        end else begin
            // CS
            if (cs_active) begin
                cs_cnt <= STRETCH_CYCLES - 1;
                cs_led <= 1'b1;
            end else if (cs_cnt != 0) begin
                cs_cnt <= cs_cnt - 1;
            end else begin
                cs_led <= 1'b0;
            end

            // 패킷 완료
            if (pkt_done) begin
                done_cnt <= STRETCH_CYCLES - 1;
                done_led <= 1'b1;
            end else if (done_cnt != 0) begin
                done_cnt <= done_cnt - 1;
            end else begin
                done_led <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------
    // 하트비트
    //
    // 이게 안 깜빡이면 비트스트림이 안 올라갔거나 클럭/리셋 문제다.
    // SPI를 의심하기 전에 여기부터 봐야 한다.
    // ---------------------------------------------------------
    logic [$clog2(HEARTBEAT_HALF+1)-1:0] hb_cnt;
    logic                                hb;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            hb_cnt <= '0;
            hb     <= 1'b0;
        end else if (hb_cnt == HEARTBEAT_HALF - 1) begin
            hb_cnt <= '0;
            hb     <= ~hb;
        end else begin
            hb_cnt <= hb_cnt + 1;
        end
    end

    // ---------------------------------------------------------
    assign led = {
        hb,           // LD15
        7'b0,         // LD14 ~ LD8
        summary,      // LD7 ~ LD4
        2'b0,         // LD3 ~ LD2
        done_led,     // LD1
        cs_led        // LD0
    };

endmodule
