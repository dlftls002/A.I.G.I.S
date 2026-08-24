`timescale 1ns / 1ps

// SPI 슬레이브. 관제 보드(Zybo)가 마스터이고 Basys3가 슬레이브다.
//
// Mode 0 (CPOL=0, CPHA=0), MSB first, 8bit 워드.
//   SCLK 유휴 Low
//   하강 엣지에서 MISO 갱신, 마스터는 상승 엣지에서 샘플링
//
// MOSI는 사용하지 않는다. 명령 체계가 없고 마스터는 읽기만 한다.
//
// 형식은 docs/SPI_INTERFACE.md 참조.
//
// ---------------------------------------------------------------
// 설계 요점 1 — 스냅샷
//
// 검출기는 영상 프레임마다(약 30Hz) 페이로드를 갱신하고, SPI는 그와
// 무관한 시점에 읽어간다. 그대로 두면 앞 바이트는 프레임 N, 뒤 바이트는
// 프레임 N+1에서 온 값이 섞인다(tearing).
//
// CS 하강 엣지에서 페이로드 전체를 슬레이브 내부 버퍼로 복사하고,
// 트랜잭션 동안에는 그 사본만 내보낸다. 이러면 한 패킷은 항상 한 프레임의
// 일관된 스냅샷이 된다.
//
// ---------------------------------------------------------------
// 설계 요점 2 — 비동기 입력
//
// SCLK/CS/MOSI는 마스터가 만드는 신호라 이 보드의 클럭과 비동기다.
// 2단 동기화기를 거친 뒤 엣지를 검출한다. SCLK를 직접 클럭으로 쓰지 않고
// 시스템 클럭으로 오버샘플링하는 방식이라, 글로벌 클럭 버퍼를 잡아먹지
// 않고 타이밍 제약도 단순해진다.
//
// 이 방식의 제약: 시스템 클럭이 SCLK보다 충분히 빨라야 한다.
// clk = 100MHz 기준 SCLK는 10MHz 이하를 권장한다.
module spi_slave
    import led_zone_pkg::*;
(
    input logic clk,      // 시스템 클럭 (100MHz 권장)
    input logic reset,

    // 페이로드 (검출 도메인에서 생성). 바이트 i는 payload[8*i +: 8].
    input logic [PAYLOAD_W-1:0] payload,

    // SPI 물리 신호 (Pmod JA)
    input  logic spi_sclk,
    input  logic spi_mosi,   // 미사용
    input  logic spi_cs_n,
    output logic spi_miso,

    // 디버그용 관측 신호 (보드 LED로 뺀다)
    output logic dbg_cs_active,   // 마스터가 CS를 내리고 있는 동안 High
    output logic dbg_pkt_done     // 32바이트를 다 내보냈을 때 1클럭 펄스
);

    // ---------------------------------------------------------
    // 입력 동기화 (2단)
    // ---------------------------------------------------------
    logic [2:0] sclk_sync;
    logic [1:0] cs_sync;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            sclk_sync <= 3'b000;
            cs_sync   <= 2'b11;      // CS는 유휴 High
        end else begin
            sclk_sync <= {sclk_sync[1:0], spi_sclk};
            cs_sync   <= {cs_sync[0],     spi_cs_n};
        end
    end

    logic cs_active;
    logic cs_falling;

    assign cs_active  = ~cs_sync[1];
    assign cs_falling = cs_sync[1] & ~cs_sync[0];   // High -> Low

    logic sclk_falling;

    assign sclk_falling = sclk_sync[2] & ~sclk_sync[1];   // High -> Low

    // ---------------------------------------------------------
    // 스냅샷 버퍼
    // ---------------------------------------------------------
    logic [PAYLOAD_W-1:0] snapshot;

    localparam int BYTE_IDX_W = $clog2(PACKET_BYTES + 1);

    logic [BYTE_IDX_W-1:0] byte_idx;
    logic [2:0]            bit_idx;     // 7 -> 0 (MSB first)
    logic [7:0]            shift_reg;

    // 페이로드를 다 내보낸 뒤에는 0x00을 계속 내보낸다.
    logic payload_done;

    assign payload_done = (byte_idx >= PACKET_BYTES);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            byte_idx  <= '0;
            bit_idx   <= 3'd7;
            shift_reg <= 8'h00;
            snapshot  <= '0;
            dbg_pkt_done <= 1'b0;
        end else begin
            dbg_pkt_done <= 1'b0;

            if (cs_falling) begin
                // 트랜잭션 시작: 페이로드 전체를 확정한다
                snapshot  <= payload;

                byte_idx  <= '0;
                bit_idx   <= 3'd7;
                shift_reg <= payload[7:0];      // 바이트 0
            end else if (!cs_active) begin
                // 유휴 상태
                byte_idx <= '0;
                bit_idx  <= 3'd7;
            end else if (sclk_falling) begin
                // 한 비트 전송 완료 -> 다음 비트 준비
                if (bit_idx == 3'd0) begin
                    bit_idx <= 3'd7;

                    if (!payload_done) begin
                        byte_idx <= byte_idx + 1;

                        // 마지막 바이트를 다 내보낸 시점
                        if (byte_idx == PACKET_BYTES - 1) dbg_pkt_done <= 1'b1;
                    end

                    // 다음 바이트 적재. 범위를 넘으면 0을 내보낸다.
                    if ((byte_idx + 1) < PACKET_BYTES)
                        shift_reg <= snapshot[8*(byte_idx + 1) +: 8];
                    else
                        shift_reg <= 8'h00;
                end else begin
                    bit_idx   <= bit_idx - 3'd1;
                    shift_reg <= {shift_reg[6:0], 1'b0};
                end
            end
        end
    end

    // ---------------------------------------------------------
    // MISO
    //
    // Mode 0에서 첫 비트는 CS 하강과 함께 유효해야 한다. shift_reg가
    // CS 하강에서 payload[0]으로 적재되므로 그 MSB가 바로 나간다.
    //
    // CS가 High면 High-Z가 정석이지만, 이 시스템은 슬레이브가 하나뿐이라
    // 버스 경합이 없다. Pmod에 tri-state를 두면 제약이 늘어나므로
    // 그냥 0을 내보낸다.
    // ---------------------------------------------------------
    assign spi_miso = cs_active ? shift_reg[7] : 1'b0;

    assign dbg_cs_active = cs_active;

endmodule
