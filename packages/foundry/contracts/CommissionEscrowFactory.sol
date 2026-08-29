// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CommissionEscrow } from "./CommissionEscrow.sol";

/**
 * @title CommissionEscrowFactory
 * @author Kalpana & the Berlin collector's engineers (built for the commission-escrow challenge)
 * @notice Entry point of the whole system. A collector calls {createCommission} here (sending the
 * agreed price as `msg.value`) to spin up a brand-new, independent {CommissionEscrow} for a single
 * deal with a single artisan. This contract also doubles as:
 *   1. A cheap deployment mechanism - every new commission is an EIP-1167 minimal proxy ("clone")
 *      pointing at one shared {CommissionEscrow} implementation, instead of a full contract
 *      deployment, which saves the vast majority of the gas a `new CommissionEscrow(...)` call
 *      would otherwise cost.
 *   2. The arbiter registry - an `AccessControl` role (`ARBITER_ROLE`) that any commission clone
 *      can check to decide whether `msg.sender` is allowed to resolve a dispute. Approving an
 *      arbiter here makes them able to resolve *any* disputed commission created by this factory.
 *   3. The dispute "marketplace" - a public, always-up-to-date list of every commission that is
 *      currently disputed, so an arbiter can simply browse {getDisputedCommissions} to find work
 *      (and earn the 1% resolution fee described in {CommissionEscrow-resolveDispute}).
 *
 * @dev DEFAULT_ADMIN_ROLE (granted to the address passed into the constructor - see
 * `DeployCommissionEscrowFactory.s.sol`) is the only role that can grant/revoke `ARBITER_ROLE`, via
 * the standard `AccessControl.grantRole` / `revokeRole` functions inherited below. There is
 * intentionally no custom "addArbiter" function - `AccessControl`'s own functions already do
 * exactly that, correctly, and reusing them means less custom code to get wrong.
 */
