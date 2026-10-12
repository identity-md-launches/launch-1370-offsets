// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev A seat NFT that answers `ownerOf` with the zero address for ids it does not know instead of
/// reverting, the pre-OpenZeppelin-v5 behaviour the registry says it tolerates. Only `ownerOf` is
/// implemented: the registry reads nothing else from the seat NFT.
contract ZeroOwnerSeats {
    mapping(uint256 => address) private _owners;

    function mint(address to, uint256 id) external {
        _owners[id] = to;
    }

    function burn(uint256 id) external {
        delete _owners[id];
    }

    function ownerOf(uint256 id) external view returns (address) {
        return _owners[id];
    }
}
