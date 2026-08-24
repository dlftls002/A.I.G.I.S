`timescale 1ns/1ps

module fire_servo_controller #(
    parameter int CLK_FREQ     = 100_000_000, // Default: 100 MHz
    parameter int PERIOD_MS    = 20,          // Default: 20 ms
    parameter int PULSE_MIN_US = 650,         // Safe 0 degrees for SG90 (prevents mechanical hard-stop slamming)
    parameter int PULSE_MAX_US = 2350        // Safe 180 degrees for SG90 (prevents mechanical hard-stop slamming)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic servo_en,    // High if temperature >= threshold
    output logic pwm,         // PWM output pin to servo
    output logic servo_state  // Current status of servo (1: active, 0: idle)
);

    localparam int CYCLES_PER_MS  = CLK_FREQ / 1000;
    localparam int CYCLES_PER_US  = CLK_FREQ / 1_000_000;

    localparam int PERIOD_CYCLES    = PERIOD_MS * CYCLES_PER_MS;
    localparam int PULSE_MIN_CYCLES = PULSE_MIN_US * CYCLES_PER_US;
    localparam int PULSE_MAX_CYCLES = PULSE_MAX_US * CYCLES_PER_US;

    // Counter for PWM period
    logic [$clog2(PERIOD_CYCLES)-1:0] cnt_reg;
    
    // PWM width register
    logic [$clog2(PERIOD_CYCLES)-1:0] pulse_width;

    always_comb begin
        if (servo_en) begin
            pulse_width = PULSE_MAX_CYCLES; // 2.0 ms (180 degrees / Open)
        end else begin
            pulse_width = PULSE_MIN_CYCLES; // 1.0 ms (0 degrees / Close)
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_reg     <= 0;
            pwm         <= 1'b0;
            servo_state <= 1'b0;
        end else begin
            if (cnt_reg >= PERIOD_CYCLES - 1) begin
                cnt_reg <= 0;
            end else begin
                cnt_reg <= cnt_reg + 1;
            end

            // PWM signal generation
            if (cnt_reg < pulse_width) begin
                pwm <= 1'b1;
            end else begin
                pwm <= 1'b0;
            end

            // Output state reflects whether servo is enabled (active)
            servo_state <= servo_en;
        end
    end

endmodule
