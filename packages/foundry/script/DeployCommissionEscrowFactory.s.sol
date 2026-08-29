// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployHelpers.s.sol";
import { CommissionEscrowFactory } from "../contracts/CommissionEscrowFactory.sol";

/**
 * @notice Deploy script for {CommissionEscrowFactory}.
 * @dev Inherits ScaffoldETHDeploy which:
 *      - Includes forge-std/Script.sol for deployment
 *      - Includes ScaffoldEthDeployerRunner modifier
 *      - Provides `deployer` variable
 *
 * The `deployer` account is granted both `DEFAULT_ADMIN_ROLE` (so it can grant/revoke
 * `ARBITER_ROLE` for other addresses later) and `ARBITER_ROLE` itself (so there is at least one
 * working arbiter as soon as the factory is live) - see the factory's constructor.
 *
 * Example:
 * yarn deploy --file DeployCommissionEscrowFactory.s.sol            # local anvil chain
 * yarn deploy --file DeployCommissionEscrowFactory.s.sol --network baseSepolia # live network
 */
contract DeployCommissionEscrowFactory is ScaffoldETHDeploy {
    /**
     * @dev Deployer setup based on `ETH_KEYSTORE_ACCOUNT` in `.env`:
     *      - "scaffold-eth-default": Uses Anvil's account #9, no password prompt
     *      - "scaffold-eth-custom": requires password used while creating keystore
     *
     * Note: Must use ScaffoldEthDeployerRunner modifier to:
     *      - Setup correct `deployer` account and fund it
     *      - Export contract addresses & ABIs to the `nextjs` package
     */
    function run() external ScaffoldEthDeployerRunner {
        new CommissionEscrowFactory(deployer);
    }
}
