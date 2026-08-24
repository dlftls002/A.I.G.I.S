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
    // 구역 좌표표 (카메라 320 x 240 좌표)
    //
    //   row 0 : 위, 가까움 -> 넓고 높다
    //   row 2 : 아래, 멂   -> 좁고 낮으며 안쪽으로 들어온다
    //
    // 현재 값은 원근을 반영한 초기 추정치다. 실측으로 대체한다.
    // ---------------------------------------------------------
    function automatic int zone_x0 (input int z);
        case (z)
            0: zone_x0 =  30;   // row0 col0
            1: zone_x0 = 165;   // row0 col1
            2: zone_x0 =  45;   // row1 col0
            3: zone_x0 = 170;   // row1 col1
            4: zone_x0 =  60;   // row2 col0
            5: zone_x0 = 175;   // row2 col1
            default: zone_x0 = 0;
        endcase
    endfunction

    function automatic int zone_x1 (input int z);
        case (z)
            0: zone_x1 = 145;
            1: zone_x1 = 280;
            2: zone_x1 = 150;
            3: zone_x1 = 275;
            4: zone_x1 = 155;
            5: zone_x1 = 270;
            default: zone_x1 = 0;
        endcase
    endfunction

    function automatic int zone_y0 (input int z);
        case (z)
            0, 1: zone_y0 =  24;   // row 0
            2, 3: zone_y0 = 100;   // row 1
            4, 5: zone_y0 = 170;   // row 2
            default: zone_y0 = 0;
        endcase
    endfunction

    function automatic int zone_y1 (input int z);
        case (z)
            0, 1: zone_y1 =  85;   // row 0  (높이 62)
            2, 3: zone_y1 = 155;   // row 1  (높이 56)
            4, 5: zone_y1 = 215;   // row 2  (높이 46, 가장 낮다)
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
