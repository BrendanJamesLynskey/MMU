// Brendan Lynskey 2025
// MMU Package — Parameters, types, and constants for Sv32 MMU

package mmu_pkg;

    // ---------- Page / Address geometry ----------
    parameter int PAGE_SIZE       = 4096;           // 4 KiB
    parameter int PAGE_OFFSET_W   = 12;             // log2(PAGE_SIZE)
    parameter int VADDR_W         = 32;
    parameter int PADDR_W         = 34;             // Sv32 supports 34-bit PA (not used fully here, kept 32)
    parameter int VPN_W           = 20;             // 2 × 10-bit VPN fields
    parameter int VPN1_W          = 10;             // VPN[1] — L1 index
    parameter int VPN0_W          = 10;             // VPN[0] — L0 index
    parameter int PPN_W           = 22;             // Physical page number width
    parameter int PPN1_W          = 12;             // PPN[1]
    parameter int PPN0_W          = 10;             // PPN[0]
    parameter int PTE_SIZE        = 4;              // Bytes per PTE

    // ---------- SATP fields ----------
    parameter int ASID_W          = 9;

    // ---------- TLB ----------
    parameter int TLB_ENTRIES     = 16;
    parameter int TLB_IDX_W       = $clog2(TLB_ENTRIES);

    // ---------- Access types ----------
    typedef enum logic [1:0] {
        ACCESS_LOAD    = 2'b00,
        ACCESS_STORE   = 2'b01,
        ACCESS_EXECUTE = 2'b10
    } access_type_t;

    // ---------- Fault types ----------
    typedef enum logic [1:0] {
        FAULT_INSTRUCTION = 2'b00,
        FAULT_LOAD        = 2'b01,
        FAULT_STORE       = 2'b10
    } fault_type_t;

    // ---------- PTE structure (Sv32) ----------
    // PTE layout: [31:10] PPN | [9:8] RSW | [7] D | [6] A | [5] G | [4] U | [3] X | [2] W | [1] R | [0] V
    typedef struct packed {
        logic [21:0] ppn;       // [31:10]
        logic [1:0]  rsw;       // [9:8]  — reserved for software
        logic        d;         // [7]    — dirty
        logic        a;         // [6]    — accessed
        logic        g;         // [5]    — global
        logic        u;         // [4]    — user-mode accessible
        logic        x;         // [3]    — execute
        logic        w;         // [2]    — write
        logic        r;         // [1]    — read
        logic        v;         // [0]    — valid
    } pte_t;

    // ---------- TLB entry ----------
    typedef struct packed {
        logic               valid;
        logic [ASID_W-1:0]  asid;
        logic [VPN_W-1:0]   vpn;
        logic [PPN_W-1:0]   ppn;
        logic               d;
        logic               a;
        logic               u;
        logic               x;
        logic               w;
        logic               r;
        logic               g;
        logic               is_megapage;
    } tlb_entry_t;

    // ---------- Helper functions ----------

    // Extract VPN[1] (L1 index) from virtual address
    function automatic logic [VPN1_W-1:0] get_vpn1(input logic [31:0] vaddr);
        return vaddr[31:22];
    endfunction

    // Extract VPN[0] (L0 index) from virtual address
    function automatic logic [VPN0_W-1:0] get_vpn0(input logic [31:0] vaddr);
        return vaddr[21:12];
    endfunction

    // Extract page offset from virtual address
    function automatic logic [PAGE_OFFSET_W-1:0] get_offset(input logic [31:0] vaddr);
        return vaddr[11:0];
    endfunction

    // Parse raw 32-bit PTE word into pte_t struct
    function automatic pte_t parse_pte(input logic [31:0] raw);
        pte_t p;
        p.ppn = raw[31:10];
        p.rsw = raw[9:8];
        p.d   = raw[7];
        p.a   = raw[6];
        p.g   = raw[5];
        p.u   = raw[4];
        p.x   = raw[3];
        p.w   = raw[2];
        p.r   = raw[1];
        p.v   = raw[0];
        return p;
    endfunction

    // Check if PTE is a leaf (has R or X set)
    function automatic logic pte_is_leaf(input pte_t p);
        return p.r | p.x;
    endfunction

    // Check if PTE is valid — V must be set and (R,W) != (0,1)
    function automatic logic pte_is_valid(input pte_t p);
        return p.v && !(p.w && !p.r);
    endfunction

    // SATP field extraction
    function automatic logic satp_mode(input logic [31:0] satp);
        return satp[31];
    endfunction

    function automatic logic [ASID_W-1:0] satp_asid(input logic [31:0] satp);
        return satp[30:22];
    endfunction

    function automatic logic [PPN_W-1:0] satp_ppn(input logic [31:0] satp);
        return satp[21:0];
    endfunction

endpackage
