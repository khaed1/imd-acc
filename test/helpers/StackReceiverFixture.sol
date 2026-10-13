// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StackReceiver, IStakedIMD} from "src/multichain/StackReceiver.sol";
import {MockOFT} from "../mocks/MockOFT.sol";
import {TestSIMD} from "../mocks/TestSIMD.sol";
import {QueuedComposeEndpoint} from "../mocks/QueuedComposeEndpoint.sol";

abstract contract StackReceiverFixture is Test {
    uint32 internal constant RH_EID = 30416;
    uint256 internal constant BRIDGE_STEP = 1e12;
    MockOFT internal imd;
    TestSIMD internal vault;
    QueuedComposeEndpoint internal endpoint;
    StackReceiver internal receiver;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal executor;

    function setUp() public virtual {
        vm.roll(1_000);
        alice = makeAddr("receiver alice");
        bob = makeAddr("receiver bob");
        carol = makeAddr("receiver carol");
        executor = makeAddr("compose executor");
        imd = new MockOFT();
        vault = new TestSIMD(address(imd), address(this));
        endpoint = new QueuedComposeEndpoint();
        receiver =
            new StackReceiver(IERC20(address(imd)), IStakedIMD(address(vault)), address(endpoint));
    }

    /// @dev Build the wire format independently of the production OFTComposeMsg decoder.
    function _packet(
        uint64 nonce,
        uint32 eid,
        uint256 amount,
        bytes32 composeFrom,
        bytes memory payload
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(nonce, eid, amount, composeFrom, payload);
    }

    function _pair(uint256 first, uint256 second) internal view returns (bytes memory) {
        address[] memory traders = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        traders[0] = alice;
        traders[1] = bob;
        amounts[0] = first;
        amounts[1] = second;
        return abi.encode(traders, amounts);
    }

    function _queue(bytes32 guid, uint256 amount, bytes memory payload)
        internal
        returns (bytes memory message)
    {
        message = _packet(1, RH_EID, amount, bytes32(uint256(uint160(carol))), payload);
        _arrive(guid, amount, message);
    }

    function _arrive(bytes32 guid, uint256 amount, bytes memory message) internal {
        imd.mint(address(receiver), amount);
        vm.prank(address(imd));
        endpoint.sendCompose(address(receiver), guid, 0, message);
    }

    function _compose(bytes32 guid, bytes memory message) internal {
        vm.prank(executor);
        endpoint.lzCompose(address(imd), address(receiver), guid, 0, message, "executor metadata");
    }

    function _queueHash(bytes32 guid) internal view returns (bytes32) {
        return endpoint.composeQueue(address(imd), address(receiver), guid, 0);
    }

    /// @dev Includes initialization, balances, share hold stamps, counters and queue state so
    /// a rejected compose cannot quietly leave an earlier trader paid or the queue consumed.
    function _state(bytes32 guid) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                imd.balanceOf(address(receiver)),
                imd.balanceOf(address(vault)),
                imd.balanceOf(alice),
                imd.balanceOf(bob),
                vault.balanceOf(alice),
                vault.balanceOf(bob),
                vault.totalSupply(),
                vault.lastDepositBlock(alice),
                vault.lastDepositBlock(bob),
                imd.allowance(address(receiver), address(vault)),
                receiver.totalDelivered(),
                receiver.deliveredFrom(RH_EID),
                _queueHash(guid)
            )
        );
    }
}
