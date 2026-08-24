`timescale 1ns / 1ps

// LED/유닛 상태를 SPI 페이로드 32바이트로 조립한다.
//
// 형식은 docs/SPI_INTERFACE.md 를 따른다. 그 문서가 팀 간 계약이므로
// 여기를 고치면 문서와 tb_spi_slave.sv도 함께 고쳐야 한다.
module status_packer
    import led_zone_pkg::*;
#(
    parameter logic [7:0] VERSION = PROTOCOL_VERSION,
    parameter logic [7:0] MY_RACK_ID = RACK_ID
) (
    input logic clk,     // cam_pclk
    input logic reset,

    input logic [LED_FLAT_W-1:0]  led_flat,
    input logic [UNIT_FLAT_W-1:0] unit_flat,

    // 프레임 경계 펄스. 이때 페이로드를 갱신한다.
    input logic frame_tick,

    // 32바이트 페이로드. 바이트 i는 payload[8*i +: 8].
    output logic [PAYLOAD_W-1:0] payload
);

    localparam logic [7:0] SYNC_HI = 8'hA5;
    localparam logic [7:0] SYNC_LO = 8'h5A;

    // 페이로드에는 이번 갱신으로 확정될 시퀀스가 실려야 하므로 seq_next를 쓴다.
    // seq를 그대로 쓰면 페이로드가 직전 시퀀스를 달고 나간다.
    logic [7:0] seq;
    logic [7:0] seq_next;

    assign seq_next = seq + 8'd1;

    // ---------------------------------------------------------
    // 요약 비트
    // ---------------------------------------------------------
    logic any_emergency;
    logic any_fault;
    logic any_inactive;
    logic all_normal;

    always_comb begin
        any_emergency = 1'b0;
        any_fault     = 1'b0;
        any_inactive  = 1'b0;
        all_normal    = 1'b1;

        for (int u = 0; u < NUM_UNITS; u++) begin
            case (unit_flat[2*u +: 2])
                UNIT_EMERGENCY: any_emergency = 1'b1;
                UNIT_FAULT:     any_fault     = 1'b1;
                UNIT_INACTIVE:  any_inactive  = 1'b1;
                default: ;
            endcase

            if (unit_flat[2*u +: 2] != UNIT_NORMAL) all_normal = 1'b0;
        end
    end

    logic [7:0] summary_byte;

    assign summary_byte = {4'b0000,
                           any_emergency,
                           any_fault,
                           any_inactive,
                           all_normal};

    // ---------------------------------------------------------
    // 조립
    //
    // 유닛 u -> rack = u / UNITS_PER_RACK, unit_in_rack = u % UNITS_PER_RACK
    // 유닛 u의 LED는 zone 2u(A), 2u+1(B)
    // ---------------------------------------------------------
    logic [PAYLOAD_W-1:0] next_payload;
    logic [7:0]           chk;

    always_comb begin
        next_payload = '0;

        next_payload[8*0 +: 8] = SYNC_HI;
        next_payload[8*1 +: 8] = SYNC_LO;
        next_payload[8*2 +: 8] = VERSION;
        next_payload[8*3 +: 8] = seq_next;
        next_payload[8*4 +: 8] = MY_RACK_ID;            // 이 보드가 담당하는 랙
        next_payload[8*5 +: 8] = 8'(NUM_UNITS);
        next_payload[8*6 +: 8] = summary_byte;
        next_payload[8*7 +: 8] = 8'h00;                 // reserved

        for (int u = 0; u < NUM_UNITS; u++) begin
            // ID 바이트: {rack, unit_in_rack}
            // 이 보드는 랙 하나만 담당하므로 상위 니블은 RACK_ID 그대로다.
            next_payload[8*(UNIT_BASE + u*2) +: 8] = {
                MY_RACK_ID[3:0],
                4'(u)
            };

            // STATUS 바이트: {2'b00, unit_status, led_b, led_a}
            next_payload[8*(UNIT_BASE + u*2 + 1) +: 8] = {
                2'b00,
                unit_flat[2*u +: 2],
                led_flat[2*(2*u + 1) +: 2],   // LED B
                led_flat[2*(2*u)     +: 2]    // LED A
            };
        end

        // 체크섬: 오프셋 2 ~ PACKET_BYTES-2 의 XOR
        chk = 8'h00;
        for (int i = 2; i < PACKET_BYTES - 1; i++)
            chk = chk ^ next_payload[8*i +: 8];

        next_payload[8*(PACKET_BYTES-1) +: 8] = chk;
    end

    // ---------------------------------------------------------
    // 프레임 경계에서만 갱신한다.
    //
    // SPI 도메인은 CS 하강에서 이 값을 스냅샷으로 가져간다.
    // ---------------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            seq     <= 8'h00;
            payload <= '0;
        end else if (frame_tick) begin
            seq     <= seq_next;
            payload <= next_payload;
        end
    end

endmodule
