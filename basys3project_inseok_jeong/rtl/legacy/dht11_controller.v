`timescale 1ns / 1ps

module dht11_controller #(
    parameter CLK_FREQ = 100_000_000
) (
    input         clk,
    input         rst,
    input         start,
    output [15:0] humidity,
    output [15:0] temperature,
    output        dht11_done,
    output        dht11_valid,
    output [ 3:0] debug,
    inout         dhtio
);

    wire tick_10u;
    tick_gen_10u U_TICK_10u (
        .clk(clk),
        .rst(rst),
        .tick_10u(tick_10u)
    );

    // STATE
    parameter IDLE = 0, START = 1, WAIT = 2, SYNC_L = 3, SYNC_H = 4,
              DATA_SYNC = 5, DATA_C = 6, STOP = 7; // data 콜렉트 // state는 개인 별 상황에 맞게 바꿔라.
    reg [3:0] c_state, n_state;
    reg dhtio_reg, dhtio_next;  // 얘는 FF
    //reg io_sel; // 얘는 조합으로 내보내겠다.초기값 잘 넣어서 Latch만 안 나오면 된다.
    // 조합으로 하니까 현상태 유지안 돼서 순차로 바꾸겠다.
    reg io_sel_reg, io_sel_next;
    // for 19msec count by 10usec tick
    reg [$clog2(1900)-1:0]
        tick_cnt_reg,
        tick_cnt_next; // 18us 까진 가야 ehla. 18000/10=1800 이니까 안전하게 1900까지 하자.
    reg [5:0]
        bit_cnt_reg, bit_cnt_next;  // 40번(0~39)을 세기 위한 카운터
    reg [39:0]
        data_reg,
        data_next;       // 40비트 데이터를 차곡차곡 모을 시프트 레지스터

    // 40비트 데이터를 8비트씩 의미에 맞게 자르기
    wire [7:0] hum_int = data_reg[39:32];  // 습도 정수
    wire [7:0] hum_dec = data_reg[31:24];  // 습도 소수
    wire [7:0] temp_int = data_reg[23:16];  // 온도 정수
    wire [7:0] temp_dec = data_reg[15:8];  // 온도 소수
    wire [7:0] checksum = data_reg[7:0];  // 체크섬


    // 2-FF Synchronizer for asynchronous dhtio pin input
    reg dhtio_s0, dhtio_s1;
    always @(posedge clk, posedge rst) begin
        if (rst) begin
            dhtio_s0 <= 1'b1;
            dhtio_s1 <= 1'b1;
        end else begin
            dhtio_s0 <= dhtio;
            dhtio_s1 <= dhtio_s0;
        end
    end

    // inout은 무조건 wire를 써야 한다. inout은 mux로 switch 해서 사용한다.
    assign dhtio = (io_sel_reg) ? dhtio_reg : 1'bz;  // 1이면 값이 나가고, 0이면 끊는다.(1'bz)
    assign debug = c_state;
    // 습도 및 온도 출력 (16비트 포트에 연결)
    assign humidity = {hum_int, hum_dec};
    assign temperature = {temp_int, temp_dec};

    assign dht11_done = (c_state == STOP && tick_10u && tick_cnt_reg == 5) ? 1'b1 : 1'b0;
    // 체크섬(오류 검출) 로직: 앞의 4바이트를 더한 값이 마지막 체크섬 바이트와 같아야 정상(Valid)
    assign dht11_valid = ((hum_int + hum_dec + temp_int + temp_dec) == checksum) ? 1'b1 : 1'b0;

    always @(posedge clk, posedge rst) begin
        if (rst) begin
            c_state <= 4'b0000;
            dhtio_reg <= 1'b1;
            tick_cnt_reg <= 0;
            io_sel_reg <= 1'b1;
            bit_cnt_reg <= 0;
            data_reg <= 0;
        end else begin
            c_state <= n_state;
            dhtio_reg <= dhtio_next;
            tick_cnt_reg <= tick_cnt_next;
            io_sel_reg <= io_sel_next;
            bit_cnt_reg <= bit_cnt_next;
            data_reg <= data_next;
        end
    end

    // next, output
    always @(*) begin
        n_state       = c_state;
        tick_cnt_next = tick_cnt_reg;
        dhtio_next    = dhtio_reg;
        io_sel_next   = io_sel_reg;
        bit_cnt_next  = bit_cnt_reg;
        data_next     = data_reg;
        case (c_state)
            IDLE: begin  //0
                if (start) begin
                    n_state = START;
                end
            end
            START: begin  //1
                dhtio_next = 1'b0;
                if (tick_10u) begin
                    tick_cnt_next = tick_cnt_reg + 1;
                    if (tick_cnt_reg == 1900) begin // 18ms 이상 센서를 깨움
                        tick_cnt_next = 0;
                        n_state = WAIT;
                    end
                end
            end
            WAIT: begin  //2
                dhtio_next = 1'b1;
                if (tick_10u) begin
                    tick_cnt_next = tick_cnt_reg + 1;
                    if (tick_cnt_reg == 3) begin  // 20이상 즉 30. 2니까 3으로 하면 된다.
                        // for output to high-z (high-z 상태는 입력을 끊은거다.)
                        n_state = SYNC_L;
                        io_sel_next = 1'b0;
                    end
                end
            end
            SYNC_L: begin  //3
                if (tick_10u) begin
                    if (dhtio_s1 == 1) begin
                        n_state = SYNC_H;
                    end
                end
            end
            SYNC_H: begin  //4
                if (tick_10u) begin
                    if (dhtio_s1 == 0) begin
                        n_state = DATA_SYNC;
                    end
                end
            end
            DATA_SYNC: begin  //5
                if (tick_10u) begin
                    if (dhtio_s1 == 1) begin
                        n_state = DATA_C;
                        tick_cnt_next = 0;
                    end
                end
            end
            DATA_C: begin  //6
                if (tick_10u) begin
                    if (dhtio_s1 == 1) begin
                        // tick count 돌려라.
                        tick_cnt_next = tick_cnt_reg + 1;
                    end else begin
                        if (tick_cnt_reg < 5) begin
                            data_next = {data_reg[38:0], 1'b0};
                        end else begin
                            data_next = {data_reg[38:0], 1'b1};
                        end
                        if (bit_cnt_reg == 39) begin
                            n_state = STOP;
                            bit_cnt_next = 0;
                            tick_cnt_next = 0;
                        end else begin
                            n_state = DATA_SYNC;
                            bit_cnt_next = bit_cnt_reg + 1;
                        end
                    end
                end
            end
            STOP: begin  //7
                if (tick_10u) begin
                    tick_cnt_next = tick_cnt_reg + 1;
                    if (tick_cnt_reg == 5) begin
                        // output mode
                        dhtio_next = 1'b1; // 1로 안 만들어도 가기는 하는데 확실하게 하기 위해.
                        io_sel_next = 1'b1; // 이러면 output모드로 다시 바뀐다.
                        n_state = IDLE;
                    end
                end
            end
        endcase
    end



endmodule



module tick_gen_10u (
    input clk,
    input rst,
    output reg tick_10u
);

    parameter F_COUNT = 100_000_000 / 100_000;
    reg [$clog2(F_COUNT)-1 : 0] counter_reg;

    always @(posedge clk, posedge rst) begin
        if (rst) begin
            counter_reg <= 0;
            tick_10u <= 1'b0;
        end else begin
            counter_reg <= counter_reg + 1;
            if (counter_reg == F_COUNT - 1) begin
                counter_reg <= 0;
                tick_10u <= 1'b1;
            end else begin
                tick_10u <= 1'b0;
            end
        end
    end

endmodule
