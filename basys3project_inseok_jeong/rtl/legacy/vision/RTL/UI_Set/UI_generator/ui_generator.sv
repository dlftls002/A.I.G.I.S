`timescale 1ns / 1ps

module ui_generator #(
    parameter int IMG_W = 320,
    parameter int IMG_H = 240
) (
    input logic clk,
    input logic reset,

    // ================================
    // Detector input
    // ================================
    input  logic       det_valid,
    output logic       det_ready,
    input  logic [8:0] det_x,      // center x
    input  logic [7:0] det_y,      // center y
    input  logic [8:0] det_w,
    input  logic [7:0] det_h,
    input  logic       det_type,   // 0: enemy, 1: friend

    // ================================
    // Pixel output to ui_framebuffer
    // ================================
    output logic       pix_valid,
    input  logic       pix_ready,
    output logic [8:0] pix_x,
    output logic [7:0] pix_y,
    output logic       pix_type    // 0: enemy, 1: friend
);

    // ================================
    // detector_input_fifo → box_coord_calc
    // ================================
    logic       fifo_out_valid;
    logic       fifo_out_ready;
    logic [8:0] fifo_out_x;
    logic [7:0] fifo_out_y;
    logic [8:0] fifo_out_w;
    logic [7:0] fifo_out_h;
    logic       fifo_out_type;

    detector_input_fifo U_DETECTOR_INPUT_FIFO (
        .clk  (clk),
        .reset(reset),

        .det_valid(det_valid),
        .det_ready(det_ready),
        .det_x    (det_x),
        .det_y    (det_y),
        .det_w    (det_w),
        .det_h    (det_h),
        .det_type (det_type),

        .out_valid(fifo_out_valid),
        .out_ready(fifo_out_ready),
        .out_x    (fifo_out_x),
        .out_y    (fifo_out_y),
        .out_w    (fifo_out_w),
        .out_h    (fifo_out_h),
        .out_type (fifo_out_type),

        .fifo_full (),
        .fifo_empty()
    );

    // ================================
    // box_coord_calc → instruction_generator
    // ================================
    logic       box_valid;
    logic       box_ready;
    logic [8:0] box_x0;
    logic [7:0] box_y0;
    logic [8:0] box_x1;
    logic [7:0] box_y1;
    logic       box_type;

    box_coord_calc #(
        .IMG_W(IMG_W),
        .IMG_H(IMG_H)
    ) U_BOX_COORD_CALC (
        .clk  (clk),
        .reset(reset),

        .in_valid(fifo_out_valid),
        .in_ready(fifo_out_ready),

        .in_cx  (fifo_out_x),
        .in_cy  (fifo_out_y),
        .in_w   (fifo_out_w),
        .in_h   (fifo_out_h),
        .in_type(fifo_out_type),

        .out_valid(box_valid),
        .out_ready(box_ready),

        .out_x0  (box_x0),
        .out_y0  (box_y0),
        .out_x1  (box_x1),
        .out_y1  (box_y1),
        .out_type(box_type)
    );

    logic       instr_valid;
    logic       instr_ready;
    logic [1:0] instr_op;
    logic [8:0] instr_x_start;
    logic [7:0] instr_y_start;
    logic [8:0] instr_length;
    logic [3:0] instr_dash_on;
    logic [3:0] instr_dash_off;
    logic       instr_type;

    instruction_generator U_INSTRUCTION_GENERATOR (
        .clk  (clk),
        .reset(reset),

        .box_valid(box_valid),
        .box_ready(box_ready),

        .box_x0  (box_x0),
        .box_y0  (box_y0),
        .box_x1  (box_x1),
        .box_y1  (box_y1),
        .box_type(box_type),

        .instr_valid   (instr_valid),
        .instr_ready   (instr_ready),
        .instr_op      (instr_op),
        .instr_x_start (instr_x_start),
        .instr_y_start (instr_y_start),
        .instr_length  (instr_length),
        .instr_dash_on (instr_dash_on),
        .instr_dash_off(instr_dash_off),
        .instr_type    (instr_type)
    );

    pixel_render #(
        .IMG_W(IMG_W),
        .IMG_H(IMG_H)
    ) U_PIXEL_RENDER (
        .clk  (clk),
        .reset(reset),

        .instr_valid   (instr_valid),
        .instr_ready   (instr_ready),
        .instr_op      (instr_op),
        .instr_x_start (instr_x_start),
        .instr_y_start (instr_y_start),
        .instr_length  (instr_length),
        .instr_dash_on (instr_dash_on),
        .instr_dash_off(instr_dash_off),
        .instr_type    (instr_type),

        .pix_valid(pix_valid),
        .pix_ready(pix_ready),
        .pix_x    (pix_x),
        .pix_y    (pix_y),
        .pix_type (pix_type)
    );

endmodule
