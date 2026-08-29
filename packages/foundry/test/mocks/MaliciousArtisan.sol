// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { CommissionEscrow } from "../../contracts/CommissionEscrow.sol";

/**
 * @title MaliciousArtisan
 * @notice Test-only contract that plays the role of a dishonest artisan trying to drain a
 * {CommissionEscrow} by re-entering `release()` from the `receive()` hook that fires when it gets
 * paid - exactly what a real attacker would attempt.
 * @dev Used by `CommissionEscrow.t.sol` to prove that `release()`'s `nonReentrant` guard (plus the
 * Checks-Effects-Interactions ordering that flips `status` to `ORDER_FULFILLED` before sending
 * ETH) actually stops a second payout from happening in the same call stack.
 */
contract MaliciousArtisan {
    CommissionEscrow public escrow;

    /// @notice Set to true the first (and only) time `receive()` attempts a reentrant call.
    bool public reentrancyAttempted;

    /// @notice Would be true only if the reentrant `release()` call had (incorrectly) succeeded.
    bool public reentrancySucceeded;

    function setEscrow(CommissionEscrow _escrow) external {
        escrow = _escrow;
    }

    receive() external payable {
        if (!reentrancyAttempted) {
            reentrancyAttempted = true;
            // solhint-disable-next-line no-empty-blocks
            try escrow.release() {
                reentrancySucceeded = true;
            } catch {
                reentrancySucceeded = false;
            }
        }
    }
}
