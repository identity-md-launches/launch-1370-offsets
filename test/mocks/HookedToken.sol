// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITokenReceiver {
    function onTokenReceived(address from, uint256 amount) external;
}

/// @dev An ERC-20 that notifies contract recipients on every transfer. OFFSETS itself has no such
/// hook; this models a token with one so the registry's reentrancy guard can be exercised for real.
contract HookedToken is ERC20 {
    constructor() ERC20("Hooked", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to.code.length > 0) ITokenReceiver(to).onTokenReceived(from, value);
    }
}
