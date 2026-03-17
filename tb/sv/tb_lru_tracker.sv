// Brendan Lynskey 2025
// Testbench for LRU Tracker

`timescale 1ns/1ps

module tb_lru_tracker;

    import mmu_pkg::*;

    localparam int NUM_ENTRIES = 4;  // Small for easy verification
    localparam int IDX_W = $clog2(NUM_ENTRIES);

    logic                clk;
    logic                srst;
    logic                access_valid;
    logic [IDX_W-1:0]    access_idx;
    logic [IDX_W-1:0]    lru_idx;

    lru_tracker #(
        .NUM_ENTRIES(NUM_ENTRIES)
    ) dut (
        .clk          (clk),
        .srst         (srst),
        .access_valid (access_valid),
        .access_idx   (access_idx),
        .lru_idx      (lru_idx)
    );

    // Clock generation
    initial clk = 0;
    always #5 clk = ~clk;

    // Test counters
    int pass_count = 0;
    int fail_count = 0;
    int test_num   = 0;

    task automatic run_cycles(int n);
        repeat (n) @(posedge clk);
    endtask

    task automatic access_entry(input logic [IDX_W-1:0] idx);
        @(posedge clk);
        access_valid <= 1'b1;
        access_idx   <= idx;
        @(posedge clk);
        access_valid <= 1'b0;
    endtask

    task automatic check_lru(input logic [IDX_W-1:0] expected, input string test_name);
        test_num++;
        // Allow combinational output to settle
        #1;
        if (lru_idx === expected) begin
            $display("[PASS] Test %0d: %s — LRU=%0d (expected %0d)", test_num, test_name, lru_idx, expected);
            pass_count++;
        end else begin
            $display("[FAIL] Test %0d: %s — LRU=%0d (expected %0d)", test_num, test_name, lru_idx, expected);
            fail_count++;
        end
    endtask

    initial begin
        // Initialize
        srst         = 1'b1;
        access_valid = 1'b0;
        access_idx   = '0;

        run_cycles(3);
        srst = 1'b0;
        run_cycles(1);

        // --------------------------------------------------------
        // Test 1: After reset, LRU should be entry 0 (all rows zero, lowest index wins)
        check_lru(0, "LRU after reset is entry 0");

        // --------------------------------------------------------
        // Test 2: Access entry 0 — now entry 0 is MRU, LRU should be entry 1
        access_entry(0);
        run_cycles(1);
        check_lru(1, "After accessing 0, LRU is 1");

        // --------------------------------------------------------
        // Test 3: Access entry 1 — LRU should be entry 2
        access_entry(1);
        run_cycles(1);
        check_lru(2, "After accessing 0,1, LRU is 2");

        // --------------------------------------------------------
        // Test 4: Access entry 2 — LRU should be entry 3
        access_entry(2);
        run_cycles(1);
        check_lru(3, "After accessing 0,1,2, LRU is 3");

        // --------------------------------------------------------
        // Test 5: Access entry 3 — All accessed, LRU should be entry 0 (least recently accessed)
        access_entry(3);
        run_cycles(1);
        check_lru(0, "After accessing 0,1,2,3, LRU is 0");

        // --------------------------------------------------------
        // Test 6: Access entry 0 again — LRU should now be entry 1
        access_entry(0);
        run_cycles(1);
        check_lru(1, "After re-accessing 0, LRU is 1");

        // --------------------------------------------------------
        // Test 7: Access entries in reverse: 3,2,1 — LRU should be entry 0
        access_entry(3);
        access_entry(2);
        access_entry(1);
        run_cycles(1);
        check_lru(0, "After accessing 3,2,1, LRU is 0");

        // --------------------------------------------------------
        // Test 8: Access all in order 0,1,2,3 then access 2 — LRU should be 0
        access_entry(0);
        access_entry(1);
        access_entry(2);
        access_entry(3);
        access_entry(2);  // Re-access 2, order becomes: 0(oldest),1,3,2(newest)
        run_cycles(1);
        check_lru(0, "Complex access pattern: LRU is 0");

        // --------------------------------------------------------
        // Test 9: From previous state, access 0 — LRU should be 1
        access_entry(0);
        run_cycles(1);
        check_lru(1, "After promoting 0, LRU is 1");

        // --------------------------------------------------------
        // Test 10: Reset and verify LRU returns to 0
        srst = 1'b1;
        run_cycles(2);
        srst = 1'b0;
        run_cycles(1);
        check_lru(0, "LRU after second reset is 0");

        // --------------------------------------------------------
        // Summary
        $display("");
        if (fail_count == 0)
            $display("All %0d tests passed", pass_count);
        else
            $display("%0d of %0d tests FAILED", fail_count, pass_count + fail_count);
        $finish;
    end

endmodule
