module framebuffer (
    // Write Side
    input  logic                       wclk,
    input  logic                       we,
    input  logic [$clog2(320*240)-1:0] wAddr,
    input  logic [               15:0] wData,
    // Read Side
    input  logic                       rclk,
    input  logic [$clog2(320*240)-1:0] rAddr,
    output logic [               15:0] rData
);
    logic [15:0] mem [0:(320*240)-1];

    // Write Side
    always_ff @(posedge wclk) begin
        if (we) mem[wAddr] <= wData;
    end

    // Read Side
    always_ff @(posedge rclk) begin
        rData <= mem[rAddr];
    end

endmodule
