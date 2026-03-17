// Brendan Lynskey 2025
// MMU Top — Sv32 Memory Management Unit with TLB, PTW, and permission checking
//
// Arbitration FSM: IDLE → TLB_LOOKUP → respond (hit) or PTW_ACTIVE (miss)
//                  PTW_ACTIVE → PTW_DONE (register result) → PERM_CHECK → respond
// Bare mode bypass when satp.MODE == 0.

module mmu_top
    import mmu_pkg::*;
#(
    parameter int NUM_TLB_ENTRIES = TLB_ENTRIES
) (
    input  logic        clk,
    input  logic        srst,

    // CPU-side request interface
    input  logic        req_valid,
    output logic        req_ready,
    input  logic [31:0] vaddr,
    input  logic [1:0]  access_type,
    input  logic        priv_mode,       // 0=user, 1=supervisor

    // CPU-side response interface
    output logic        resp_valid,
    output logic [31:0] paddr,
    output logic        page_fault,
    output logic [1:0]  fault_type,

    // Memory-side interface (for PTW)
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [31:0] mem_req_addr,
    input  logic        mem_resp_valid,
    input  logic [31:0] mem_resp_data,

    // Control / CSR interface
    input  logic [31:0] satp,
    input  logic        sfence_valid,
    input  logic [31:0] sfence_vaddr,
    input  logic [8:0]  sfence_asid,

    // Optional CSR bits
    input  logic        mxr,
    input  logic        sum
);

    // ---- Top-level FSM ----
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_TLB_LOOKUP,
        ST_PTW_ACTIVE,
        ST_PTW_DONE,
        ST_PERM_CHECK
    } mmu_state_t;

    mmu_state_t state, state_next;

    // Registered request fields
    logic [31:0] vaddr_r;
    logic [1:0]  access_type_r;
    logic        priv_mode_r;

    // Registered PTW results (captured in ST_PTW_DONE)
    logic [PPN_W-1:0] ptw_ppn_r;
    logic        ptw_d_r, ptw_a_r, ptw_u_r, ptw_x_r, ptw_w_r, ptw_r_r, ptw_g_r;
    logic        ptw_mega_r;
    logic        ptw_fault_r;

    // ---- TLB signals ----
    logic [VPN_W-1:0]   tlb_lookup_vpn;
    logic [ASID_W-1:0]  tlb_lookup_asid;
    logic               tlb_hit;
    logic [PPN_W-1:0]   tlb_ppn;
    logic               tlb_d, tlb_a, tlb_u, tlb_x, tlb_w, tlb_r;
    logic               tlb_is_megapage;

    logic               tlb_write_valid;
    logic [ASID_W-1:0]  tlb_write_asid;
    logic [VPN_W-1:0]   tlb_write_vpn;
    logic [PPN_W-1:0]   tlb_write_ppn;
    logic               tlb_write_d, tlb_write_a, tlb_write_u;
    logic               tlb_write_x, tlb_write_w, tlb_write_r;
    logic               tlb_write_g, tlb_write_is_megapage;

    // ---- PTW signals ----
    logic        ptw_start;
    logic        ptw_done, ptw_fault;
    logic [PPN_W-1:0] ptw_ppn;
    logic        ptw_d, ptw_a, ptw_u, ptw_x, ptw_w, ptw_r, ptw_g;
    logic        ptw_is_megapage;

    // ---- Permission checker signals ----
    logic        perm_fault;
    logic [1:0]  perm_fault_type;

    // Permission checker source select — use registered PTW result in PERM_CHECK,
    // otherwise use TLB values.
    logic        perm_src_ptw;
    assign perm_src_ptw = (state == ST_PERM_CHECK);

    wire         pc_v = 1'b1;
    wire         pc_r = perm_src_ptw ? ptw_r_r : tlb_r;
    wire         pc_w = perm_src_ptw ? ptw_w_r : tlb_w;
    wire         pc_x = perm_src_ptw ? ptw_x_r : tlb_x;
    wire         pc_u = perm_src_ptw ? ptw_u_r : tlb_u;
    wire         pc_a = perm_src_ptw ? ptw_a_r : tlb_a;
    wire         pc_d = perm_src_ptw ? ptw_d_r : tlb_d;

    // ---- Submodule instances ----
    tlb #(.NUM_ENTRIES(NUM_TLB_ENTRIES)) u_tlb (
        .clk               (clk),
        .srst              (srst),
        .lookup_vpn        (tlb_lookup_vpn),
        .lookup_asid       (tlb_lookup_asid),
        .lookup_hit        (tlb_hit),
        .lookup_ppn        (tlb_ppn),
        .lookup_d          (tlb_d),
        .lookup_a          (tlb_a),
        .lookup_u          (tlb_u),
        .lookup_x          (tlb_x),
        .lookup_w          (tlb_w),
        .lookup_r          (tlb_r),
        .lookup_is_megapage(tlb_is_megapage),
        .write_valid       (tlb_write_valid),
        .write_asid        (tlb_write_asid),
        .write_vpn         (tlb_write_vpn),
        .write_ppn         (tlb_write_ppn),
        .write_d           (tlb_write_d),
        .write_a           (tlb_write_a),
        .write_u           (tlb_write_u),
        .write_x           (tlb_write_x),
        .write_w           (tlb_write_w),
        .write_r           (tlb_write_r),
        .write_g           (tlb_write_g),
        .write_is_megapage (tlb_write_is_megapage),
        .sfence_valid      (sfence_valid),
        .sfence_vaddr      (sfence_vaddr),
        .sfence_asid       (sfence_asid)
    );

    page_table_walker u_ptw (
        .clk              (clk),
        .srst             (srst),
        .start            (ptw_start),
        .vaddr            (vaddr_r),
        .satp             (satp),
        .done             (ptw_done),
        .fault            (ptw_fault),
        .result_ppn       (ptw_ppn),
        .result_d         (ptw_d),
        .result_a         (ptw_a),
        .result_u         (ptw_u),
        .result_x         (ptw_x),
        .result_w         (ptw_w),
        .result_r         (ptw_r),
        .result_g         (ptw_g),
        .result_is_megapage(ptw_is_megapage),
        .mem_req_valid    (mem_req_valid),
        .mem_req_ready    (mem_req_ready),
        .mem_req_addr     (mem_req_addr),
        .mem_resp_valid   (mem_resp_valid),
        .mem_resp_data    (mem_resp_data)
    );

    permission_checker u_perm (
        .pte_v       (pc_v),
        .pte_r       (pc_r),
        .pte_w       (pc_w),
        .pte_x       (pc_x),
        .pte_u       (pc_u),
        .pte_a       (pc_a),
        .pte_d       (pc_d),
        .access_type (access_type_r),
        .priv_mode   (priv_mode_r),
        .mxr         (mxr),
        .sum         (sum),
        .fault       (perm_fault),
        .fault_type  (perm_fault_type)
    );

    // ---- TLB lookup address ----
    assign tlb_lookup_vpn  = vaddr_r[31:12];
    assign tlb_lookup_asid = satp[30:22];

    // ---- Sequential logic ----
    always_ff @(posedge clk) begin
        if (srst) begin
            state         <= ST_IDLE;
            vaddr_r       <= '0;
            access_type_r <= '0;
            priv_mode_r   <= 1'b0;
            ptw_ppn_r     <= '0;
            ptw_d_r       <= 1'b0;
            ptw_a_r       <= 1'b0;
            ptw_u_r       <= 1'b0;
            ptw_x_r       <= 1'b0;
            ptw_w_r       <= 1'b0;
            ptw_r_r       <= 1'b0;
            ptw_g_r       <= 1'b0;
            ptw_mega_r    <= 1'b0;
            ptw_fault_r   <= 1'b0;
        end else begin
            state <= state_next;

            // Capture request on acceptance
            if (state == ST_IDLE && req_valid && !sfence_valid) begin
                vaddr_r       <= vaddr;
                access_type_r <= access_type;
                priv_mode_r   <= priv_mode;
            end

            // Capture PTW results when done
            if (state == ST_PTW_ACTIVE && ptw_done) begin
                ptw_ppn_r   <= ptw_ppn;
                ptw_d_r     <= ptw_d;
                ptw_a_r     <= ptw_a;
                ptw_u_r     <= ptw_u;
                ptw_x_r     <= ptw_x;
                ptw_w_r     <= ptw_w;
                ptw_r_r     <= ptw_r;
                ptw_g_r     <= ptw_g;
                ptw_mega_r  <= ptw_is_megapage;
                ptw_fault_r <= ptw_fault;
            end
        end
    end

    // ---- Combinational FSM ----
    always @(*) begin
        state_next   = state;
        req_ready    = 1'b0;
        resp_valid   = 1'b0;
        paddr        = '0;
        page_fault   = 1'b0;
        fault_type   = '0;
        ptw_start    = 1'b0;

        // TLB write defaults
        tlb_write_valid       = 1'b0;
        tlb_write_asid        = '0;
        tlb_write_vpn         = '0;
        tlb_write_ppn         = '0;
        tlb_write_d           = 1'b0;
        tlb_write_a           = 1'b0;
        tlb_write_u           = 1'b0;
        tlb_write_x           = 1'b0;
        tlb_write_w           = 1'b0;
        tlb_write_r           = 1'b0;
        tlb_write_g           = 1'b0;
        tlb_write_is_megapage = 1'b0;

        case (state)
            ST_IDLE: begin
                req_ready = 1'b1;
                if (req_valid && !sfence_valid) begin
                    if (!satp[31]) begin
                        // Bare mode — passthrough
                        resp_valid = 1'b1;
                        paddr      = vaddr;
                    end else begin
                        state_next = ST_TLB_LOOKUP;
                    end
                end
            end

            ST_TLB_LOOKUP: begin
                if (tlb_hit) begin
                    // Permission check uses TLB values (perm_src_ptw=0 since state!=PERM_CHECK)
                    if (perm_fault) begin
                        resp_valid = 1'b1;
                        page_fault = 1'b1;
                        fault_type = perm_fault_type;
                        state_next = ST_IDLE;
                    end else begin
                        resp_valid = 1'b1;
                        if (tlb_is_megapage) begin
                            paddr = {tlb_ppn[19:10], vaddr_r[21:0]};
                        end else begin
                            paddr = {tlb_ppn[19:0], vaddr_r[11:0]};
                        end
                        state_next = ST_IDLE;
                    end
                end else begin
                    // TLB miss — start PTW
                    ptw_start  = 1'b1;
                    state_next = ST_PTW_ACTIVE;
                end
            end

            ST_PTW_ACTIVE: begin
                if (ptw_done) begin
                    // PTW completed — register results and go to PTW_DONE
                    state_next = ST_PTW_DONE;
                end
            end

            ST_PTW_DONE: begin
                // PTW results are now registered. Write TLB and check permissions.
                if (ptw_fault_r) begin
                    // PTW detected a structural fault (invalid PTE, misaligned, etc.)
                    resp_valid = 1'b1;
                    page_fault = 1'b1;
                    case (access_type_r)
                        ACCESS_LOAD:    fault_type = FAULT_LOAD;
                        ACCESS_STORE:   fault_type = FAULT_STORE;
                        ACCESS_EXECUTE: fault_type = FAULT_INSTRUCTION;
                        default:        fault_type = FAULT_LOAD;
                    endcase
                    state_next = ST_IDLE;
                end else begin
                    // Write TLB entry
                    tlb_write_valid       = 1'b1;
                    tlb_write_asid        = satp[30:22];
                    tlb_write_vpn         = vaddr_r[31:12];
                    tlb_write_ppn         = ptw_ppn_r;
                    tlb_write_d           = ptw_d_r;
                    tlb_write_a           = ptw_a_r;
                    tlb_write_u           = ptw_u_r;
                    tlb_write_x           = ptw_x_r;
                    tlb_write_w           = ptw_w_r;
                    tlb_write_r           = ptw_r_r;
                    tlb_write_g           = ptw_g_r;
                    tlb_write_is_megapage = ptw_mega_r;

                    // Go to permission check (one more cycle for TLB write to take effect,
                    // though we use registered PTW values for perm check)
                    state_next = ST_PERM_CHECK;
                end
            end

            ST_PERM_CHECK: begin
                // Permission checker now sees registered PTW values (perm_src_ptw=1)
                if (perm_fault) begin
                    resp_valid = 1'b1;
                    page_fault = 1'b1;
                    fault_type = perm_fault_type;
                    state_next = ST_IDLE;
                end else begin
                    resp_valid = 1'b1;
                    if (ptw_mega_r) begin
                        paddr = {ptw_ppn_r[19:10], vaddr_r[21:0]};
                    end else begin
                        paddr = {ptw_ppn_r[19:0], vaddr_r[11:0]};
                    end
                    state_next = ST_IDLE;
                end
            end

            default: state_next = ST_IDLE;
        endcase
    end

endmodule
