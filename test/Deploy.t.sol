// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {OffsetsToken} from "../src/OffsetsToken.sol";
import {OffsetsRegistry} from "../src/OffsetsRegistry.sol";

contract DeployTest is Test {
    address owner = makeAddr("owner");

    function test_deployWiresTokenAndRegistry() public {
        Deploy deployer = new Deploy();
        (OffsetsToken token, OffsetsRegistry registry) = deployer.deploy(Deploy.Config({owner: owner}));

        assertEq(token.totalSupply(), 1_000_000_000 * 1e18);
        assertEq(token.balanceOf(address(deployer)), token.totalSupply(), "supply goes to the deploying contract");
        assertEq(address(registry.OFFSETS()), address(token));
        assertEq(registry.owner(), owner);
        assertFalse(registry.isConfigured(), "nothing is configured at deployment");
    }
}
