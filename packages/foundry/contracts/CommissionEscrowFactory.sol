// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

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
 *      can check to decide whether `msg.sender` is allowed to vote on a dispute. Approving an
 *      arbiter here makes them able to vote on *any* disputed commission created by this factory.
 *   3. The dispute "marketplace" - a public, always-up-to-date list of every commission that is
 *      currently disputed, so an arbiter can simply browse {getDisputedCommissions} to find work
 *      (and earn a share of the 1% resolution fee described in
 *      {CommissionEscrow-castArbiterVote}).
 *   4. The vote-threshold registry - {arbiterThreshold} says how many arbiters must agree on the
 *      same verdict before a disputed commission's {CommissionEscrow-castArbiterVote} pays out, so
 *      no single `ARBITER_ROLE` holder can unilaterally move funds.
 *
 * @dev DEFAULT_ADMIN_ROLE (granted to the `admin` address passed into the constructor - see
 * `DeployCommissionEscrowFactory.s.sol`) is the only role that can grant/revoke `ARBITER_ROLE`, via
 * the standard `AccessControl.grantRole` / `revokeRole` functions inherited below. There is
 * intentionally no custom "addArbiter" function - `AccessControl`'s own functions already do
 * exactly that, correctly, and reusing them means less custom code to get wrong. `DEFAULT_ADMIN_ROLE`
 * also controls {arbiterThreshold} via {setArbiterThreshold}.
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
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice Thrown when a required address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when `createCommission` is called with no ETH attached.
    error NoCommissionAmountSent();

    /// @notice Thrown when `notifyDisputed` / `notifyDisputeSettled` is called by something other
    /// than a genuine commission clone this factory created.
    error NotGenuineCommission();

    /// @notice Thrown when `notifyDisputed` is called for a commission already on the disputed list.
    error AlreadyDisputed();

    /// @notice Thrown when `notifyDisputeSettled` is called for a commission not on the disputed list.
    error NotListedAsDisputed();

    /// @notice Thrown when the constructor or `setArbiterThreshold` is given a threshold of zero -
    /// a dispute with a zero-vote requirement could never actually require any arbiter to agree.
    error ThresholdMustBePositive();

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @notice The one-off {CommissionEscrow} contract every new commission is cloned from. Deployed
    /// once, in this factory's constructor, and then never touched directly again - all real
    /// commissions live in clones pointing at this address.
    address public immutable escrowImplementation;

    /// @notice The number of matching arbiter votes a disputed commission needs before
    /// {CommissionEscrow-castArbiterVote} finalizes it. Set at deployment and adjustable afterwards
    /// by `DEFAULT_ADMIN_ROLE` via {setArbiterThreshold} - e.g. to raise it as more arbiters are
    /// onboarded. See {CommissionEscrow}'s "N-OF-M ARBITER VOTING" docs for why requiring more than
    /// one arbiter's agreement matters.
    uint256 public arbiterThreshold;

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

    /// @notice Emitted whenever `DEFAULT_ADMIN_ROLE` changes {arbiterThreshold}.
    event ArbiterThresholdUpdated(uint256 previousThreshold, uint256 newThreshold);

    // ---------------------------------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------------------------------

    /// @dev Restricts a function to a commission clone this factory actually created, calling about
    /// itself. Shared by {notifyDisputed} and {notifyDisputeSettled}.
    modifier onlyGenuineCommission(address commission) {
        if (!isCommission[msg.sender] || msg.sender != commission) revert NotGenuineCommission();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /**
     * @param admin Address granted `DEFAULT_ADMIN_ROLE`, i.e. able to grant/revoke `ARBITER_ROLE` for
     * any address (including itself) going forward.
     * @param arbiter Address granted `ARBITER_ROLE` directly, so the system has at least one working
     * arbiter immediately after deployment. Passed as an explicit, independent argument (rather than
     * automatically reusing `admin`) so that deployments can hand day-to-day dispute resolution to a
     * different address - e.g. a dedicated multisig - than the address controlling role management.
     * `admin` and `arbiter` may be the same address if that separation isn't needed.
     * @param initialArbiterThreshold Starting value for {arbiterThreshold} - how many matching
     * arbiter votes a dispute needs to finalize. A deployment that starts with a single arbiter (as
     * above) should start this at `1` so that lone arbiter can still resolve disputes immediately;
     * {setArbiterThreshold} can raise it later as more arbiters are granted `ARBITER_ROLE`.
     */
    constructor(address admin, address arbiter, uint256 initialArbiterThreshold) {
        if (admin == address(0)) revert ZeroAddress();
        if (arbiter == address(0)) revert ZeroAddress();
        if (initialArbiterThreshold == 0) revert ThresholdMustBePositive();

        escrowImplementation = address(new CommissionEscrow());

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ARBITER_ROLE, arbiter);
        arbiterThreshold = initialArbiterThreshold;
    }

    // ---------------------------------------------------------------------------------------------
    // Admin configuration
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Updates how many matching arbiter votes a disputed commission needs before it can be
     * finalized. Only affects disputes resolved *after* this call - a dispute already mid-vote
     * simply needs the new threshold's vote count on whichever side reaches it next.
     * @param newThreshold The new required vote count. Must be at least `1`.
     */
    function setArbiterThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newThreshold == 0) revert ThresholdMustBePositive();

        emit ArbiterThresholdUpdated(arbiterThreshold, newThreshold);
        arbiterThreshold = newThreshold;
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
        if (msg.value == 0) revert NoCommissionAmountSent();

        commission = Clones.clone(escrowImplementation);

        // Checks-Effects-Interactions: every bit of this factory's own bookkeeping - including the
        // event - is recorded before the external call to `initialize` below. None of it depends on
        // that call's outcome (a revert there unwinds the whole transaction, these writes included),
        // so there is no reason to leave them exposed to reentrancy during the external call.
        isCommission[commission] = true;
        allCommissions.push(commission);
        commissionsByCollector[msg.sender].push(commission);
        commissionsByArtisan[artisan].push(commission);

        emit CommissionCreated(commission, msg.sender, artisan, msg.value, deadline);

        // `msg.sender` becomes the collector; `initialize` re-validates every argument (zero address,
        // artisan == collector, deadline in the past) so this factory does not have to duplicate those
        // checks.
        CommissionEscrow(payable(commission)).initialize{ value: msg.value }(
            msg.sender, artisan, deadline, address(this)
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Dispute marketplace bookkeeping (callable only by this factory's own commission clones)
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Adds `commission` to the public disputed-commissions list. Called automatically by a
     * {CommissionEscrow} clone from inside its own `raiseDispute()` - never call this directly.
     */
    function notifyDisputed(address commission) external onlyGenuineCommission(commission) {
        if (_disputedIndexPlusOne[commission] != 0) revert AlreadyDisputed();

        disputedCommissions.push(commission);
        _disputedIndexPlusOne[commission] = disputedCommissions.length;
    }

    /**
     * @notice Removes `commission` from the public disputed-commissions list. Called automatically
     * by a {CommissionEscrow} clone from inside its own `castArbiterVote()` once a dispute's vote
     * tally is finalized - never call this directly.
     * @dev Uses swap-and-pop so removal is O(1) regardless of list size.
     */
    function notifyDisputeSettled(address commission) external onlyGenuineCommission(commission) {
        uint256 indexPlusOne = _disputedIndexPlusOne[commission];
        if (indexPlusOne == 0) revert NotListedAsDisputed();

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
