#!/bin/bash
# Brendan Lynskey 2025
# Master CocoTB runner for MMU
# Usage: ./run_cocotb.sh [module|all]

set -e

cd "$(dirname "$0")/../tb/cocotb"

declare -A MAKEFILES
MAKEFILES=(
    [lru_tracker]="Makefile.lru"
    [permission_checker]="Makefile.perm"
    [tlb]="Makefile.tlb"
    [page_table_walker]="Makefile.ptw"
    [mmu_top]="Makefile.mmu"
)

run_module() {
    local name=$1
    local makefile=${MAKEFILES[$name]}

    echo "=== CocoTB: $name ==="
    rm -rf sim_build results.xml
    if make -f "$makefile" 2>&1 | tee /dev/stderr | grep -q "FAIL"; then
        echo "--- $name: FAILED ---"
        return 1
    else
        echo "--- $name: PASSED ---"
        return 0
    fi
}

if [ $# -eq 0 ] || [ "$1" = "all" ]; then
    TOTAL=0
    PASSED=0
    FAILED=0
    for mod in lru_tracker permission_checker tlb page_table_walker mmu_top; do
        TOTAL=$((TOTAL + 1))
        if run_module "$mod"; then
            PASSED=$((PASSED + 1))
        else
            FAILED=$((FAILED + 1))
        fi
        echo ""
    done
    echo "=============================="
    echo "Total: $TOTAL  Passed: $PASSED  Failed: $FAILED"
    if [ "$FAILED" -gt 0 ]; then
        exit 1
    fi
elif [ -n "${MAKEFILES[$1]}" ]; then
    run_module "$1"
else
    echo "Unknown module: $1"
    echo "Available: ${!MAKEFILES[*]}"
    echo "Usage: $0 [module|all]"
    exit 1
fi