contract CommissionEscrowFactory is AccessControl {
    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Role identifier for addresses allowed to resolve disputed commissions. Must match the
    /// constant of the same name in {CommissionEscrow} - both are `keccak256("ARBITER_ROLE")`, so a
    /// role granted here is recognised by every commission clone.
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @notice The one-off {CommissionEscrow} contract every new commission is cloned from. Deployed
    /// once, in this factory's constructor, and then never touched directly again - all real
    /// commissions live in clones pointing at this address.
    address public immutable escrowImplementation;

    /// @notice Every commission clone this factory has ever created, in creation order.
    address[] public allCommissions;

    /// @notice Every commission a given collector has opened.
    mapping(address collector => address[] commissions) public commissionsByCollector;

    /// @notice Every commission a given artisan has been commissioned for.
    mapping(address artisan => address[] commissions) public commissionsByArtisan;

    /// @notice `true` for any address this factory has cloned - lets us verify that a caller
    /// reporting a dispute (via {notifyDisputed} / {notifyDisputeSettled}) is a real commission this
    /// factory created, and not an arbitrary address trying to spam the disputed-commissions list.
    mapping(address commission => bool isCommission) public isCommission;

    /// @notice Every commission currently sitting in `ORDER_DISPUTED`, i.e. the "marketplace" of
    /// deals waiting for an arbiter. Kept in sync by {notifyDisputed} / {notifyDisputeSettled}, which
    /// only a real commission clone can call.
    address[] public disputedCommissions;

    /// @dev `disputedCommissions` index (plus one, so `0` can mean "not listed") for O(1)
    /// swap-and-pop removal in {notifyDisputeSettled}.
    mapping(address commission => uint256 indexPlusOne) private _disputedIndexPlusOne;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    /// @notice Emitted every time a new commission escrow is created and funded.
    event CommissionCreated(
        address indexed commission, address indexed collector, address indexed artisan, uint256 amount, uint256 deadline
    );

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /**
     * @param admin Address granted `DEFAULT_ADMIN_ROLE` (able to grant/revoke `ARBITER_ROLE`) and, as
     * a convenience so the system has at least one working arbiter immediately after deployment,
     * `ARBITER_ROLE` itself. In production you would typically grant `ARBITER_ROLE` to a multisig or
     * DAO instead of/in addition to a single EOA.
     */
    constructor(address admin) {
        require(admin != address(0), "CommissionEscrowFactory: admin is the zero address");

        escrowImplementation = address(new CommissionEscrow());

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ARBITER_ROLE, admin);
    }

    // ---------------------------------------------------------------------------------------------
    // Commission creation
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Opens a new commission for `artisan`, locking `msg.value` into a freshly-cloned
     * {CommissionEscrow} immediately.
     * @dev Deploys an EIP-1167 minimal proxy via {Clones-clone} (cheap: ~45k gas instead of the full
     * cost of deploying {CommissionEscrow}'s bytecode again), then immediately forwards the entire
     * `msg.value` into that clone's `initialize` function. The clone records `msg.value` as its
     * `amount` itself, so the amount locked always matches the ETH actually transferred - this
     * function never passes a separately-chosen "amount" the clone would have to trust blindly.
     * @param artisan The seller who is being commissioned. Cannot be the zero address or the caller.
     * @param deadline Unix timestamp after which, if delivery has not been confirmed and no dispute
     * is open, the collector can reclaim their funds.
     * @return commission The address of the newly created, funded {CommissionEscrow} clone.
     */
    function createCommission(address artisan, uint256 deadline) external payable returns (address commission) {
        require(msg.value > 0, "CommissionEscrowFactory: no commission amount sent");

        commission = Clones.clone(escrowImplementation);
        // `msg.sender` becomes the collector; `initialize` re-validates every argument (zero address,
        // artisan == collector, deadline in the past) so this factory does not have to duplicate those
        // checks.
        CommissionEscrow(payable(commission)).initialize{ value: msg.value }(
            msg.sender, artisan, deadline, address(this)
        );

        isCommission[commission] = true;
        allCommissions.push(commission);
        commissionsByCollector[msg.sender].push(commission);
        commissionsByArtisan[artisan].push(commission);

        emit CommissionCreated(commission, msg.sender, artisan, msg.value, deadline);
    }

    // ---------------------------------------------------------------------------------------------
    // Dispute marketplace bookkeeping (callable only by this factory's own commission clones)
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Adds `commission` to the public disputed-commissions list. Called automatically by a
     * {CommissionEscrow} clone from inside its own `raiseDispute()` - never call this directly.
     * @dev Reverts unless `msg.sender` both (a) is a commission this factory created and (b) equals
     * `commission`, so only a genuine escrow clone can register *itself* as disputed.
     */
    function notifyDisputed(address commission) external {
        require(
            isCommission[msg.sender] && msg.sender == commission,
            "CommissionEscrowFactory: caller is not a commission created by this factory"
        );
        require(
            _disputedIndexPlusOne[commission] == 0, "CommissionEscrowFactory: commission already listed as disputed"
        );

        disputedCommissions.push(commission);
        _disputedIndexPlusOne[commission] = disputedCommissions.length;
    }

    /**
     * @notice Removes `commission` from the public disputed-commissions list. Called automatically
     * by a {CommissionEscrow} clone from inside its own `resolveDispute()` - never call this
     * directly.
     * @dev Same caller restriction as {notifyDisputed}. Uses swap-and-pop so removal is O(1)
     * regardless of list size.
     */
    function notifyDisputeSettled(address commission) external {
        require(
            isCommission[msg.sender] && msg.sender == commission,
            "CommissionEscrowFactory: caller is not a commission created by this factory"
        );

        uint256 indexPlusOne = _disputedIndexPlusOne[commission];
        require(indexPlusOne != 0, "CommissionEscrowFactory: commission is not listed as disputed");

        uint256 indexToRemove = indexPlusOne - 1;
        uint256 lastIndex = disputedCommissions.length - 1;

        if (indexToRemove != lastIndex) {
            address lastCommission = disputedCommissions[lastIndex];
            disputedCommissions[indexToRemove] = lastCommission;
            _disputedIndexPlusOne[lastCommission] = indexToRemove + 1;
        }

        disputedCommissions.pop();
        delete _disputedIndexPlusOne[commission];
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Returns every commission this factory has ever created, in creation order.
    function getAllCommissions() external view returns (address[] memory) {
        return allCommissions;
    }

    /// @notice Returns every commission `collector` has opened.
    function getCommissionsByCollector(address collector) external view returns (address[] memory) {
        return commissionsByCollector[collector];
    }

    /// @notice Returns every commission `artisan` has been commissioned for.
    function getCommissionsByArtisan(address artisan) external view returns (address[] memory) {
        return commissionsByArtisan[artisan];
    }

    /// @notice Returns every commission currently awaiting arbiter resolution - the "marketplace" of
    /// disputed deals.
    function getDisputedCommissions() external view returns (address[] memory) {
        return disputedCommissions;
    }

    /// @notice Returns how many commissions this factory has created in total.
    function totalCommissions() external view returns (uint256) {
        return allCommissions.length;
    }
}
