// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OffsetsToken} from "../src/OffsetsToken.sol";

/// @dev Deploys the token the way the launch factory does: from a contract that then holds the supply.
contract FactoryStub {
    function deploy() external returns (OffsetsToken) {
        return new OffsetsToken();
    }
}

contract OffsetsTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    FactoryStub factory;
    OffsetsToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        factory = new FactoryStub();
        token = factory.deploy();
    }

    function test_metadata() public view {
        assertEq(token.name(), "OFFSETS");
        assertEq(token.symbol(), "OFFSETS");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_transferMovesExactAmount() public {
        vm.prank(address(factory));
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(address(factory)), SUPPLY - 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromRespectsAllowance() public {
        vm.prank(address(factory));
        token.transfer(alice, 500e18);

        vm.prank(alice);
        token.approve(bob, 200e18);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 200e18));
        assertEq(token.balanceOf(bob), 200e18);
        assertEq(token.allowance(alice, bob), 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_transferRevertsWhenBalanceInsufficient() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    /// @dev The token exposes no privileged surface: none of the usual admin selectors exist, so
    /// nothing can grow the supply or freeze a holder after launch.
    function test_noAdminSurface() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setMinter(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(address(factory));
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, type(uint128).max));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4 && op != 0xF2 && op != 0xFF, "forbidden opcode");
        }
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(factory));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(address(factory));
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
