// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title OFFSETS
/// @notice The OFFSETS launch token: a plain ERC-20 with a fixed supply of 1,000,000,000 tokens
/// (18 decimals), minted once to the deployer in the constructor.
/// @dev Deliberately minimal. There is no owner, no mint path, no pause, no blocklist, no fee and
/// no burn-from: nothing can grow the supply after launch and nothing but a holder's own signature
/// can move or freeze a holder's balance. The launch factory is the deployer, so the whole supply
/// lands with it and it distributes the swarm share, seeds the pool and forwards the remainder.
/// Holders may still shrink the supply by sending to a dead address; the contract itself exposes
/// no burn so that no privileged hand can.
contract OffsetsToken is ERC20 {
    /// @notice The fixed, final supply in minor units: one billion tokens at 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    constructor() ERC20("OFFSETS", "OFFSETS") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
