`timescale 1ns / 1ps
module OV7670_Controller #(
    parameter CLK_FREQ = 100_000_000
) (
    input logic clk,
    input logic reset,  // 카운터와 동일하게 Active High Reset 적용
    // I2C/SCCB Master Handshake
    input logic ready,
    output logic valid,
    output logic [7:0] reg_addr,
    output logic [7:0] reg_data,
    output logic init_done
);
    // ==========================================
    // 1. 1ms Tick 생성 (사용자 카운터 인스턴스화)
    // ==========================================
    logic ms_tick;

    counter #(
        .CLK_FREQ(CLK_FREQ),
        .MS(1)  // 1ms 주기로 tick 발생
    ) u_1ms_timer (
        .clk(clk),
        .reset(reset),
        .ms_tick(ms_tick)
    );
    // ==========================================
    // 2. 상태(State) 정의
    // ==========================================
    typedef enum logic [1:0] {
        STATE_IDLE       = 2'd0,
        STATE_SEND       = 2'd1,
        STATE_WAIT_DELAY = 2'd2,
        STATE_DONE       = 2'd3
    } state_t;
    state_t state;
    // ==========================================
    // 3. 초기화 레지스터 ROM 구성
    // ==========================================
    localparam int ROM_DEPTH = 75;
    logic [15:0] init_rom  [0:ROM_DEPTH-1];
    logic [ 6:0] rom_index;
    initial begin
        // { 주소(8bit), 데이터(8bit) }
        // 8'hFF 주소는 특수 명령어(Delay)로 사용되며, 데이터는 ms 단위입니다.

        // --- 2. OV7670_ResetSW ---
        init_rom[0]  = {8'h12, 8'h80};  // Reset
        init_rom[1]  = {8'hFF, 8'd30};  // WAIT 30ms
        init_rom[2]  = {8'h3A, 8'h04};
        init_rom[3]  = {8'h12, 8'h00};
        init_rom[4]  = {8'h13, 8'hE7};
        init_rom[5]  = {8'h6F, 8'h9F};
        init_rom[6]  = {8'hB0, 8'h84};
        init_rom[7]  = {8'h70, 8'h3A};
        init_rom[8]  = {8'h71, 8'h35};
        init_rom[9]  = {8'h72, 8'h11};
        init_rom[10] = {8'h73, 8'hF0};
        init_rom[11] = {8'h7A, 8'h20};
        init_rom[12] = {8'h7B, 8'h10};
        init_rom[13] = {8'h7C, 8'h1E};
        init_rom[14] = {8'h7D, 8'h35};
        init_rom[15] = {8'h7E, 8'h5A};
        init_rom[16] = {8'h7F, 8'h69};
        init_rom[17] = {8'h80, 8'h76};
        init_rom[18] = {8'h81, 8'h80};
        init_rom[19] = {8'h82, 8'h88};
        init_rom[20] = {8'h83, 8'h8F};
        init_rom[21] = {8'h84, 8'h96};
        init_rom[22] = {8'h85, 8'hA3};
        init_rom[23] = {8'h86, 8'hAF};
        init_rom[24] = {8'h87, 8'hC4};
        init_rom[25] = {8'h88, 8'hD7};
        init_rom[26] = {8'h89, 8'hE8};
        init_rom[27] = {8'h00, 8'h00};
        init_rom[28] = {8'h10, 8'h00};
        init_rom[29] = {8'h0D, 8'h40};
        init_rom[30] = {8'h14, 8'h18};
        init_rom[31] = {8'hA5, 8'h05};
        init_rom[32] = {8'hAB, 8'h07};
        init_rom[33] = {8'h24, 8'h95};
        init_rom[34] = {8'h25, 8'h33};
        init_rom[35] = {8'h26, 8'hE3};
        init_rom[36] = {8'h9F, 8'h78};
        init_rom[37] = {8'hA0, 8'h68};
        init_rom[38] = {8'hA1, 8'h03};
        init_rom[39] = {8'hA6, 8'hD8};
        init_rom[40] = {8'hA7, 8'hD8};
        init_rom[41] = {8'hA8, 8'hF0};
        init_rom[42] = {8'hA9, 8'h90};
        init_rom[43] = {8'hAA, 8'h94};
        init_rom[44] = {8'hFF, 8'd10};  // WAIT 10ms
        // --- 3. OV7670_SetResolution(QVGA) ---
        init_rom[45] = {8'h12, 8'h11};  // COM7
        init_rom[46] = {8'hFF, 8'd1};  // WAIT 1ms
        init_rom[47] = {8'h0C, 8'h04};  // COM3
        init_rom[48] = {8'hFF, 8'd1};
        init_rom[49] = {8'h3E, 8'h19};  // COM14
        init_rom[50] = {8'hFF, 8'd1};
        init_rom[51] = {8'h70, 8'h3A};  // SCALING_XSC
        init_rom[52] = {8'hFF, 8'd1};
        init_rom[53] = {8'h71, 8'h35};  // SCALING_YSC
        init_rom[54] = {8'hFF, 8'd1};
        init_rom[55] = {8'h72, 8'h11};  // SCALING_DCWCTR
        init_rom[56] = {8'hFF, 8'd1};
        init_rom[57] = {8'h73, 8'hF1};  // SCALING_PCLK_DIV
        init_rom[58] = {8'hFF, 8'd1};
        init_rom[59] = {8'hA2, 8'h02};  // SCALING_PCLK_DELAY
        init_rom[60] = {8'hFF, 8'd1};

        init_rom[61] = {8'h17, 8'h15};  // HSTART
        init_rom[62] = {8'h18, 8'h03};  // HSTOP
        init_rom[63] = {8'h32, 8'h00};  // HREF
        init_rom[64] = {8'h19, 8'h03};  // VSTART
        init_rom[65] = {8'h1A, 8'h7B};  // VSTOP
        init_rom[66] = {8'h03, 8'h00};  // VREF
        init_rom[67] = {8'hFF, 8'd10};  // WAIT 10ms
        // --- 4. OV7670_SetColorFormat(RGB565) ---
        init_rom[68] = {8'h12, 8'h14};
        init_rom[69] = {8'h40, 8'h10};
        // --- 5. OV7670_AutoExposureMode(1) ---
        init_rom[70] = {8'h13, 8'hE7};
        // --- 6. OV7670_SetBrightness(120) ---
        init_rom[71] = {8'h55, 8'h87};
        // --- 7. OV7670_AutoGainMode(1) ---
        init_rom[72] = {8'h13, 8'hE7};

        init_rom[73] = {8'hFF, 8'd0};
        init_rom[74] = {8'hFF, 8'd0};
    end
    // ==========================================
    // 4. FSM 및 제어 로직
    // ==========================================
    logic [ 7:0] delay_cnt;
    logic [ 7:0] target_ms;
    logic [15:0] current_cmd;
    logic [ 7:0] cmd_addr;
    logic [ 7:0] cmd_data;
    logic        is_delay_cmd;
    assign current_cmd  = init_rom[rom_index];
    assign cmd_addr     = current_cmd[15:8];
    assign cmd_data     = current_cmd[7:0];
    assign is_delay_cmd = (cmd_addr == 8'hFF);
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state     <= STATE_IDLE;
            rom_index <= '0;
            delay_cnt <= '0;
            target_ms <= '0;
            valid     <= 1'b0;
            reg_addr  <= '0;
            reg_data  <= '0;
            init_done <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (rom_index < ROM_DEPTH) begin
                        if (is_delay_cmd) begin
                            // 주소가 0xFF이면 Delay 명령어 수행
                            if (cmd_data > 0) begin
                                target_ms <= cmd_data;
                                delay_cnt <= '0;
                                state     <= STATE_WAIT_DELAY;
                            end else begin
                                // 0ms인 경우 건너뜀
                                rom_index <= rom_index + 1;
                            end
                        end else begin
                            // 일반 레지스터 쓰기 명령어 셋팅
                            reg_addr <= cmd_addr;
                            reg_data <= cmd_data;
                            valid    <= 1'b1;
                            state    <= STATE_SEND;
                        end
                    end else begin
                        state     <= STATE_DONE;
                        init_done <= 1'b1;
                    end
                end
                STATE_SEND: begin
                    // I2C/SCCB Master 모듈에 데이터를 전달하는 Handshake
                    if (valid && ready) begin
                        valid     <= 1'b0;
                        rom_index <= rom_index + 1;
                        state     <= STATE_IDLE;
                    end
                end
                STATE_WAIT_DELAY: begin
                    // ms_tick이 발생할 때마다 카운트 다운(업)
                    if (ms_tick) begin
                        if (delay_cnt >= target_ms - 1) begin
                            delay_cnt <= '0;
                            rom_index <= rom_index + 1;
                            state     <= STATE_IDLE;
                        end else begin
                            delay_cnt <= delay_cnt + 1;
                        end
                    end
                end
                STATE_DONE: begin
                    init_done <= 1'b1;
                    valid     <= 1'b0;
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end
endmodule

module counter #(
    parameter CLK_FREQ = 100_000_000,
    MS = 10  //10ms tick , 1ms tick(modify)
) (
    input  logic clk,
    input  logic reset,
    output logic ms_tick
);
    localparam MAX_COUNT = (CLK_FREQ / 1000) * MS;
    localparam int BIT_WIDTH = $clog2(MAX_COUNT);
    logic [BIT_WIDTH-1:0] count;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            count   <= '0;
            ms_tick <= 1'b0;
        end else begin
            if (count == MAX_COUNT - 1) begin
                count   <= '0;
                ms_tick <= 1'b1;
            end else begin
                count   <= count + 1;
                ms_tick <= 1'b0;
            end
        end
    end

endmodule
