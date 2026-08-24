`timescale 1ns / 1ps

module OV7670MemController(
    input  logic                       pclk,
    input  logic                       reset,
    // ov7670 side
    input  logic                       href,
    input  logic                       vsync,
    input  logic [                7:0] pdata,
    // framebuffer side
    output logic                       we,
    output logic [$clog2(320*240)-1:0] wAddr,
    output logic [               15:0] wData
);
    logic [15:0] pixelData;
    logic        pixelEvenOdd;
    logic [$clog2(320*240)-1:0] nextAddr;

    assign wData = pixelData;

    // Synchronous reset keeps BRAM address/control paths timing-safe.
    always_ff @(posedge pclk) begin
        if (reset) begin
            wAddr        <= 0;
            nextAddr     <= 0;
            pixelData    <= 0;
            pixelEvenOdd <= 1'b0;
            we           <= 1'b0;
        end
        else begin
            if (href) begin
                if (pixelEvenOdd == 1'b0) begin
                    we              <= 1'b0;
                    pixelData[15:8] <= pdata;
                    pixelEvenOdd    <= ~pixelEvenOdd;
                end
                else begin
                    we             <= 1'b1;
                    pixelData[7:0] <= pdata;
                    pixelEvenOdd   <= ~pixelEvenOdd;
                    // Publish the completed pixel at the current address.
                    // The separate next-address counter keeps the first
                    // valid camera pixel at address 0 for frame detection.
                    wAddr          <= nextAddr;
                    if (nextAddr == 17'd76799)
                        nextAddr <= 0;
                    else
                        nextAddr <= nextAddr + 1'b1;
                end
            end
            else begin
                we           <= 1'b0;
                pixelData    <= 0;
                pixelEvenOdd <= 1'b0;
            end
            if (vsync) begin
                wAddr        <= 0;
                nextAddr     <= 0;
                pixelData    <= 0;
                pixelEvenOdd <= 1'b0;
                we           <= 1'b0;
            end
        end
    end
endmodule
