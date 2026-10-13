#!/usr/bin/env bash
# Checks the snapshot builder: its event topics and selectors against `cast`, then on a local Sepolia fork
# (anvil on :8545) a listing, points, a delisting and points stopping. Nothing is sent to live Sepolia.
# usage: anvil --fork-url https://rpc.sepolia.ethpandaops.io --chain-id 11155111 --port 8545 & tools/snapshot/test.sh
set -euo pipefail
export PATH=$HOME/.foundry/bin:$PATH
cd "$(dirname "$0")/../.."
F=${ANVIL:-http://127.0.0.1:8545}
B=tools/snapshot/build.mjs
fail() { echo "FAIL $*"; exit 1; }

for e in "Stacked(address,address,uint256,uint256)" "Applied(address,address,bytes32,uint16,address,string,string)" "Listed(address,uint16,address,uint64,bytes32)" "Rejected(address,bytes32)" "Challenged(address,address,bytes32,string)" "Defended(address,uint256,bytes32)" "Delisted(address,uint64,bytes32)" "AskCleared(address,bytes32,uint8,uint8,bytes32)" "BeneficiarySet(address,address)" "Queued(address,address,address,uint256)" "Delivering(bytes32,address,uint256,uint256)"; do
  grep -q "$(cast keccak "$e")" $B || fail "topic $e"
done
for f in "IMD()" "SIMD()" "totalStacked()" "projectStacked(address)" "projectShares(address)" "decimals()" "VAULT()" "RECEIVER()" "totalQueued()" "projectQueued(address)" "waiting(address)"; do
  grep -q "\"$(cast sig "$f")\"" $B || fail "selector $f"
done
echo "PASS topics and selectors"

W=0x4b91078b2374c956a65f7af0999cae0a935e6821            # the test wallet, impersonated on the fork
REG=0x30a3bb4d75989cb19f83607abc2dffe52a253384
SC=0x3d1778be5f9e55f0df35acaf64a13efe2fe81488            # SelfCredit: its owner credits its own IMD
FT=0x44a1cd38474fb1748400e7deb5f8d786cce3f89a
OUT=$(mktemp -d)
cast rpc anvil_impersonateAccount $W --rpc-url $F >/dev/null
cast rpc anvil_setBalance $W 0x56BC75E2D63100000 --rpc-url $F >/dev/null
send() { cast send "$@" --from $W --unlocked --rpc-url $F >/dev/null; }
snap() { node $B --rpc $F --confirmations 0 --out $OUT >/dev/null; }
q() { python3 -c "import json,sys; d=json.load(open('$OUT/sepolia.json')); print($1)"; }

snap
base=$(q "d['totals']['points']")
send $FT "mint(address,uint256)" $W 20000000000000000000
send $FT "approve(address,uint256)" $REG 500000000000000000
send $REG "applyListing(address,string,string,uint16,address)" $SC "SelfCredit trial" "https://repo.sourcify.dev/11155111/0x3D1778bE5f9E55f0dF35ACAF64A13Efe2FE81488" 50 $W
snap
[ "$(q "next(p['status'] for p in d['projects'] if p['address']=='$SC')")" = applied ] || fail "status applied"
bash tools/site-check/fork-answer.sh $SC yes >/dev/null
send $SC "creditTo(address[],uint256)" "[$W]" 1000000000000000000
snap
[ "$(q "next(p['status'] for p in d['projects'] if p['address']=='$SC')")" = listed ] || fail "status listed"
[ "$(q "next(p['points'] for p in d['projects'] if p['address']=='$SC')")" = 1000000000000000000 ] || fail "project points after a listed credit"
[ "$(q "next(t['projects']['$SC']['points'] for t in d['traders'] if t['address']=='$W')")" = 1000000000000000000 ] || fail "trader points"
[ "$(q "int(d['totals']['points']) - $base")" = 1000000000000000000 ] || fail "total points"
echo "PASS listed: a credit earns 1 point per IMD, the earlier credit none"

cast rpc evm_increaseTime 3601 --rpc-url $F >/dev/null; cast rpc evm_mine --rpc-url $F >/dev/null
send $FT "approve(address,uint256)" $REG 5500000000000000000
send $REG "challengeForBeneficiary(address,string,address)" $SC "test challenge" $W
bash tools/site-check/fork-answer.sh $SC no >/dev/null
send $SC "creditTo(address[],uint256)" "[$W]" 2000000000000000000
snap
[ "$(q "next(p['status'] for p in d['projects'] if p['address']=='$SC')")" = delisted ] || fail "status delisted"
[ "$(q "next(p['periods'][0]['to'] is not None for p in d['projects'] if p['address']=='$SC')")" = True ] || fail "period closed"
[ "$(q "next(p['points'] for p in d['projects'] if p['address']=='$SC')")" = 1000000000000000000 ] || fail "points stop after delisting"
[ "$(q "next(p['imd'] for p in d['projects'] if p['address']=='$SC')")" = 4000000000000000000 ] || fail "all IMD still counted"
echo "PASS delisted: points stop, the IMD is still counted, totals match the Stacker"

# Robinhood Chain (optional): RH_ANVIL is a fork of Robinhood Chain from its official RPC (the one that
# serves old logs), e.g. anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8546.
# A trade on the listed RemoteTrialVenue queues cashback that earns points; a flush moves it from
# waiting to delivered, and the file still matches totalQueued, projectQueued and waiting().
if [ -n "${RH_ANVIL:-}" ]; then
  RS=0x4de07c2fa46d5d6ed9ceb3f38ec56d3461b3e898
  VENUE=0x81d17894b724dcb462bd5585be0792b1b32d19cc
  RIMD=0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127
  RCH=$(mktemp)
  python3 -c "import json; print(json.dumps([c for c in json.load(open('tools/snapshot/chains.json')) if c['name']=='robinhood']))" > $RCH
  rsend() { cast send "$@" --from $W --unlocked --rpc-url $RH_ANVIL >/dev/null; }
  rsnap() { node $B --chains $RCH --rpc $RH_ANVIL --confirmations 0 --out $OUT | grep -q "robinhood: blocks" || fail "robinhood build"; }
  rq() { python3 -c "import json,sys; d=json.load(open('$OUT/robinhood.json')); print($1)"; }
  cast rpc anvil_impersonateAccount $W --rpc-url $RH_ANVIL >/dev/null
  cast rpc anvil_setBalance $W 0x56BC75E2D63100000 --rpc-url $RH_ANVIL >/dev/null
  rsnap
  before=$(rq "d['totals']['points']")
  [ "$(rq "next(p['status'] for p in d['projects'] if p['address']=='$VENUE')")" = listed ] || fail "venue listed"
  rsend $RIMD "approve(address,uint256)" $VENUE 100000000000000000
  rsend $VENUE "buy(uint256,uint256)" 100000000000000000 0
  rsnap
  [ "$(rq "int(d['totals']['points']) - $before")" = 500000000000000 ] || fail "a listed trade earns its 0.5% cashback as points"
  [ "$(rq "next(t['points'] for t in d['traders'] if t['address']=='$W')")" = "$(rq "d['totals']['points']")" ] || fail "trader points"
  w0=$(rq "d['totals']['waiting']")
  fee=$(cast call $RS "quoteFlush(address[])(uint256,uint256,address[],uint256[],uint256)" "[$W]" --rpc-url $RH_ANVIL | tail -1 | awk '{print $1}')
  rsend $RS "flush(address[])" "[$W]" --value $((fee * 2))
  rsnap
  [ "$(rq "int(d['totals']['waiting']) < $w0 and int(d['totals']['delivered']) > 0")" = True ] || fail "flush moves waiting to delivered"
  echo "PASS robinhood: Queued credits earn points from the listing block; a flush leaves waiting for delivered; totals match"
fi
