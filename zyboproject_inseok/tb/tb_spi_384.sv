`timescale 1ns/1ps

module tb_spi_384;
    logic master_clk = 1'b0;
    logic slave_clk  = 1'b0;
    logic master_rst_n = 1'b0;
    logic slave_rst_n  = 1'b0;
    always #4 master_clk = ~master_clk;
    always #5 slave_clk  = ~slave_clk;

    logic start;
    logic [383:0] master_tx;
    logic [383:0] slave_tx;
    wire [383:0] master_rx;
    wire [383:0] slave_rx;
    wire master_busy;
    wire master_done;
    wire master_rx_valid;
    wire slave_rx_valid;
    wire sclk;
    wire cs_n;
    wire mosi;
    wire miso;
    logic master_seen;
    logic slave_seen;
    logic [383:0] captured_master_rx;
    logic [383:0] captured_slave_rx;

    always_ff @(posedge master_clk or negedge master_rst_n) begin
        if (!master_rst_n) begin
            master_seen        <= 1'b0;
            captured_master_rx <= '0;
        end else if (master_rx_valid) begin
            master_seen        <= 1'b1;
            captured_master_rx <= master_rx;
        end
    end

    always_ff @(posedge slave_clk or negedge slave_rst_n) begin
        if (!slave_rst_n) begin
            slave_seen        <= 1'b0;
            captured_slave_rx <= '0;
        end else if (slave_rx_valid) begin
            slave_seen        <= 1'b1;
            captured_slave_rx <= slave_rx;
        end
    end

    spi_master #(
        .DATA_WIDTH(384),
        .CPOL(1'b0),
        .CPHA(1'b0),
        .CLK_DIV(16)
    ) u_master (
        .clk(master_clk), .rst_n(master_rst_n), .start(start),
        .tx_data(master_tx), .busy(master_busy), .done(master_done),
        .rx_data(master_rx), .rx_valid(master_rx_valid),
        .sclk(sclk), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    spi_slave #(
        .DATA_WIDTH(384),
        .CPOL(1'b0),
        .CPHA(1'b0)
    ) u_slave (
        .clk(slave_clk), .rst_n(slave_rst_n),
        .sclk(sclk), .cs_n(cs_n), .mosi(mosi), .miso(miso),
        .rx_data(slave_rx), .rx_valid(slave_rx_valid), .tx_data(slave_tx)
    );

    initial begin
        start = 1'b0;
        master_tx = {
            32'hA55A_0410,
            96'h0011_2233_4455_6677_8899_AABB,
            128'h0123_4567_89AB_CDEF_0011_2233_4455_6677,
            128'hFFEE_DDCC_BBAA_9988_7766_5544_3322_1100
        };
        slave_tx = {
            32'hA55A_0510,
            96'hAABB_CCDD_EEFF_0011_2233_4455,
            128'hFEDC_BA98_7654_3210_FFEF_DFCF_BFAF_9F8F,
            128'h0011_2233_4455_6677_8899_AABB_CCDD_EEFF
        };

        repeat (8) @(posedge master_clk);
        master_rst_n = 1'b1;
        slave_rst_n  = 1'b1;
        repeat (8) @(posedge master_clk);

        start = 1'b1;
        @(posedge master_clk);
        start = 1'b0;

        wait (master_seen && slave_seen);
        if (captured_slave_rx !== master_tx)
            $fatal(1, "384-bit MOSI mismatch\nexp=%h\ngot=%h", master_tx, captured_slave_rx);
        if (captured_master_rx !== slave_tx)
            $fatal(1, "384-bit MISO mismatch\nexp=%h\ngot=%h", slave_tx, captured_master_rx);

        $display("PASS: 384-bit full-duplex SPI transfers both secure frames exactly");
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "384-bit SPI simulation timeout");
    end
endmodule
