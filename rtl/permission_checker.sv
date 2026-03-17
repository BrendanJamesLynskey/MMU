// Brendan Lynskey 2025
// Permission Checker — Combinational access permission and fault logic
//
// Implements RISC-V Privileged Spec §4.3.1 permission rules:
// - Supervisor cannot access U-mode pages unless SUM=1
// - User cannot access non-U-mode pages
// - Execute requires X bit
// - Read requires R bit (or X bit if MXR=1)
// - Write requires W bit; store also requires D bit (accessed+dirty)
// - A (accessed) bit must be set
// - PTE must be valid (V=1) and not use reserved encoding (W=1, R=0)

module permission_checker
    import mmu_pkg::*;
(
    // PTE permission bits
    input  logic        pte_v,
    input  logic        pte_r,
    input  logic        pte_w,
    input  logic        pte_x,
    input  logic        pte_u,
    input  logic        pte_a,
    input  logic        pte_d,

    // Request info
    input  logic [1:0]  access_type,    // access_type_t encoding
    input  logic        priv_mode,      // 0=user, 1=supervisor

    // Optional CSR bits
    input  logic        mxr,            // mstatus.MXR — make executable readable
    input  logic        sum,            // mstatus.SUM — supervisor user memory access

    // Outputs
    output logic        fault,
    output logic [1:0]  fault_type
);

    // Determine fault_type based on access type
    always_comb begin
        case (access_type)
            ACCESS_LOAD:    fault_type = FAULT_LOAD;
            ACCESS_STORE:   fault_type = FAULT_STORE;
            ACCESS_EXECUTE: fault_type = FAULT_INSTRUCTION;
            default:        fault_type = FAULT_LOAD;
        endcase
    end

    // Permission check logic
    always_comb begin
        fault = 1'b0;

        // Check 1: PTE must be valid
        if (!pte_v) begin
            fault = 1'b1;
        end
        // Check 2: Reserved encoding — W=1, R=0 is invalid
        else if (pte_w && !pte_r) begin
            fault = 1'b1;
        end
        // Check 3: Accessed bit must be set
        else if (!pte_a) begin
            fault = 1'b1;
        end
        // Check 4: Privilege-based checks
        else if (priv_mode == 1'b0) begin
            // User mode — must have U bit
            if (!pte_u) begin
                fault = 1'b1;
            end
        end else begin
            // Supervisor mode — cannot access U-mode pages unless SUM=1
            if (pte_u && !sum) begin
                fault = 1'b1;
            end
        end

        // Check 5: Access-type specific permission checks (only if no fault yet)
        if (!fault) begin
            case (access_type)
                ACCESS_LOAD: begin
                    // Read requires R bit, or X bit if MXR=1
                    if (!pte_r && !(mxr && pte_x)) begin
                        fault = 1'b1;
                    end
                end
                ACCESS_STORE: begin
                    // Write requires W bit and D bit
                    if (!pte_w || !pte_d) begin
                        fault = 1'b1;
                    end
                end
                ACCESS_EXECUTE: begin
                    // Execute requires X bit
                    if (!pte_x) begin
                        fault = 1'b1;
                    end
                end
                default: begin
                    fault = 1'b1;
                end
            endcase
        end
    end

endmodule
