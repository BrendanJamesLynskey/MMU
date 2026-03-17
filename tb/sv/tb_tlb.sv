// Brendan Lynskey 2025
// Testbench for TLB

`timescale 1ns/1ps

module tb_tlb;

    import mmu_pkg::*;

    localparam int NUM_ENTRIES = 4;  // Small for easier verification

    logic                clk, srst;

    // Lookup
    logic [VPN_W-1:0]    lookup_vpn;
    logic [ASID_W-1:0]   lookup_asid;
    logic                lookup_hit;
    logic [PPN_W-1:0]    lookup_ppn;
    logic                lookup_d, lookup_a, lookup_u, lookup_x, lookup_w, lookup_r;
    logic                lookup_is_megapage;

    // Write
    logic                write_valid;
    logic [ASID_W-1:0]   write_asid;
    logic [VPN_W-1:0]    write_vpn;
    logic [PPN_W-1:0]    write_ppn;
    logic                write_d, write_a, write_u, write_x, write_w, write_r, write_g;
    logic                write_is_megapage;

    // Flush
    logic                sfence_valid;
    logic [31:0]         sfence_vaddr;
    logic [ASID_W-1:0]   sfence_asid;

    tlb #(.NUM_ENTRIES(NUM_ENTRIES)) dut (.*);

    initial clk = 0;
    always #5 clk = ~clk;

    int pass_count = 0;
    int fail_count = 0;
    int test_num   = 0;

    task automatic run_cycles(int n);
        repeat (n) @(posedge clk);
    endtask

    task automatic clear_inputs();
        write_valid   = 0;
        sfence_valid  = 0;
        lookup_vpn    = '0;
        lookup_asid   = '0;
        write_asid    = '0;
        write_vpn     = '0;
        write_ppn     = '0;
        write_d       = 0; write_a = 0; write_u = 0;
        write_x       = 0; write_w = 0; write_r = 0;
        write_g       = 0; write_is_megapage = 0;
        sfence_vaddr  = '0;
        sfence_asid   = '0;
    endtask

    task automatic insert_entry(
        input logic [ASID_W-1:0] asid,
        input logic [VPN_W-1:0]  vpn,
        input logic [PPN_W-1:0]  ppn,
        input logic              is_mega,
        input logic              g
    );
        @(posedge clk);
        write_valid       <= 1'b1;
        write_asid        <= asid;
        write_vpn         <= vpn;
        write_ppn         <= ppn;
        write_r           <= 1'b1;
        write_a           <= 1'b1;
        write_u           <= 1'b1;
        write_d           <= 1'b1;
        write_x           <= 1'b0;
        write_w           <= 1'b1;
        write_g           <= g;
        write_is_megapage <= is_mega;
        @(posedge clk);
        write_valid <= 1'b0;
    endtask

    task automatic do_lookup(
        input logic [ASID_W-1:0] asid,
        input logic [VPN_W-1:0]  vpn
    );
        lookup_asid = asid;
        lookup_vpn  = vpn;
        #1; // combinational settle
    endtask

    task automatic check_hit(input logic exp_hit, input logic [PPN_W-1:0] exp_ppn, input string name);
        test_num++;
        if (lookup_hit === exp_hit && (!exp_hit || lookup_ppn === exp_ppn)) begin
            $display("[PASS] Test %0d: %s", test_num, name);
            pass_count++;
        end else begin
            $display("[FAIL] Test %0d: %s — hit=%0b (exp %0b), ppn=0x%05x (exp 0x%05x)",
                     test_num, name, lookup_hit, exp_hit, lookup_ppn, exp_ppn);
            fail_count++;
        end
    endtask

    task automatic check_miss(input string name);
        test_num++;
        if (lookup_hit === 1'b0) begin
            $display("[PASS] Test %0d: %s", test_num, name);
            pass_count++;
        end else begin
            $display("[FAIL] Test %0d: %s — hit=%0b (expected miss)", test_num, name, lookup_hit);
            fail_count++;
        end
    endtask

    initial begin
        srst = 1'b1;
        clear_inputs();
        run_cycles(3);
        srst = 1'b0;
        run_cycles(1);

        // ============================================================
        // Test 1: Lookup miss on empty TLB
        do_lookup(9'd1, 20'hABCDE);
        check_miss("Lookup miss on empty TLB");

        // ============================================================
        // Test 2: Insert and hit
        insert_entry(9'd1, 20'h12345, 22'h3ABCD, 1'b0, 1'b0);
        run_cycles(1);
        do_lookup(9'd1, 20'h12345);
        check_hit(1'b1, 22'h3ABCD, "Insert and hit — VPN match");

        // ============================================================
        // Test 3: Lookup miss — wrong VPN
        do_lookup(9'd1, 20'h12346);
        check_miss("Miss on wrong VPN");

        // ============================================================
        // Test 4: Lookup miss — wrong ASID (same VPN)
        do_lookup(9'd2, 20'h12345);
        check_miss("Miss on wrong ASID");

        // ============================================================
        // Test 5: ASID isolation — same VPN, different ASID, different PPN
        insert_entry(9'd2, 20'h12345, 22'h1FFFF, 1'b0, 1'b0);
        run_cycles(1);
        do_lookup(9'd2, 20'h12345);
        check_hit(1'b1, 22'h1FFFF, "ASID isolation — same VPN, different ASID maps to different PPN");

        // Verify original ASID still works
        do_lookup(9'd1, 20'h12345);
        check_hit(1'b1, 22'h3ABCD, "Original ASID entry still valid");

        // ============================================================
        // Test 7: Megapage hit — VPN[0] wildcard
        insert_entry(9'd1, 20'hAA000, 22'h2AA00, 1'b1, 1'b0);
        run_cycles(1);
        // Megapage: any VPN[0] under VPN[1]=0x2A8 should hit
        do_lookup(9'd1, {10'h2A8, 10'h123});
        check_hit(1'b1, 22'h2AA00, "Megapage hit — VPN[0] wildcard");

        // Same VPN[1], different VPN[0]
        do_lookup(9'd1, {10'h2A8, 10'h3FF});
        check_hit(1'b1, 22'h2AA00, "Megapage hit — different VPN[0]");

        // ============================================================
        // Test 9: Eviction on full TLB (4 entries)
        // We already have 3 entries. Insert a 4th.
        insert_entry(9'd1, 20'hBBBBB, 22'h0BBBB, 1'b0, 1'b0);
        run_cycles(1);
        do_lookup(9'd1, 20'hBBBBB);
        check_hit(1'b1, 22'h0BBBB, "4th entry lookup hit");

        // Insert a 5th — should evict LRU
        insert_entry(9'd1, 20'hCCCCC, 22'h0CCCC, 1'b0, 1'b0);
        run_cycles(1);
        do_lookup(9'd1, 20'hCCCCC);
        check_hit(1'b1, 22'h0CCCC, "5th entry after eviction — hit");

        // ============================================================
        // Test 11: SFENCE flush all
        sfence_valid <= 1'b1;
        sfence_vaddr <= 32'b0;
        sfence_asid  <= 9'b0;
        @(posedge clk);
        sfence_valid <= 1'b0;
        run_cycles(1);
        do_lookup(9'd1, 20'hCCCCC);
        check_miss("After flush all — miss");

        // ============================================================
        // Test 12: SFENCE flush by address
        insert_entry(9'd1, 20'hAAAAA, 22'h1AAAA, 1'b0, 1'b0);
        insert_entry(9'd1, 20'hBBBBB, 22'h1BBBB, 1'b0, 1'b0);
        run_cycles(1);

        // Flush only AAAAA
        sfence_valid <= 1'b1;
        sfence_vaddr <= {20'hAAAAA, 12'b0};
        sfence_asid  <= 9'b0;
        @(posedge clk);
        sfence_valid <= 1'b0;
        run_cycles(1);

        do_lookup(9'd1, 20'hAAAAA);
        check_miss("Flush by address — flushed entry misses");

        do_lookup(9'd1, 20'hBBBBB);
        check_hit(1'b1, 22'h1BBBB, "Flush by address — other entry still valid");

        // ============================================================
        // Test 14: SFENCE flush by ASID
        insert_entry(9'd3, 20'hDDDDD, 22'h1DDDD, 1'b0, 1'b0);
        run_cycles(1);

        sfence_valid <= 1'b1;
        sfence_vaddr <= 32'b0;
        sfence_asid  <= 9'd3;
        @(posedge clk);
        sfence_valid <= 1'b0;
        run_cycles(1);

        do_lookup(9'd3, 20'hDDDDD);
        check_miss("Flush by ASID — matching ASID flushed");

        do_lookup(9'd1, 20'hBBBBB);
        check_hit(1'b1, 22'h1BBBB, "Flush by ASID — different ASID preserved");

        // ============================================================
        // Test 16: Global page — matches any ASID
        // Flush all first
        sfence_valid <= 1'b1; sfence_vaddr <= 32'b0; sfence_asid <= 9'b0;
        @(posedge clk);
        sfence_valid <= 1'b0;
        run_cycles(1);

        insert_entry(9'd5, 20'hEEEEE, 22'h0EEEE, 1'b0, 1'b1);  // g=1
        run_cycles(1);

        do_lookup(9'd5, 20'hEEEEE);
        check_hit(1'b1, 22'h0EEEE, "Global page hit with matching ASID");

        do_lookup(9'd99, 20'hEEEEE);
        check_hit(1'b1, 22'h0EEEE, "Global page hit with different ASID");

        // ============================================================
        // Summary
        $display("");
        if (fail_count == 0)
            $display("All %0d tests passed", pass_count);
        else
            $display("%0d of %0d tests FAILED", fail_count, pass_count + fail_count);
        $finish;
    end

endmodule
