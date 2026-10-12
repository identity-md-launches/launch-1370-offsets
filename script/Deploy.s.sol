// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {OffsetsToken} from "../src/OffsetsToken.sol";
import {OffsetsRegistry} from "../src/OffsetsRegistry.sol";

/// @title Deploy
/// @notice Reference deployment for a local chain or a test network. The production launch does
/// not use this: the IMD factory deploys both contracts from their bytecode with the manifest's
/// constructor arguments. `deploy` takes its configuration as an argument so tests call it directly;
/// only `run` reads the environment.
contract Deploy is Script {
    struct Config {
        /// @dev Owner of the registry: the launch's owner, never the deployer wallet by default.
        address owner;
    }

    /// @notice Deploys the token (its whole supply to the broadcaster) and the registry owned by `cfg.owner`.
    function deploy(Config memory cfg) public returns (OffsetsToken token, OffsetsRegistry registry) {
        token = new OffsetsToken();
        registry = new OffsetsRegistry(cfg.owner, address(token));
    }

    /// @notice Reads OFFSETS_OWNER from the environment and broadcasts the deployment.
    function run() external returns (OffsetsToken token, OffsetsRegistry registry) {
        Config memory cfg = Config({owner: vm.envAddress("OFFSETS_OWNER")});
        vm.startBroadcast();
        (token, registry) = deploy(cfg);
        vm.stopBroadcast();
    }
}
