// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OffsetsToken} from "../../src/OffsetsToken.sol";

/// @dev Moves OFFSETS between a fixed set of actors with transfer, approve and transferFrom, in
/// random order and with amounts at and beyond each actor's balance and allowance. Every call's
/// success is predicted from a ghost model and the outcome asserted.
contract OffsetsTokenHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 * 1e18;
    OffsetsToken public immutable token;
    address[] public actors;

    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => uint256) public ghostBalance;

    constructor() {
        token = new OffsetsToken();
        actors.push(address(this));
        for (uint256 i; i < 5; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
        ghostBalance[address(this)] = SUPPLY;
        // Seed the other actors so transfers have something to move.
        for (uint256 i = 1; i < actors.length; ++i) {
            token.transfer(actors[i], 1_000_000e18);
            ghostBalance[address(this)] -= 1_000_000e18;
            ghostBalance[actors[i]] += 1_000_000e18;
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _amount(uint256 seed, uint256 cap) internal pure returns (uint256) {
        uint256 r = seed % 6;
        if (r == 0) return 0;
        if (r == 1) return cap;
        if (r == 2) return cap + 1;
        return bound(seed, 0, cap);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool toZero) external {
        address from = actors[fromSeed % actors.length];
        address to = toZero ? address(0) : actors[toSeed % actors.length];
        uint256 amount = _amount(amountSeed, token.balanceOf(from));
        bool expectOk = to != address(0) && amount <= ghostBalance[from];
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            assertTrue(ok, "transfer returned false");
            assertTrue(expectOk, "transfer succeeded unexpectedly");
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
        } catch {
            assertFalse(expectOk, "transfer reverted unexpectedly");
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool infinite) external {
        address owner_ = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 amount = infinite ? type(uint256).max : bound(amountSeed, 0, SUPPLY);
        vm.prank(owner_);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner_][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner_ = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowance_ = ghostAllowance[owner_][spender];
        uint256 cap = allowance_ < ghostBalance[owner_] ? allowance_ : ghostBalance[owner_];
        uint256 amount = _amount(amountSeed, cap);
        bool expectOk = amount <= allowance_ && amount <= ghostBalance[owner_];
        vm.prank(spender);
        try token.transferFrom(owner_, to, amount) returns (bool ok) {
            assertTrue(ok, "transferFrom returned false");
            assertTrue(expectOk, "transferFrom succeeded unexpectedly");
            ghostBalance[owner_] -= amount;
            ghostBalance[to] += amount;
            if (allowance_ != type(uint256).max) ghostAllowance[owner_][spender] = allowance_ - amount;
        } catch {
            assertFalse(expectOk, "transferFrom reverted unexpectedly");
        }
    }
}

/// @notice The token holds every holder's balance, so its conservation laws are checked over random
/// sequences of transfers, approvals and delegated transfers.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract OffsetsTokenInvariantTest is Test {
    OffsetsTokenHandler handler;
    OffsetsToken token;

    function setUp() public {
        handler = new OffsetsTokenHandler();
        token = handler.token();
        targetContract(address(handler));
    }

    function invariant_supplyNeverChanges() public view {
        assertEq(token.totalSupply(), handler.SUPPLY());
        assertEq(token.TOTAL_SUPPLY(), handler.SUPPLY());
    }

    function invariant_balancesSumToSupply() public view {
        uint256 n = handler.actorsLength();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "a balance drifted from the model");
            sum += token.balanceOf(a);
        }
        assertEq(sum, handler.SUPPLY(), "the actors' balances do not add up to the supply");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
    }

    function invariant_allowancesMatchModel() public view {
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address o = handler.actors(i);
                address s = handler.actors(j);
                assertEq(token.allowance(o, s), handler.ghostAllowance(o, s), "an allowance drifted from the model");
            }
        }
    }
}
