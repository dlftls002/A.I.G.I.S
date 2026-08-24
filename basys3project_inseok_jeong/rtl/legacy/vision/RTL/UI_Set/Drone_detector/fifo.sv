module pxc_sync_fifo #(
    //1비트(EOF) + 1비트(적/아군 타입) + 8비트(구역 주소) = 10비트
    parameter int DATA_WIDTH = 10,
    parameter int DEPTH = 64
)(
    input logic clk,
    input logic rst,
    
    input logic wr_en,
    input logic [DATA_WIDTH-1:0] wr_data,
    output logic full,
    
    input logic rd_en,
    output logic [DATA_WIDTH-1:0] rd_data,
    output logic empty
);
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    logic [$clog2(DEPTH)-1:0] wr_ptr;
    logic [$clog2(DEPTH)-1:0] rd_ptr;
    logic [$clog2(DEPTH):0] count;
    
    assign full = (count == DEPTH);
    assign empty = (count == 0);
    assign rd_data = mem[rd_ptr];
    
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count <= 0;
        end else begin
            case ({wr_en && !full, rd_en && !empty})
                2'b10: begin
                    mem[wr_ptr] <= wr_data;
                    wr_ptr <= (wr_ptr + 1) % DEPTH;
                    count <= count + 1;
                end
                2'b01: begin
                    rd_ptr <= (rd_ptr + 1) % DEPTH;
                    count <= count - 1;
                end
                2'b11: begin
                    mem[wr_ptr] <= wr_data;
                    wr_ptr <= (wr_ptr + 1) % DEPTH;
                    rd_ptr <= (rd_ptr + 1) % DEPTH;
                end
                default: ; // Do nothing
            endcase
        end
    end
endmodule
