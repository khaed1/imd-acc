#!/usr/bin/env bash
# Fork only: answer the open question of a project as the oracle would, or fail it.
# usage: fork-answer.sh <project> yes|no|fail
set -euo pipefail
export PATH=$HOME/.foundry/bin:$PATH
F=${ANVIL:-http://127.0.0.1:8545}
# The test run 6 registry (launch #1463) by default; REG=0x… for another one.
REG=${REG:-0x30a3bb4d75989cb19f83607abc2dffe52a253384}
INTAKE=0xa43e6f75ee006411f79ac1c84120606c2330de82
TESTKEY=0x00000000000000000000000000000000000000000000000000000000000a11ce
SIGNER=$(cast wallet address --private-key $TESTKEY)
cast rpc anvil_setStorageAt $REG 0x2 $(cast abi-encode "f(address)" $SIGNER) --rpc-url $F >/dev/null
cast rpc anvil_impersonateAccount $INTAKE --rpc-url $F >/dev/null
cast rpc anvil_setBalance $INTAKE 0x56BC75E2D63100000 --rpc-url $F >/dev/null
ID=$(cast call $REG "projectOf(address)((uint8,bool,uint16,uint64,uint64,uint64,address,uint64,address,bytes32))" $1 --rpc-url $F | tr -d '()' | awk -F', ' '{print $10}')
if [ "$2" = fail ]; then
  cast send $REG "onOracleFailure(bytes32,uint8,bytes32,uint16,uint16,bytes)" $ID 2 $(cast format-bytes32-string split) 15 7 0x --from $INTAKE --unlocked --rpc-url $F | grep -E "^status"
  exit 0
fi
[ "$2" = yes ] && ANS=$(cast abi-encode "f(bool)" true) || ANS=$(cast abi-encode "f(bool)" false)
NOW=$(cast block latest --field timestamp --rpc-url $F)
RID=0x$(openssl rand -hex 16)00000000000000000000000000000000
T="($RID,1,0x0000000000000000000000000000000000000000000000000000000000000000,0,$ANS,0,0,0,0x0000000000000000000000000000000000000000000000000000000000000000,0x0000000000000000000000000000000000000000000000000000000000000000,15,11,15,$NOW,$((NOW+86400)))"
TT="(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64)"
D=$(cast call $REG "attestationDigest($TT)(bytes32)" "$T" --rpc-url $F)
SIG=$(cast wallet sign --no-hash $D --private-key $TESTKEY)
cast send $REG "onOracleResult(bytes32,$TT,bytes)" $ID "$T" $SIG --from $INTAKE --unlocked --rpc-url $F | grep -E "^status"
