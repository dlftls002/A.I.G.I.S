package aes_pkg;
    localparam int AES_BLOCK_BITS = 128;
    localparam int AES_KEY_BITS   = 128;
    localparam int AES_ROUNDS     = 10;

    // Tables are ordered from input 8'h00 (leftmost byte) to 8'hff.
    localparam logic [2047:0] SBOX_TABLE = {
        128'h637c777bf26b6fc53001672bfed7ab76,
        128'hca82c97dfa5947f0add4a2af9ca472c0,
        128'hb7fd9326363ff7cc34a5e5f171d83115,
        128'h04c723c31896059a071280e2eb27b275,
        128'h09832c1a1b6e5aa0523bd6b329e32f84,
        128'h53d100ed20fcb15b6acbbe394a4c58cf,
        128'hd0efaafb434d338545f9027f503c9fa8,
        128'h51a3408f929d38f5bcb6da2110fff3d2,
        128'hcd0c13ec5f974417c4a77e3d645d1973,
        128'h60814fdc222a908846eeb814de5e0bdb,
        128'he0323a0a4906245cc2d3ac629195e479,
        128'he7c8376d8dd54ea96c56f4ea657aae08,
        128'hba78252e1ca6b4c6e8dd741f4bbd8b8a,
        128'h703eb5664803f60e613557b986c11d9e,
        128'he1f8981169d98e949b1e87e9ce5528df,
        128'h8ca1890dbfe6426841992d0fb054bb16
    };

    localparam logic [2047:0] INV_SBOX_TABLE = {
        128'h52096ad53036a538bf40a39e81f3d7fb,
        128'h7ce339829b2fff87348e4344c4dee9cb,
        128'h547b9432a6c2233dee4c950b42fac34e,
        128'h082ea16628d924b2765ba2496d8bd125,
        128'h72f8f66486689816d4a45ccc5d65b692,
        128'h6c704850fdedb9da5e154657a78d9d84,
        128'h90d8ab008cbcd30af7e45805b8b34506,
        128'hd02c1e8fca3f0f02c1afbd0301138a6b,
        128'h3a9111414f67dcea97f2cfcef0b4e673,
        128'h96ac7422e7ad3585e2f937e81c75df6e,
        128'h47f11a711d29c5896fb7620eaa18be1b,
        128'hfc563e4bc6d279209adbc0fe78cd5af4,
        128'h1fdda8338807c731b11210592780ec5f,
        128'h60517fa919b54a0d2de57a9f93c99cef,
        128'ha0e03b4dae2af5b0c8ebbb3c83539961,
        128'h172b047eba77d626e169146355210c7d
    };

    function automatic logic [7:0] sbox(input logic [7:0] value);
        sbox = SBOX_TABLE[2047-(value*8) -: 8];
    endfunction

    function automatic logic [7:0] inv_sbox(input logic [7:0] value);
        inv_sbox = INV_SBOX_TABLE[2047-(value*8) -: 8];
    endfunction

    function automatic logic [7:0] xtime(input logic [7:0] value);
        xtime = {value[6:0], 1'b0} ^ (8'h1b & {8{value[7]}});
    endfunction

    function automatic logic [7:0] gf_mul(
        input logic [7:0] a,
        input logic [7:0] b
    );
        logic [7:0] aa;
        logic [7:0] bb;
        logic [7:0] product;
        integer i;
        begin
            aa = a;
            bb = b;
            product = 8'h00;
            for (i = 0; i < 8; i = i + 1) begin
                if (bb[0])
                    product = product ^ aa;
                aa = xtime(aa);
                bb = bb >> 1;
            end
            gf_mul = product;
        end
    endfunction

    function automatic logic [7:0] rcon(input integer round_number);
        begin
            case (round_number)
                1:  rcon = 8'h01;
                2:  rcon = 8'h02;
                3:  rcon = 8'h04;
                4:  rcon = 8'h08;
                5:  rcon = 8'h10;
                6:  rcon = 8'h20;
                7:  rcon = 8'h40;
                8:  rcon = 8'h80;
                9:  rcon = 8'h1b;
                10: rcon = 8'h36;
                default: rcon = 8'h00;
            endcase
        end
    endfunction

    function automatic logic [31:0] rot_word(input logic [31:0] word_in);
        rot_word = {word_in[23:0], word_in[31:24]};
    endfunction

    function automatic logic [31:0] sub_word(input logic [31:0] word_in);
        sub_word = {
            sbox(word_in[31:24]), sbox(word_in[23:16]),
            sbox(word_in[15:8]),  sbox(word_in[7:0])
        };
    endfunction

    function automatic logic [127:0] next_round_key(
        input logic [127:0] previous_key,
        input integer round_number
    );
        logic [31:0] w0, w1, w2, w3;
        logic [31:0] n0, n1, n2, n3;
        logic [31:0] temp;
        begin
            w0 = previous_key[127:96];
            w1 = previous_key[95:64];
            w2 = previous_key[63:32];
            w3 = previous_key[31:0];
            temp = sub_word(rot_word(w3)) ^ {rcon(round_number), 24'h000000};
            n0 = w0 ^ temp;
            n1 = w1 ^ n0;
            n2 = w2 ^ n1;
            n3 = w3 ^ n2;
            next_round_key = {n0, n1, n2, n3};
        end
    endfunction
endpackage
