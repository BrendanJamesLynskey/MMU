// Brendan Lynskey 2025
// Testbench for Permission Checker

`timescale 1ns/1ps

module tb_permission_checker;

    import mmu_pkg::*;

    // DUT signals
    logic       pte_v, pte_r, pte_w, pte_x, pte_u, pte_a, pte_d;
    logic [1:0] access_type;
    logic       priv_mode;
    logic       mxr, sum;
    logic       fault;
    logic [1:0] fault_type;

    permission_checker dut (
        .pte_v       (pte_v),
        .pte_r       (pte_r),
        .pte_w       (pte_w),
        .pte_x       (pte_x),
        .pte_u       (pte_u),
        .pte_a       (pte_a),
        .pte_d       (pte_d),
        .access_type (access_type),
        .priv_mode   (priv_mode),
        .mxr         (mxr),
        .sum         (sum),
        .fault       (fault),
        .fault_type  (fault_type)
    );

    // Test counters
    int pass_count = 0;
    int fail_count = 0;
    int test_num   = 0;

    task automatic check(
        input logic       exp_fault,
        input logic [1:0] exp_fault_type,
        input string      test_name
    );
        test_num++;
        #1;  // Allow combinational settling
        if (fault === exp_fault && (exp_fault == 0 || fault_type === exp_fault_type)) begin
            $display("[PASS] Test %0d: %s", test_num, test_name);
            pass_count++;
        end else begin
            $display("[FAIL] Test %0d: %s — fault=%0b (exp %0b), fault_type=%0b (exp %0b)",
                     test_num, test_name, fault, exp_fault, fault_type, exp_fault_type);
            fail_count++;
        end
    endtask

    task automatic set_pte(
        input logic v, r, w, x, u, a, d
    );
        pte_v = v; pte_r = r; pte_w = w; pte_x = x;
        pte_u = u; pte_a = a; pte_d = d;
    endtask

    initial begin
        // Defaults
        mxr = 0; sum = 0;

        // ========== Basic valid leaf PTEs ==========

        // Test 1: Valid read page, user load — should pass
        set_pte(1, 1, 0, 0, 1, 1, 0);
        access_type = ACCESS_LOAD; priv_mode = 0;
        check(0, FAULT_LOAD, "User load on R page — no fault");

        // Test 2: Valid read-write page, user store — should pass
        set_pte(1, 1, 1, 0, 1, 1, 1);
        access_type = ACCESS_STORE; priv_mode = 0;
        check(0, FAULT_STORE, "User store on RW page with D — no fault");

        // Test 3: Valid execute page, user execute — should pass
        set_pte(1, 0, 0, 1, 1, 1, 0);
        access_type = ACCESS_EXECUTE; priv_mode = 0;
        check(0, FAULT_INSTRUCTION, "User execute on X page — no fault");

        // Test 4: Valid RWX page, supervisor load — should pass (non-U page)
        set_pte(1, 1, 1, 1, 0, 1, 1);
        access_type = ACCESS_LOAD; priv_mode = 1;
        check(0, FAULT_LOAD, "Supervisor load on RWX page — no fault");

        // ========== Invalid PTE checks ==========

        // Test 5: V=0 — always fault
        set_pte(0, 1, 1, 1, 1, 1, 1);
        access_type = ACCESS_LOAD; priv_mode = 0;
        check(1, FAULT_LOAD, "V=0 — fault on load");

        // Test 6: Reserved encoding W=1, R=0
        set_pte(1, 0, 1, 0, 1, 1, 1);
        access_type = ACCESS_LOAD; priv_mode = 0;
        check(1, FAULT_LOAD, "W=1 R=0 reserved — fault");

        // Test 7: A bit not set
        set_pte(1, 1, 0, 0, 1, 0, 0);
        access_type = ACCESS_LOAD; priv_mode = 0;
        check(1, FAULT_LOAD, "A=0 — fault on load");

        // ========== Privilege checks ==========

        // Test 8: User accessing supervisor page (U=0) — fault
        set_pte(1, 1, 0, 0, 0, 1, 0);
        access_type = ACCESS_LOAD; priv_mode = 0;
        check(1, FAULT_LOAD, "User load on S-mode page — fault");

        // Test 9: Supervisor accessing U-mode page without SUM — fault
        set_pte(1, 1, 0, 0, 1, 1, 0);
        access_type = ACCESS_LOAD; priv_mode = 1; sum = 0;
        check(1, FAULT_LOAD, "Supervisor load on U-mode page, SUM=0 — fault");

        // Test 10: Supervisor accessing U-mode page with SUM=1 — no fault
        set_pte(1, 1, 0, 0, 1, 1, 0);
        access_type = ACCESS_LOAD; priv_mode = 1; sum = 1;
        check(0, FAULT_LOAD, "Supervisor load on U-mode page, SUM=1 — no fault");
        sum = 0;

        // ========== Access type permission checks ==========

        // Test 11: Load on execute-only page without MXR — fault
        set_pte(1, 0, 0, 1, 1, 1, 0);
        access_type = ACCESS_LOAD; priv_mode = 0;
        check(1, FAULT_LOAD, "Load on X-only page, MXR=0 — fault");

        // Test 12: Load on execute-only page with MXR=1 — no fault
        set_pte(1, 0, 0, 1, 1, 1, 0);
        access_type = ACCESS_LOAD; priv_mode = 0; mxr = 1;
        check(0, FAULT_LOAD, "Load on X-only page, MXR=1 — no fault");
        mxr = 0;

        // Test 13: Store without W bit — fault
        set_pte(1, 1, 0, 0, 1, 1, 0);
        access_type = ACCESS_STORE; priv_mode = 0;
        check(1, FAULT_STORE, "Store on R-only page — fault");

        // Test 14: Store with W but without D bit — fault
        set_pte(1, 1, 1, 0, 1, 1, 0);
        access_type = ACCESS_STORE; priv_mode = 0;
        check(1, FAULT_STORE, "Store on RW page, D=0 — fault");

        // Test 15: Execute on non-X page — fault
        set_pte(1, 1, 1, 0, 1, 1, 1);
        access_type = ACCESS_EXECUTE; priv_mode = 0;
        check(1, FAULT_INSTRUCTION, "Execute on RW page (no X) — fault");

        // ========== Fault type encoding checks ==========

        // Test 16: Verify load fault type
        set_pte(0, 0, 0, 0, 0, 0, 0);
        access_type = ACCESS_LOAD; priv_mode = 0;
        check(1, FAULT_LOAD, "Fault type is LOAD for load access");

        // Test 17: Verify store fault type
        access_type = ACCESS_STORE;
        check(1, FAULT_STORE, "Fault type is STORE for store access");

        // Test 18: Verify instruction fault type
        access_type = ACCESS_EXECUTE;
        check(1, FAULT_INSTRUCTION, "Fault type is INSTRUCTION for execute access");

        // ========== Edge cases ==========

        // Test 19: RWX page, user store, D=1 — should pass
        set_pte(1, 1, 1, 1, 1, 1, 1);
        access_type = ACCESS_STORE; priv_mode = 0;
        check(0, FAULT_STORE, "Full RWX page, user store, D=1 — no fault");

        // Test 20: Supervisor execute on S-mode X page — should pass
        set_pte(1, 0, 0, 1, 0, 1, 0);
        access_type = ACCESS_EXECUTE; priv_mode = 1;
        check(0, FAULT_INSTRUCTION, "Supervisor execute on S-mode X page — no fault");

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
