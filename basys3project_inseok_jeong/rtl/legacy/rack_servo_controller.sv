// `timescale 1ns / 1ps

// /*
//  * 일반적인 RC 서보모터용 PWM 발생 모듈
//  *
//  * PWM 주파수:
//  *   50 Hz, 주기 20 ms
//  *
//  * CLOSE:
//  *   약 1.0 ms 동안 HIGH
//  *
//  * OPEN:
//  *   약 2.0 ms 동안 HIGH
//  *
//  * 실제 각도는 서보모터 종류와 기구 구조에 따라 달라질 수 있으므로
//  * CLOSE_PULSE_US와 OPEN_PULSE_US를 조절할 수 있다.
//  */
// module rack_servo_controller #(
//     parameter integer CLOCK_FREQ_HZ  = 100_000_000,
//     parameter integer PWM_FREQ_HZ    = 50,
//     parameter integer CLOSE_PULSE_US = 1000,
//     parameter integer OPEN_PULSE_US  = 2000
// ) (
//     input  logic clk,
//     input  logic rst_n,

//     // 0 = CLOSE 위치
//     // 1 = OPEN 위치
//     input  logic open_cmd,

//     // 서보모터 제어용 PWM
//     output logic servo_pwm
// );

//     // 20 ms PWM 주기에 필요한 클럭 수
//     localparam integer PERIOD_COUNT =
//         CLOCK_FREQ_HZ / PWM_FREQ_HZ;

//     // 1.0 ms HIGH에 필요한 클럭 수
//     localparam integer CLOSE_COUNT =
//         (CLOCK_FREQ_HZ / 1_000_000) * CLOSE_PULSE_US;

//     // 2.0 ms HIGH에 필요한 클럭 수
//     localparam integer OPEN_COUNT =
//         (CLOCK_FREQ_HZ / 1_000_000) * OPEN_PULSE_US;

//     // PWM 주기 카운터
//     integer period_counter;

//     // 현재 사용할 HIGH 구간 길이
//     integer pulse_count;


//     // OPEN/CLOSE 명령에 따라 펄스 폭 선택
//     always_comb begin
//         if (open_cmd)
//             pulse_count = OPEN_COUNT;
//         else
//             pulse_count = CLOSE_COUNT;
//     end


//     // 0부터 PERIOD_COUNT-1까지 반복
//     always_ff @(posedge clk or negedge rst_n) begin
//         if (!rst_n) begin
//             period_counter <= 0;
//         end else begin
//             if (period_counter >= PERIOD_COUNT - 1)
//                 period_counter <= 0;
//             else
//                 period_counter <= period_counter + 1;
//         end
//     end


//     // 선택된 펄스 폭 동안 PWM을 HIGH로 출력
//     always_comb begin
//         if (!rst_n)
//             servo_pwm = 1'b0;
//         else if (period_counter < pulse_count)
//             servo_pwm = 1'b1;
//         else
//             servo_pwm = 1'b0;
//     end

// endmodule








`timescale 1ns / 1ps

/*
 * 일반적인 RC 서보모터용 PWM 발생 모듈
 *
 * PWM 주파수:
 *   50 Hz, 주기 20 ms
 *
 * CLOSE:
 *   약 1.0 ms 동안 HIGH
 *
 * OPEN:
 *   약 2.0 ms 동안 HIGH
 *
 * 실제 각도는 서보모터 종류와 기구 구조에 따라 달라질 수 있으므로
 * CLOSE_PULSE_US와 OPEN_PULSE_US를 조절할 수 있다.
 */
module rack_servo_controller #(
    parameter integer CLOCK_FREQ_HZ  = 100_000_000,
    parameter integer PWM_FREQ_HZ    = 50,
    parameter integer CLOSE_PULSE_US = 1000,
    parameter integer OPEN_PULSE_US  = 2000
) (
    input  logic clk,
    input  logic rst_n,

    // 0 = CLOSE 위치
    // 1 = OPEN 위치
    input  logic open_cmd,

    // 서보모터 제어용 PWM
    output logic servo_pwm
);

    // 20 ms PWM 주기에 필요한 클럭 수
    localparam integer PERIOD_COUNT =
        CLOCK_FREQ_HZ / PWM_FREQ_HZ;

    // 1.0 ms HIGH에 필요한 클럭 수
    localparam integer CLOSE_COUNT =
        (CLOCK_FREQ_HZ / 1_000_000) * CLOSE_PULSE_US;

    // 2.0 ms HIGH에 필요한 클럭 수
    localparam integer OPEN_COUNT =
        (CLOCK_FREQ_HZ / 1_000_000) * OPEN_PULSE_US;

    // PWM 주기 카운터
    integer period_counter;

    // 현재 사용할 HIGH 구간 길이
    integer pulse_count;


    // OPEN/CLOSE 명령에 따라 펄스 폭 선택
    always_comb begin
        if (open_cmd)
            pulse_count = CLOSE_COUNT;
        else
            pulse_count = OPEN_COUNT;
    end


    // 0부터 PERIOD_COUNT-1까지 반복
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            period_counter <= 0;
        end else begin
            if (period_counter >= PERIOD_COUNT - 1)
                period_counter <= 0;
            else
                period_counter <= period_counter + 1;
        end
    end


    // 선택된 펄스 폭 동안 PWM을 HIGH로 출력
    always_comb begin
        if (!rst_n)
            servo_pwm = 1'b0;
        else if (period_counter < pulse_count)
            servo_pwm = 1'b1;
        else
            servo_pwm = 1'b0;
    end

endmodule
