// Brendan Lynskey 2025
// TLB — Fully-associative Translation Lookaside Buffer with LRU replacement
//
// Single-cycle combinational lookup, single write port for PTW fill.
// Supports megapage (4 MiB) entries with VPN[0] wildcard matching.
// ASID-tagged entries with SFENCE.VMA flush support.

module tlb
    import mmu_pkg::*;
#(
    parameter int NUM_ENTRIES = TLB_ENTRIES
) (
    input  logic                clk,
    input  logic                srst,

    // Lookup interface (combinational)
    input  logic [VPN_W-1:0]    lookup_vpn,
    input  logic [ASID_W-1:0]   lookup_asid,
    output logic                lookup_hit,
    output logic [PPN_W-1:0]    lookup_ppn,
    output logic                lookup_d,
    output logic                lookup_a,
    output logic                lookup_u,
    output logic                lookup_x,
    output logic                lookup_w,
    output logic                lookup_r,
    output logic                lookup_is_megapage,

    // Write interface (from PTW)
    input  logic                write_valid,
    input  logic [ASID_W-1:0]   write_asid,
    input  logic [VPN_W-1:0]    write_vpn,
    input  logic [PPN_W-1:0]    write_ppn,
    input  logic                write_d,
    input  logic                write_a,
    input  logic                write_u,
    input  logic                write_x,
    input  logic                write_w,
    input  logic                write_r,
    input  logic                write_g,
    input  logic                write_is_megapage,

    // Flush interface (SFENCE.VMA)
    input  logic                sfence_valid,
    input  logic [31:0]         sfence_vaddr,
    input  logic [ASID_W-1:0]   sfence_asid
);

    localparam int IDX_W = $clog2(NUM_ENTRIES);

    // TLB storage — flattened (iverilog struct array workaround)
    logic               entry_valid [NUM_ENTRIES];
    logic [ASID_W-1:0]  entry_asid  [NUM_ENTRIES];
    logic [VPN_W-1:0]   entry_vpn   [NUM_ENTRIES];
    logic [PPN_W-1:0]   entry_ppn   [NUM_ENTRIES];
    logic               entry_d     [NUM_ENTRIES];
    logic               entry_a     [NUM_ENTRIES];
    logic               entry_u     [NUM_ENTRIES];
    logic               entry_x     [NUM_ENTRIES];
    logic               entry_w     [NUM_ENTRIES];
    logic               entry_r     [NUM_ENTRIES];
    logic               entry_g     [NUM_ENTRIES];
    logic               entry_mega  [NUM_ENTRIES];

    // LRU tracker
    logic               lru_access_valid;
    logic [IDX_W-1:0]   lru_access_idx;
    logic [IDX_W-1:0]   lru_victim_idx;

    lru_tracker #(
        .NUM_ENTRIES(NUM_ENTRIES)
    ) u_lru (
        .clk          (clk),
        .srst         (srst),
        .access_valid (lru_access_valid),
        .access_idx   (lru_access_idx),
        .lru_idx      (lru_victim_idx)
    );

    // ---- Combinational lookup ----
    logic [NUM_ENTRIES-1:0] match_vec;
    logic [IDX_W-1:0]      hit_idx;

    // Intermediate signals for ASID comparison (avoid local var in always_comb)
    logic [NUM_ENTRIES-1:0] asid_ok_vec;
    logic [NUM_ENTRIES-1:0] vpn_match_vec;

    // Generate ASID and VPN match signals
    genvar gi;
    generate
        for (gi = 0; gi < NUM_ENTRIES; gi++) begin : gen_match
            assign asid_ok_vec[gi] = entry_g[gi] || (entry_asid[gi] == lookup_asid);
            assign vpn_match_vec[gi] = entry_mega[gi]
                ? (entry_vpn[gi][VPN_W-1:VPN0_W] == lookup_vpn[VPN_W-1:VPN0_W])
                : (entry_vpn[gi] == lookup_vpn);
        end
    endgenerate

    always_comb begin
        match_vec = '0;
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            match_vec[i] = entry_valid[i] && asid_ok_vec[i] && vpn_match_vec[i];
        end
    end

    // Priority encoder — find first match
    always_comb begin
        lookup_hit = 1'b0;
        hit_idx    = '0;
        lookup_ppn = '0;
        lookup_d   = 1'b0;
        lookup_a   = 1'b0;
        lookup_u   = 1'b0;
        lookup_x   = 1'b0;
        lookup_w   = 1'b0;
        lookup_r   = 1'b0;
        lookup_is_megapage = 1'b0;

        for (int i = 0; i < NUM_ENTRIES; i++) begin
            if (match_vec[i] && !lookup_hit) begin
                lookup_hit = 1'b1;
                hit_idx    = IDX_W'(i);
                lookup_ppn = entry_ppn[i];
                lookup_d   = entry_d[i];
                lookup_a   = entry_a[i];
                lookup_u   = entry_u[i];
                lookup_x   = entry_x[i];
                lookup_w   = entry_w[i];
                lookup_r   = entry_r[i];
                lookup_is_megapage = entry_mega[i];
            end
        end
    end

    // LRU access on hit
    assign lru_access_valid = lookup_hit;
    assign lru_access_idx   = hit_idx;

    // ---- Write and Flush (sequential) ----

    // Find a free slot or use LRU victim
    logic [IDX_W-1:0] write_idx;
    logic              found_free;

    always_comb begin
        write_idx  = lru_victim_idx;
        found_free = 1'b0;
        for (int i = NUM_ENTRIES - 1; i >= 0; i--) begin
            if (!entry_valid[i]) begin
                write_idx  = IDX_W'(i);
                found_free = 1'b1;
            end
        end
    end

    // Flush match signals — combinational, used by always_ff
    logic [NUM_ENTRIES-1:0] flush_vec;

    // Note: using always @(*) to avoid iverilog constant-select sensitivity issues
    always @(*) begin
        flush_vec = '0;
        if (sfence_valid) begin
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                if (sfence_vaddr == 32'b0 && sfence_asid == 9'b0) begin
                    flush_vec[i] = 1'b1;
                end else if (sfence_vaddr != 32'b0 && sfence_asid == 9'b0) begin
                    flush_vec[i] = (entry_vpn[i] == sfence_vaddr[31:12]);
                end else if (sfence_vaddr == 32'b0 && sfence_asid != 9'b0) begin
                    flush_vec[i] = (entry_asid[i] == sfence_asid) && !entry_g[i];
                end else begin
                    flush_vec[i] = (entry_vpn[i] == sfence_vaddr[31:12]) && (entry_asid[i] == sfence_asid);
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (srst) begin
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                entry_valid[i] <= 1'b0;
            end
        end else begin
            // SFENCE flush
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                if (flush_vec[i])
                    entry_valid[i] <= 1'b0;
            end

            // Write new entry (sfence takes priority — don't write during flush)
            if (write_valid && !sfence_valid) begin
                entry_valid[write_idx] <= 1'b1;
                entry_asid [write_idx] <= write_asid;
                entry_vpn  [write_idx] <= write_vpn;
                entry_ppn  [write_idx] <= write_ppn;
                entry_d    [write_idx] <= write_d;
                entry_a    [write_idx] <= write_a;
                entry_u    [write_idx] <= write_u;
                entry_x    [write_idx] <= write_x;
                entry_w    [write_idx] <= write_w;
                entry_r    [write_idx] <= write_r;
                entry_g    [write_idx] <= write_g;
                entry_mega [write_idx] <= write_is_megapage;
            end
        end
    end

endmodule
