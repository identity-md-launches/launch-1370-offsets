// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev Stands in for the network's seat NFT in tests. Anyone may mint; production seats are the
/// requester's own NFT, configured after launch.
contract MockSeats is ERC721 {
    constructor() ERC721("Seat", "SEAT") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function burn(uint256 id) external {
        _burn(id);
    }
}
