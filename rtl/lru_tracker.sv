// Brendan Lynskey 2025
// LRU Tracker — True LRU replacement policy for TLB
//
// Maintains an NxN upper-triangular bit matrix for true LRU tracking.
// Matrix method: for each pair (i,j) where i<j, bit[i][j]=1 means i was
// used more recently than j. On access to entry k, set row k to all 1s
// and column k to all 0s. The LRU entry is the one whose row is all 0s
// and column is all 1s (i.e., it lost every pairwise comparison).

module lru_tracker
    import mmu_pkg::*;
#(
    parameter int NUM_ENTRIES = TLB_ENTRIES
) (
    input  logic                          clk,
    input  logic                          srst,

    // Access interface — pulse access_valid when an entry is used
    input  logic                          access_valid,
    input  logic [$clog2(NUM_ENTRIES)-1:0] access_idx,

    // Replacement output — which entry to evict
    output logic [$clog2(NUM_ENTRIES)-1:0] lru_idx
);

    localparam int IDX_W = $clog2(NUM_ENTRIES);

    // NxN matrix — matrix[i][j] = 1 means i was used more recently than j
    logic [NUM_ENTRIES-1:0] matrix [NUM_ENTRIES];

    // Update matrix on access
    always_ff @(posedge clk) begin
        if (srst) begin
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                matrix[i] <= '0;
            end
        end else if (access_valid) begin
            // Set row access_idx to all 1s (accessed entry beats everyone)
            for (int j = 0; j < NUM_ENTRIES; j++) begin
                matrix[access_idx][j] <= (j != access_idx) ? 1'b1 : 1'b0;
            end
            // Set column access_idx to all 0s (everyone loses to accessed entry)
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                if (i != access_idx) begin
                    matrix[i][access_idx] <= 1'b0;
                end
            end
        end
    end

    // Find LRU: entry whose row is all zeros (loses every comparison)
    always_comb begin
        lru_idx = '0;
        for (int i = NUM_ENTRIES - 1; i >= 0; i--) begin
            if (matrix[i] == '0) begin
                lru_idx = IDX_W'(i);
            end
        end
    end

endmodule
