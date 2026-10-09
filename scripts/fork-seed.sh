#!/usr/bin/env bash
# Seeds a local anvil fork (started with --auto-impersonate) with test balances for the frontend.
# Tokens are moved out of real Uniswap v3 pools by impersonation, which only works on a local fork.
# Usage: scripts/fork-seed.sh <rpc-url> <user-address> <deployment-json>
set -euo pipefail
RPC=${1:-http://127.0.0.1:8545}
USER_ADDR=$2
DEP=${3:-contracts/deployments/31337.json}

USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
POOL=$(python -c "import json,sys;print(json.load(open('$DEP'))['lenderPool'])")
LENDER=$(cast to-check-sum-address $(cast keccak "holdcredit-fork-lender" | cut -c1-42))

fund_eth() { cast rpc anvil_setBalance "$1" 0x8AC7230489E80000 --rpc-url "$RPC" > /dev/null; }
take() { # token source to amount
  fund_eth "$2"
  cast send "$1" "transfer(address,uint256)" "$3" "$4" --from "$2" --unlocked --rpc-url "$RPC" > /dev/null
}

fund_eth "$USER_ADDR"
fund_eth "$LENDER"
CRCL_POOL=0x654E4143e82a5824445Ade0824351C2A9ACD95a8   # deepest USDG source
take $USDG $CRCL_POOL "$USER_ADDR" 50000000000                 # 50,000 USDG
take $USDG $CRCL_POOL "$LENDER" 500000000000                   # 500,000 USDG
take 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3 "$USER_ADDR" 50000000000000000000   # 50 NVDA
take 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C 0xa7Bb1AC63BBaB0C44316E6c8C455213441689167 "$USER_ADDR" 10000000000000000000   # 10 SPY
take 0x322F0929c4625eD5bAd873c95208D54E1c003b2d 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3 "$USER_ADDR" 20000000000000000000   # 20 TSLA
take 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 0xaae0D815eE56E4092a5E5C2911e676FeA50B2d6D "$USER_ADDR" 30000000000000000000   # 30 AAPL

# Lender liquidity
cast send $USDG "approve(address,uint256)" "$POOL" 500000000000 --from "$LENDER" --unlocked --rpc-url "$RPC" > /dev/null
cast send "$POOL" "deposit(uint256,address)" 500000000000 "$LENDER" --from "$LENDER" --unlocked --rpc-url "$RPC" > /dev/null

echo "seeded user $USER_ADDR and lender $LENDER on $RPC"
echo "pool totalAssets: $(cast call "$POOL" 'totalAssets()(uint256)' --rpc-url "$RPC")"
