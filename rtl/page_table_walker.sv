// Brendan Lynskey 2025
// Page Table Walker — Sv32 two-level hardware PTW
//
// FSM walks the Sv32 two-level page table via a memory interface.
// Supports megapage (leaf at L1) and detects invalid/misaligned PTEs.
//
// Note: PTE fields extracted directly from raw word to avoid iverilog
// packed-struct constant-select limitations in always_comb.

module page_table_walker
    import mmu_pkg::*;
(
    input  logic        clk,
    input  logic        srst,

    // Request interface (from MMU top)
    input  logic        start,
    input  logic [31:0] vaddr,
    input  logic [31:0] satp,

    // Result interface
    output logic        done,
    output logic        fault,
    output logic [PPN_W-1:0] result_ppn,
    output logic        result_d,
    output logic        result_a,
    output logic        result_u,
    output logic        result_x,
    output logic        result_w,
    output logic        result_r,
    output logic        result_g,
    output logic        result_is_megapage,

    // Memory interface
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [31:0] mem_req_addr,
    input  logic        mem_resp_valid,
    input  logic [31:0] mem_resp_data
);

    // FSM states
    typedef enum logic [2:0] {
        S_IDLE,
        S_L1_REQ,
        S_L1_WAIT,
        S_L1_CHECK,
        S_L0_REQ,
        S_L0_WAIT,
        S_L0_CHECK,
        S_DONE
    } ptw_state_t;

    ptw_state_t state, state_next;

    // Registered request
    logic [9:0]  vpn1_r, vpn0_r;
    logic [21:0] root_ppn_r;

    // PTE captured from memory
    logic [31:0] pte_raw;

    // Flattened PTE field extraction (avoids struct constant-select issues in iverilog)
    wire [21:0] pte_ppn = pte_raw[31:10];
    wire        pte_d   = pte_raw[7];
    wire        pte_a   = pte_raw[6];
    wire        pte_g   = pte_raw[5];
    wire        pte_u   = pte_raw[4];
    wire        pte_x   = pte_raw[3];
    wire        pte_w   = pte_raw[2];
    wire        pte_r   = pte_raw[1];
    wire        pte_v   = pte_raw[0];

    // Derived PTE checks
    wire pte_valid  = pte_v && !(pte_w && !pte_r);   // V=1 and not reserved W=1,R=0
    wire pte_is_leaf = pte_r | pte_x;                 // Leaf if R or X set

    // Sequential state
    always_ff @(posedge clk) begin
        if (srst) begin
            state      <= S_IDLE;
            vpn1_r     <= '0;
            vpn0_r     <= '0;
            root_ppn_r <= '0;
            pte_raw    <= '0;
        end else begin
            state <= state_next;

            if (state == S_IDLE && start) begin
                vpn1_r     <= vaddr[31:22];
                vpn0_r     <= vaddr[21:12];
                root_ppn_r <= satp[21:0];
            end

            // Capture memory response
            if ((state == S_L1_WAIT || state == S_L0_WAIT) && mem_resp_valid) begin
                pte_raw <= mem_resp_data;
            end
        end
    end

    // Combinational next-state and outputs
    // Note: using always @(*) to avoid iverilog constant-select sensitivity issues
    always @(*) begin
        state_next       = state;
        mem_req_valid    = 1'b0;
        mem_req_addr     = '0;
        done             = 1'b0;
        fault            = 1'b0;
        result_ppn       = '0;
        result_d         = 1'b0;
        result_a         = 1'b0;
        result_u         = 1'b0;
        result_x         = 1'b0;
        result_w         = 1'b0;
        result_r         = 1'b0;
        result_g         = 1'b0;
        result_is_megapage = 1'b0;

        case (state)
            S_IDLE: begin
                if (start)
                    state_next = S_L1_REQ;
            end

            S_L1_REQ: begin
                mem_req_valid = 1'b1;
                mem_req_addr  = {root_ppn_r, 12'b0} + {20'b0, vpn1_r, 2'b0};
                if (mem_req_ready)
                    state_next = S_L1_WAIT;
            end

            S_L1_WAIT: begin
                if (mem_resp_valid)
                    state_next = S_L1_CHECK;
            end

            S_L1_CHECK: begin
                if (!pte_valid) begin
                    state_next = S_DONE;
                    fault      = 1'b1;
                    done       = 1'b1;
                end else if (pte_is_leaf) begin
                    // Megapage — PPN[9:0] must be zero for alignment
                    if (pte_ppn[9:0] != 10'b0) begin
                        state_next = S_DONE;
                        fault      = 1'b1;
                        done       = 1'b1;
                    end else begin
                        state_next       = S_DONE;
                        done             = 1'b1;
                        result_ppn       = pte_ppn;
                        result_d         = pte_d;
                        result_a         = pte_a;
                        result_u         = pte_u;
                        result_x         = pte_x;
                        result_w         = pte_w;
                        result_r         = pte_r;
                        result_g         = pte_g;
                        result_is_megapage = 1'b1;
                    end
                end else begin
                    state_next = S_L0_REQ;
                end
            end

            S_L0_REQ: begin
                mem_req_valid = 1'b1;
                mem_req_addr  = {pte_ppn, 12'b0} + {20'b0, vpn0_r, 2'b0};
                if (mem_req_ready)
                    state_next = S_L0_WAIT;
            end

            S_L0_WAIT: begin
                if (mem_resp_valid)
                    state_next = S_L0_CHECK;
            end

            S_L0_CHECK: begin
                if (!pte_valid) begin
                    state_next = S_DONE;
                    fault      = 1'b1;
                    done       = 1'b1;
                end else if (!pte_is_leaf) begin
                    state_next = S_DONE;
                    fault      = 1'b1;
                    done       = 1'b1;
                end else begin
                    state_next   = S_DONE;
                    done         = 1'b1;
                    result_ppn   = pte_ppn;
                    result_d     = pte_d;
                    result_a     = pte_a;
                    result_u     = pte_u;
                    result_x     = pte_x;
                    result_w     = pte_w;
                    result_r     = pte_r;
                    result_g     = pte_g;
                    result_is_megapage = 1'b0;
                end
            end

            S_DONE: begin
                state_next = S_IDLE;
            end

            default: state_next = S_IDLE;
        endcase
    end

endmodule
