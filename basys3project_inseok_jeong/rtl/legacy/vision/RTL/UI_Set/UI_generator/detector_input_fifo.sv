`timescale 1ns / 1ps

module detector_input_fifo #(
    parameter int DEPTH = 16
) (
    input  logic       clk,
    input  logic       reset,

    // from Drone Detector
    input  logic       det_valid,
    output logic       det_ready,

    input  logic [8:0] det_x,
    input  logic [7:0] det_y,
    input  logic [8:0] det_w,
    input  logic [7:0] det_h,
    input  logic       det_type,   // 0: enemy, 1: friend

    // to coordinate calculator
    output logic       out_valid,
    input  logic       out_ready,

    output logic [8:0] out_x,
    output logic [7:0] out_y,
    output logic [8:0] out_w,
    output logic [7:0] out_h,
    output logic       out_type,
    
    // fifo
    output logic       fifo_full,
    output logic       fifo_empty
);

    localparam int DATA_W = 35;

    logic [DATA_W-1:0] fifo_wdata;
    logic [DATA_W-1:0] fifo_rdata;

    logic fifo_wr_en;
    logic fifo_rd_en;

    // 입력 데이터 (위치, 크기, 종류) 35비트 하나로 pack
    assign fifo_wdata = {
        det_x,      // [34:26]
        det_y,      // [25:18]
        det_w,      // [17:9]
        det_h,      // [8:1]
        det_type    // [0]
    };

    // FIFO에 묶여 있던 35비트 unpack
    assign {
        out_x,
        out_y,
        out_w,
        out_h,
        out_type
    } = fifo_rdata;
    
    // ready-valid handshake
    assign out_valid = !fifo_empty;

    assign fifo_rd_en = out_valid && out_ready;

    assign det_ready = !fifo_full || fifo_rd_en;

    assign fifo_wr_en = det_valid && det_ready;

    sync_fifo #(
        .DATA_WIDTH(DATA_W),
        .DEPTH     (DEPTH)
    ) U_SYNC_FIFO (
        .clk    (clk),
        .reset  (reset),
        .wr_en  (fifo_wr_en),
        .wr_data(fifo_wdata),
        .rd_en  (fifo_rd_en),
        .rd_data(fifo_rdata),
        .full   (fifo_full),
        .empty  (fifo_empty)
    );

endmodule



module sync_fifo #(
    parameter int DATA_WIDTH = 35,
    parameter int DEPTH      = 16,
    parameter int ADDR_WIDTH = $clog2(DEPTH)
) (
    input  logic                  clk,
    input  logic                  reset,

    input  logic                  wr_en,
    input  logic [DATA_WIDTH-1:0] wr_data,

    input  logic                  rd_en,
    output logic [DATA_WIDTH-1:0] rd_data,

    output logic                  full,
    output logic                  empty
);

    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    logic [ADDR_WIDTH-1:0] wr_ptr; // 다음 데이터 저장할 주소
    logic [ADDR_WIDTH-1:0] rd_ptr; // 다음 데이터 꺼낼 주소
    logic [ADDR_WIDTH:0]   count;  // 현재 FIFO 안에 저장된 데이터 개수

    logic do_write;
    logic do_read;

    assign full  = (count == DEPTH);
    assign empty = (count == 0);

    // first-word fall-through style read
    assign rd_data = mem[rd_ptr];

    assign do_read  = rd_en && !empty;

    // full이어도 동시에 read가 일어나면 write 가능
    assign do_write = wr_en && (!full || do_read);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            case ({do_write, do_read})
                // write only
                2'b10: begin
                    mem[wr_ptr] <= wr_data;
                    wr_ptr      <= wr_ptr + 1'b1;
                    count       <= count + 1'b1;
                end
                // read only
                2'b01: begin
                    rd_ptr <= rd_ptr + 1'b1;
                    count  <= count - 1'b1;
                end
                // write&read
                2'b11: begin
                    mem[wr_ptr] <= wr_data;
                    wr_ptr      <= wr_ptr + 1'b1;
                    rd_ptr      <= rd_ptr + 1'b1;
                    count       <= count;
                end
                default: begin
                    count <= count;
                end
            endcase
        end
    end

endmodule