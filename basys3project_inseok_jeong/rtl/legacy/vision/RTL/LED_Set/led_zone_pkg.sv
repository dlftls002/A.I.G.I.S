`timescale 1ns / 1ps

// 서버 랙 LED 감시 구역(ROI) 정의.
//
// 물리 배치: 랙 1대, 유닛 3개, 유닛마다 LED 2개 -> LED 6개
//
//   [A][B]  unit 0   (위, 카메라에 가까움)
//   [A][B]  unit 1
//   [A][B]  unit 2   (아래, 카메라에서 멂)
//
// zone 인덱스: row*2 + col
// unit 인덱스: row          (zone_unit(z) = z / 2)
//
// ---------------------------------------------------------------
// 원근 왜곡
//
// 카메라를 랙 상단에 달아 아래로 비스듬히 내려다본다. 정면 촬영이 아니므로
// 위 유닛은 가깝고 크게, 아래 유닛은 멀고 작게 보이며 화면 중앙 쪽으로
// 모인다. 위아래 LED를 보는 각도가 서로 다르다.
//
// 그래서 균등 격자(원점 + 일정 간격)로는 맞출 수 없다. 구역 6개의 좌표를
// 각각 표로 둔다. 개수가 적어 표가 오히려 단순하고, 행마다 크기와 위치를
// 독립적으로 조정할 수 있다.
//
// 조정 방법: 화면에 격자를 띄우고(sw[0]) LED가 칸 안에 들어오도록
// 아래 표의 숫자를 고친다. 검출과 화면이 같은 표를 쓰므로 한 곳만 고치면
// 양쪽이 함께 움직인다.
// ---------------------------------------------------------------
package led_zone_pkg;

    localparam int NUM_RACKS      = 1;
    localparam int UNITS_PER_RACK = 3;
    localparam int LEDS_PER_UNIT  = 2;

    localparam int NUM_UNITS = NUM_RACKS * UNITS_PER_RACK;   // 3
    localparam int NUM_ZONES = NUM_UNITS * LEDS_PER_UNIT;    // 6

    // 이 보드가 담당하는 랙 번호. SPI 패킷에 실린다.
    // 나중에 보드를 늘려 랙마다 하나씩 둘 때 마스터가 구분할 수 있도록 한다.
    localparam logic [7:0] RACK_ID = 8'd0;

    // ---------------------------------------------------------
    // 화면 회전
    //
    // 브레드보드를 세로로 세워 카메라를 비스듬히 달았더니 화면에서
    // 보드가 누워 보인다. 원래 방향 그대로는 맞출 수 없다.
    // 현재 90도(시계방향). 45도로 맞춰보고 한 번 더 돌린 결과다.
    //
    // 구역 6개를 각각 회전시키는 대신 **픽셀 좌표를 한 번만 역회전**시키고
    // 구역표는 축 정렬로 유지한다. 회전 중심과 각도가 모든 구역에 공통이라
    // 이렇게 하면 곱셈이 픽셀당 4번으로 끝난다. 구역마다 회전시키면
    // 6배가 된다.
    //
    // 회전 후 좌표계에서는 보드가 똑바로 서 있으므로 구역표가 단순한
    // 2열 x 3행 격자가 된다.
    //
    // 부호: 화면 좌표는 y가 아래를 향한다. 구역을 화면에서 시계방향으로
    // 돌리려면 픽셀을 반시계방향으로 돌려서 판정해야 한다.
    //   rx = CX + ( dx*COS + dy*SIN) >> 8
    //   ry = CY + (-dx*SIN + dy*COS) >> 8
    // ---------------------------------------------------------
    localparam int FRAME_W = 320;
    localparam int FRAME_H = 240;

    localparam int ROT_CX = FRAME_W / 2;   // 160
    localparam int ROT_CY = FRAME_H / 2;   // 120

    // Q8 고정소수점 (256 = 1.0)
    //    0도 -> COS=256 SIN=0
    //   45도 -> COS=181 SIN=181
    //   90도 -> COS=0   SIN=256     <- 현재
    //  135도 -> COS=-181 SIN=181
    // 각도를 바꾸려면 이 두 값만 고친다. 검출과 화면이 함께 따라간다.
    //
    // 90도에서는 곱셈 계수가 0과 256이라 곱셈기가 통째로 사라진다.
    // 좌표가 그대로 맞바뀌므로 반올림 오차도 없다.
    // 화면에서 사각형이 다시 축 정렬로 보인다 (45도에서만 기울어 보인다).
    localparam int ROT_COS = 0;
    localparam int ROT_SIN = 256;

    // 화면 좌표 -> 회전 후 좌표
    function automatic int rot_x (input int sx, input int sy);
        rot_x = ROT_CX + ((( (sx - ROT_CX) * ROT_COS)
                         + ( (sy - ROT_CY) * ROT_SIN)) >>> 8);
    endfunction

    function automatic int rot_y (input int sx, input int sy);
        rot_y = ROT_CY + (((-(sx - ROT_CX) * ROT_SIN)
                         + ( (sy - ROT_CY) * ROT_COS)) >>> 8);
    endfunction

    // 회전 후 좌표 -> 화면 좌표 (역변환. 검증용)
    function automatic int unrot_x (input int rx, input int ry);
        unrot_x = ROT_CX + ((( (rx - ROT_CX) * ROT_COS)
                           - ( (ry - ROT_CY) * ROT_SIN)) >>> 8);
    endfunction

    function automatic int unrot_y (input int rx, input int ry);
        unrot_y = ROT_CY + ((( (rx - ROT_CX) * ROT_SIN)
                           + ( (ry - ROT_CY) * ROT_COS)) >>> 8);
    endfunction

    // ---------------------------------------------------------
    // 구역 좌표표 — **회전 후 좌표계** 기준
    //
    // 회전 후에는 보드가 똑바로 서 있으므로 평범한 2열 x 3행 격자다.
    //   row 0 : 위 (카메라에 가까움)
    //   row 2 : 아래 (멂)
    //
    // 화면에 그려질 때는 시계방향 90도 돌아간 위치로 보인다.
    //   회전 후 y축(보드 위->아래) -> 화면 오른쪽->왼쪽
    //   회전 후 x축(좌->우 LED)   -> 화면 위->아래
    //
    // 주의: 회전 후 사각형이 화면 밖으로 나가지 않아야 한다.
    // 45도에서는 바운딩 박스가 약 1.41배로 커지므로 여유를 둬야 한다.
    // tb_led_zone이 네 꼭짓점을 화면 좌표로 되돌려 전수 확인한다.
    //
    // 조정 방향 (90도 기준):
    //   zone_y(구역표) 감소 -> 화면 오른쪽으로 이동   (화면x = 280 - ry)
    //   zone_x(구역표) 증가 -> 화면 아래로 이동       (화면y = rx - 40)
    //
    // 현재 화면 점유: x 41~272, y 45~200 (프레임 320x240)
    // 좌우 여백 41/47, 상하 여백 45/39. 칸 크기 69x71.
    //
    // 현재 값은 초기 추정치다. 실측으로 대체한다.
    // ---------------------------------------------------------
    function automatic int zone_x0 (input int z);
        case (z)
            0: zone_x0 =  85;   // row0 col0
            1: zone_x0 = 169;   // row0 col1
            2: zone_x0 =  85;   // row1 col0
            3: zone_x0 = 169;   // row1 col1
            4: zone_x0 =  85;   // row2 col0
            5: zone_x0 = 169;   // row2 col1
            default: zone_x0 = 0;
        endcase
    endfunction

    function automatic int zone_x1 (input int z);
        case (z)
            0: zone_x1 = 156;
            1: zone_x1 = 240;
            2: zone_x1 = 156;
            3: zone_x1 = 240;
            4: zone_x1 = 156;
            5: zone_x1 = 240;
            default: zone_x1 = 0;
        endcase
    endfunction

    function automatic int zone_y0 (input int z);
        case (z)
            0, 1: zone_y0 =   8;   // row 0 (보드 위)  -> 화면 오른쪽
            2, 3: zone_y0 =  89;   // row 1
            4, 5: zone_y0 = 170;   // row 2 (보드 아래) -> 화면 왼쪽
            default: zone_y0 = 0;
        endcase
    endfunction

    function automatic int zone_y1 (input int z);
        case (z)
            0, 1: zone_y1 =  77;
            2, 3: zone_y1 = 158;
            4, 5: zone_y1 = 239;
            default: zone_y1 = 0;
        endcase
    endfunction

    // 구역 하나가 가질 수 있는 최대 픽셀 수의 상한.
    // 카운터 폭을 정하는 데만 쓰인다. 구역마다 크기가 다르므로 정확한
    // 최대값 대신 넉넉한 상한을 둔다. 과대평가해도 비트 하나 늘 뿐이다.
    // (현재 가장 큰 구역은 row0의 116 x 62 = 7192)
    localparam int ZONE_MAX_PIXELS = 8192;

    // ---------------------------------------------------------
    // 인덱스 헬퍼
    // ---------------------------------------------------------
    function automatic int zone_rack (input int z);
        zone_rack = 0;                       // 이 보드는 랙 하나만 본다
    endfunction

    function automatic int zone_row (input int z);
        zone_row = z / LEDS_PER_UNIT;
    endfunction

    function automatic int zone_col (input int z);
        zone_col = z % LEDS_PER_UNIT;
    endfunction

    function automatic int zone_unit (input int z);
        zone_unit = z / LEDS_PER_UNIT;
    endfunction

    // ---------------------------------------------------------
    // SPI 패킷 레이아웃 (docs/SPI_INTERFACE.md 와 일치해야 한다)
    //
    // 프로토콜 버전 2. 랙 1대 3유닛 구성으로 바뀌면서 길이가 바뀌었다.
    //
    //   0  SYNC_HI 0xA5
    //   1  SYNC_LO 0x5A
    //   2  VERSION 0x02
    //   3  SEQ
    //   4  RACK_ID
    //   5  UNIT_COUNT
    //   6  SUMMARY
    //   7  RESERVED
    //   8  유닛 레코드 3개 x 2바이트
    //  14  RESERVED
    //  15  CHECKSUM (오프셋 2~14 XOR)
    // ---------------------------------------------------------
    localparam logic [7:0] PROTOCOL_VERSION = 8'h02;

    localparam int UNIT_BASE    = 8;
    localparam int UNIT_REC_LEN = 2;
    localparam int PACKET_BYTES = 16;

    // LED 상태 코드
    localparam logic [1:0] LED_OFF   = 2'b00;
    localparam logic [1:0] LED_GREEN = 2'b01;
    localparam logic [1:0] LED_RED   = 2'b10;

    // 유닛 상태 코드
    localparam logic [1:0] UNIT_INACTIVE  = 2'b00;  // 서버 비활성화
    localparam logic [1:0] UNIT_NORMAL    = 2'b01;  // 서버 정상
    localparam logic [1:0] UNIT_FAULT     = 2'b10;  // 서버 이상
    localparam logic [1:0] UNIT_EMERGENCY = 2'b11;  // 서버 비상

    // ---------------------------------------------------------
    // 모듈 간 상태 전달은 packed 벡터로 한다.
    //
    // unpacked array를 포트로 쓰면 원소 단위 변경이 always_comb의 추론
    // 감도 목록에 잡히지 않는 경우가 있다.
    //
    //   LED  z  -> led_flat [2*z +: 2]
    //   유닛 u  -> unit_flat[2*u +: 2]
    // ---------------------------------------------------------
    localparam int LED_FLAT_W  = 2 * NUM_ZONES;   // 12
    localparam int UNIT_FLAT_W = 2 * NUM_UNITS;   //  6
    localparam int PAYLOAD_W   = 8 * PACKET_BYTES;

endpackage
