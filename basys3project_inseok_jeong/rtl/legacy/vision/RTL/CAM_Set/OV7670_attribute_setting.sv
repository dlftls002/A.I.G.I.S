`timescale 1ns / 1ps

module OV7670_attribute_setting #(
    parameter CLK_FREQ = 100_000_000
) (
    input  logic clk,
    input  logic reset,
    
    // SCCB 
    output logic scl,
    inout  logic sda
);

    logic       valid;
    logic       ready;
    logic [7:0] reg_addr;
    logic [7:0] reg_data;

    OV7670_Controller #(
        .CLK_FREQ   (CLK_FREQ)
    ) U_OV7670_Controller (
        .clk        (clk),
        .reset      (reset),
        .ready      (ready),
        .valid      (valid),
        .reg_addr   (reg_addr),
        .reg_data   (reg_data),
        .init_done  (init_done)
    );
    
    sccb_master U_SCCB_MASTER (
        .clk        (clk),
        .reset      (reset),
        .valid      (valid),
        .rw         (1'b1),
        .in_addr    (reg_addr),
        .w_data     (reg_data),
        .ready      (ready),
        .scl        (scl),
        .sda        (sda)
    );

endmodule
