// Brendan Lynskey 2025
// Testbench for Page Table Walker

`timescale 1ns/1ps

module tb_page_table_walker;

    import mmu_pkg::*;

    logic        clk, srst;
    logic        start;
    logic [31:0] vaddr;
    logic [31:0] satp;

    logic        done, fault;
    logic [PPN_W-1:0] result_ppn;
    logic        result_d, result_a, result_u, result_x, result_w, result_r, result_g;
    logic        result_is_megapage;

    logic        mem_req_valid, mem_req_ready;
    logic [31:0] mem_req_addr;
    logic        mem_resp_valid;
    logic [31:0] mem_resp_data;

    page_table_walker dut (
        .clk             (clk),
        .srst            (srst),
        .start           (start),
        .vaddr           (vaddr),
        .satp            (satp),
        .done            (done),
        .fault           (fault),
        .result_ppn      (result_ppn),
        .result_d        (result_d),
        .result_a        (result_a),
        .result_u        (result_u),
        .result_x        (result_x),
        .result_w        (result_w),
        .result_r        (result_r),
        .result_g        (result_g),
        .result_is_megapage (result_is_megapage),
        .mem_req_valid   (mem_req_valid),
        .mem_req_ready   (mem_req_ready),
        .mem_req_addr    (mem_req_addr),
        .mem_resp_valid  (mem_resp_valid),
        .mem_resp_data   (mem_resp_data)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    int pass_count = 0;
    int fail_count = 0;
    int test_num   = 0;

    // Simple memory model — 64K words
    logic [31:0] mem [0:65535];

    task automatic run_cycles(int n);
        repeat (n) @(posedge clk);
    endtask

    // Memory responder — single-cycle response on request
    always_ff @(posedge clk) begin
        if (srst) begin
            mem_req_ready  <= 1'b0;
            mem_resp_valid <= 1'b0;
            mem_resp_data  <= '0;
        end else begin
            mem_req_ready  <= 1'b1;  // Always ready
            mem_resp_valid <= 1'b0;
            if (mem_req_valid && mem_req_ready) begin
                mem_resp_valid <= 1'b1;
                mem_resp_data  <= mem[mem_req_addr[17:2]];  // Word-aligned index
            end
        end
    end

    // Build a PTE word
    function automatic logic [31:0] make_pte(
        input logic [21:0] ppn,
        input logic d, a, g, u, x, w, r, v
    );
        return {ppn, 2'b00, d, a, g, u, x, w, r, v};
    endfunction

    task automatic start_walk(input logic [31:0] va, input logic [31:0] s);
        vaddr = va;
        satp  = s;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
    endtask

    task automatic wait_done();
        while (!done) @(posedge clk);
    endtask

    task automatic check_result(
        input logic exp_fault,
        input logic [PPN_W-1:0] exp_ppn,
        input logic exp_mega,
        input string name
    );
        test_num++;
        if (fault === exp_fault &&
            (exp_fault || (result_ppn === exp_ppn && result_is_megapage === exp_mega))) begin
            $display("[PASS] Test %0d: %s", test_num, name);
            pass_count++;
        end else begin
            $display("[FAIL] Test %0d: %s — fault=%0b (exp %0b), ppn=0x%06x (exp 0x%06x), mega=%0b (exp %0b)",
                     test_num, name, fault, exp_fault, result_ppn, exp_ppn, result_is_megapage, exp_mega);
            fail_count++;
        end
    endtask

    // Page table setup constants
    // Root page table at physical page 0x00100 (address 0x00100000)
    localparam logic [21:0] ROOT_PPN = 22'h00100;
    // satp: MODE=1 (Sv32), ASID=0, PPN=ROOT_PPN
    localparam logic [31:0] SATP_VAL = {1'b1, 9'b0, ROOT_PPN};

    initial begin
        srst  = 1'b1;
        start = 1'b0;
        vaddr = '0;
        satp  = '0;

        // Clear memory
        for (int i = 0; i < 65536; i++) mem[i] = '0;

        run_cycles(3);
        srst = 1'b0;
        run_cycles(2);

        // ================================================================
        // Setup page tables in memory
        // Root PT at 0x00100_000 (word index: 0x00100_000 >> 2 = 0x40000)
        // But our memory is only 64K words (256KB), so use smaller addresses.
        // Root PT at ppn=0x00010 -> byte addr 0x00010_000 -> word addr 0x4000
        // ================================================================

        // Reconfigure with smaller addresses
        // Root PT at PPN=0x10 -> base addr = 0x10 * 4096 = 0x10000 -> word idx = 0x4000
        // L0 PT at PPN=0x20 -> base addr = 0x20 * 4096 = 0x20000 -> word idx = 0x8000

        // ---- Test 1: Successful 2-level walk ----
        // Virtual address: VPN1=0x001, VPN0=0x002, offset=0x345
        // L1 PTE at root + VPN1*4 = 0x10000 + 0x001*4 = 0x10004 -> word idx 0x4001
        // L1 PTE: non-leaf, points to L0 PT at PPN=0x20
        mem[16'h4001] = make_pte(22'h00020, 0, 0, 0, 0, 0, 0, 0, 1); // V=1, non-leaf (no R/W/X)

        // L0 PTE at 0x20000 + VPN0*4 = 0x20000 + 0x002*4 = 0x20008 -> word idx 0x8002
        // L0 PTE: leaf, PPN=0x30, R+W+A+D+U
        mem[16'h8002] = make_pte(22'h00030, 1, 1, 0, 1, 0, 1, 1, 1); // D,A,U,W,R,V

        start_walk({10'h001, 10'h002, 12'h345}, {1'b1, 9'b0, 22'h00010});
        wait_done();
        check_result(1'b0, 22'h00030, 1'b0, "Successful 2-level walk");

        run_cycles(2);

        // ---- Test 2: Megapage leaf at L1 ----
        // VPN1=0x002, L1 PTE is a leaf (megapage)
        // L1 PTE at 0x10000 + 0x002*4 = 0x10008 -> word idx 0x4002
        // Megapage: PPN[9:0] must be 0 for alignment
        mem[16'h4002] = make_pte(22'h3FC00, 1, 1, 0, 1, 0, 0, 1, 1); // PPN=0x3FC00 (aligned), R+A+D+U+V

        start_walk({10'h002, 10'h123, 12'h456}, {1'b1, 9'b0, 22'h00010});
        wait_done();
        check_result(1'b0, 22'h3FC00, 1'b1, "Megapage leaf at L1");

        run_cycles(2);

        // ---- Test 3: Invalid PTE at L1 (V=0) ----
        // VPN1=0x003, L1 PTE has V=0
        mem[16'h4003] = make_pte(22'h00040, 0, 0, 0, 0, 0, 0, 0, 0); // V=0

        start_walk({10'h003, 10'h000, 12'h000}, {1'b1, 9'b0, 22'h00010});
        wait_done();
        check_result(1'b1, '0, 1'b0, "Invalid PTE at L1 (V=0)");

        run_cycles(2);

        // ---- Test 4: Invalid PTE at L0 (V=0) ----
        // VPN1=0x004, L1 PTE valid non-leaf pointing to L0 at PPN=0x21
        mem[16'h4004] = make_pte(22'h00021, 0, 0, 0, 0, 0, 0, 0, 1); // V=1, non-leaf
        // L0 PTE at 0x21000 + VPN0*4 = 0x21000 + 0x005*4 = 0x21014 -> word idx 0x8405
        // VPN0=0x005
        mem[16'h8405] = make_pte(22'h00050, 0, 0, 0, 0, 0, 0, 0, 0); // V=0

        start_walk({10'h004, 10'h005, 12'h000}, {1'b1, 9'b0, 22'h00010});
        wait_done();
        check_result(1'b1, '0, 1'b0, "Invalid PTE at L0 (V=0)");

        run_cycles(2);

        // ---- Test 5: Reserved encoding W=1, R=0 at L1 ----
        mem[16'h4005] = make_pte(22'h00060, 1, 1, 0, 0, 0, 1, 0, 1); // W=1, R=0, V=1

        start_walk({10'h005, 10'h000, 12'h000}, {1'b1, 9'b0, 22'h00010});
        wait_done();
        check_result(1'b1, '0, 1'b0, "Reserved PTE encoding (W=1 R=0) at L1");

        run_cycles(2);

        // ---- Test 6: Misaligned megapage ----
        // L1 leaf with PPN[9:0] != 0
        mem[16'h4006] = make_pte(22'h3FC01, 1, 1, 0, 1, 0, 0, 1, 1); // PPN[0]=1, misaligned

        start_walk({10'h006, 10'h000, 12'h000}, {1'b1, 9'b0, 22'h00010});
        wait_done();
        check_result(1'b1, '0, 1'b0, "Misaligned megapage (PPN[9:0]!=0)");

        run_cycles(2);

        // ---- Test 7: L0 non-leaf (pointer at L0 is invalid in Sv32) ----
        mem[16'h4007] = make_pte(22'h00022, 0, 0, 0, 0, 0, 0, 0, 1); // L1 non-leaf -> PPN=0x22
        // L0 PTE at PPN=0x22, VPN0=0
        // word addr = 0x22000 >> 2 = 0x8800
        mem[16'h8800] = make_pte(22'h00070, 0, 0, 0, 0, 0, 0, 0, 1); // V=1 but non-leaf (no R/W/X)

        start_walk({10'h007, 10'h000, 12'h000}, {1'b1, 9'b0, 22'h00010});
        wait_done();
        check_result(1'b1, '0, 1'b0, "L0 non-leaf PTE — fault");

        run_cycles(2);

        // ---- Test 8: Reserved encoding W=1, R=0 at L0 ----
        mem[16'h4008] = make_pte(22'h00023, 0, 0, 0, 0, 0, 0, 0, 1); // L1 non-leaf -> PPN=0x23
        // L0 at PPN=0x23, VPN0=0
        // word addr = 0x23000 >> 2 = 0x8C00
        mem[16'h8C00] = make_pte(22'h00080, 1, 1, 0, 0, 0, 1, 0, 1); // W=1,R=0 — invalid

        start_walk({10'h008, 10'h000, 12'h000}, {1'b1, 9'b0, 22'h00010});
        wait_done();
        check_result(1'b1, '0, 1'b0, "Reserved PTE encoding (W=1 R=0) at L0");

        run_cycles(2);

        // ---- Test 9: Walk with different VPN — verifies address calculation ----
        // VPN1=0x000, VPN0=0x000 — simplest case
        mem[16'h4000] = make_pte(22'h00024, 0, 0, 0, 0, 0, 0, 0, 1); // L1 non-leaf -> PPN=0x24
        // L0 at PPN=0x24, VPN0=0x000
        // word addr = 0x24000 >> 2 = 0x9000
        mem[16'h9000] = make_pte(22'h000AA, 1, 1, 0, 1, 1, 0, 1, 1); // RXU leaf

        start_walk({10'h000, 10'h000, 12'hFFF}, {1'b1, 9'b0, 22'h00010});
        wait_done();
        check_result(1'b0, 22'h000AA, 1'b0, "Walk VPN1=0 VPN0=0 — valid leaf");

        run_cycles(2);

        // ---- Test 10: Verify PTE permission bits are forwarded ----
        // Use a leaf with specific permission combo: R=1, W=0, X=1, U=0, D=0, A=1, G=1
        mem[16'h4009] = make_pte(22'h00025, 0, 0, 0, 0, 0, 0, 0, 1); // L1 non-leaf
        // L0 at PPN=0x25, VPN0=0x000
        mem[16'h9400] = make_pte(22'h00FFF, 0, 1, 1, 0, 1, 0, 1, 1); // D=0,A=1,G=1,X=1,R=1,V=1

        start_walk({10'h009, 10'h000, 12'h000}, {1'b1, 9'b0, 22'h00010});
        wait_done();

        test_num++;
        if (!fault && result_ppn == 22'h00FFF &&
            result_r == 1'b1 && result_w == 1'b0 && result_x == 1'b1 &&
            result_u == 1'b0 && result_d == 1'b0 && result_a == 1'b1 && result_g == 1'b1) begin
            $display("[PASS] Test %0d: PTE permission bits forwarded correctly", test_num);
            pass_count++;
        end else begin
            $display("[FAIL] Test %0d: PTE permission bits — R=%0b W=%0b X=%0b U=%0b D=%0b A=%0b G=%0b",
                     test_num, result_r, result_w, result_x, result_u, result_d, result_a, result_g);
            fail_count++;
        end

        run_cycles(2);

        // ---- Test 11: Megapage with G (global) bit ----
        mem[16'h400A] = make_pte(22'h3F800, 1, 1, 1, 1, 1, 1, 1, 1); // All bits set, PPN aligned

        start_walk({10'h00A, 10'h3FF, 12'h000}, {1'b1, 9'b0, 22'h00010});
        wait_done();

        test_num++;
        if (!fault && result_is_megapage && result_g) begin
            $display("[PASS] Test %0d: Megapage with global bit", test_num);
            pass_count++;
        end else begin
            $display("[FAIL] Test %0d: Megapage global — fault=%0b mega=%0b g=%0b",
                     test_num, fault, result_is_megapage, result_g);
            fail_count++;
        end

        // ================================================================
        // Summary
        $display("");
        if (fail_count == 0)
            $display("All %0d tests passed", pass_count);
        else
            $display("%0d of %0d tests FAILED", fail_count, pass_count + fail_count);
        $finish;
    end

endmodule
