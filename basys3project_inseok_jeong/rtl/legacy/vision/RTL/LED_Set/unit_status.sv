`timescale 1ns / 1ps

// LED 2개 -> 유닛 상태 1개.
//
// 유닛 u는 zone 2u(LED A)와 2u+1(LED B)를 쓴다.
// (led_zone_pkg의 zone_unit 매핑과 일치: rack*6 + row*2 + col)
//
// 상태 정의:
//   둘 다 꺼짐   -> 비활성화
//   둘 다 초록   -> 정상
//   빨강 1개     -> 이상
//   빨강 2개     -> 비상
//
// 명시되지 않은 조합인 (초록 1, 꺼짐 1)은 "이상"으로 판정한다.
// LED 하나가 죽었거나 유닛이 반쯤 내려간 상태이며 정상은 아니기 때문이다.
// 원시 LED 상태도 SPI로 함께 보내므로, 이 정책을 바꾸고 싶으면
// 마스터 쪽에서 재해석하면 된다. FPGA를 다시 굽지 않아도 된다.
//
// 포트가 packed 벡터인 이유는 led_zone_pkg의 LED_FLAT_W 주석 참조.
module unit_status
    import led_zone_pkg::*;
(
    input  logic [LED_FLAT_W-1:0]  led_flat,
    output logic [UNIT_FLAT_W-1:0] unit_flat
);

    function automatic logic [1:0] unit_status_of (
        input logic [1:0] a,
        input logic [1:0] b
    );
        int red_n;
        int green_n;
        int off_n;
        begin
            red_n   = ((a == LED_RED)   ? 1 : 0) + ((b == LED_RED)   ? 1 : 0);
            green_n = ((a == LED_GREEN) ? 1 : 0) + ((b == LED_GREEN) ? 1 : 0);
            off_n   = ((a == LED_OFF)   ? 1 : 0) + ((b == LED_OFF)   ? 1 : 0);

            if (red_n == 2)        unit_status_of = UNIT_EMERGENCY;
            else if (red_n == 1)   unit_status_of = UNIT_FAULT;
            else if (green_n == 2) unit_status_of = UNIT_NORMAL;
            else if (off_n == 2)   unit_status_of = UNIT_INACTIVE;
            else                   unit_status_of = UNIT_FAULT;  // (초록1, 꺼짐1)
        end
    endfunction

    always_comb begin
        for (int u = 0; u < NUM_UNITS; u++) begin
            unit_flat[2*u +: 2] = unit_status_of(
                led_flat[2*(2*u)     +: 2],   // LED A = zone 2u
                led_flat[2*(2*u + 1) +: 2]    // LED B = zone 2u+1
            );
        end
    end

endmodule
