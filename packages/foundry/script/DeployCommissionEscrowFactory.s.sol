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
 * The `deployer` account is always granted `DEFAULT_ADMIN_ROLE` (so it can grant/revoke
 * `ARBITER_ROLE` for other addresses later). `ARBITER_ROLE` itself goes to whatever address is set
 * in the `INITIAL_ARBITER` environment variable, or falls back to `deployer` if that variable is
 * unset - so there is always at least one working arbiter as soon as the factory is live, but a
 * real deployment can hand day-to-day dispute resolution to a separate address (e.g. a multisig)
 * from the start. The starting {CommissionEscrowFactory-arbiterThreshold} (how many matching
 * arbiter votes a dispute needs to finalize) comes from `INITIAL_ARBITER_THRESHOLD`, defaulting to
 * `1` if unset - a fresh deployment only has one arbiter, so requiring more than one vote out of
 * the box would leave every dispute permanently stuck until `setArbiterThreshold` is called. Raise
 * it once more arbiters have been granted `ARBITER_ROLE`. See the factory's constructor.
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
        address initialArbiter = vm.envOr("INITIAL_ARBITER", deployer);
        uint256 initialArbiterThreshold = vm.envOr("INITIAL_ARBITER_THRESHOLD", uint256(1));
        new CommissionEscrowFactory(deployer, initialArbiter, initialArbiterThreshold);
    }
}
