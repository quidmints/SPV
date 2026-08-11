#!/usr/bin/env bash
RPC="${RPC:?}"
H=0x0000005bb4DF4109bF356a585C8b8Ea70FCbAaC0
T=0x76c4350174727086805a3b026998a38a23dec4eaa173f2eb5449eb961e69c043

echo "-- all logs from the hook at its init block, errors visible"
cast logs --from-block 25589883 --to-block 25589883 --address $H --rpc-url $RPC

echo "-- same, with the assumed topic0"
cast logs --from-block 25589883 --to-block 25589883 --address $H $T --rpc-url $RPC

echo "-- raw json, bypassing cast arg parsing"
cast rpc eth_getLogs '{"fromBlock":"0x1868C1B","toBlock":"0x1868C1B","address":"0x0000005bb4df4109bf356a585c8b8ea70fcbaac0"}' --rpc-url $RPC
