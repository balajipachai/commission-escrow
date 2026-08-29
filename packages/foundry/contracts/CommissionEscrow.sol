// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title ICommissionEscrowFactory
 * @notice The tiny slice of `CommissionEscrowFactory` that a `CommissionEscrow` clone needs to
 *         talk back to. Declaring it as an interface (instead of importing the whole factory
 *         contract) avoids a circular import between the two files.
 * @dev "Marketplace" here just means: the factory keeps a public list of every commission that is
 *      currently disputed, so that any approved arbiter can browse it and pick up work. The two
 *      functions below are how an escrow clone adds itself to / removes itself from that list.
 */
interface ICommissionEscrowFactory {
    /// @notice Called by a commission when it enters the ORDER_DISPUTED state.
    function notifyDisputed(address commission) external;

    /// @notice Called by a commission when its dispute has just been resolved.
    function notifyDisputeSettled(address commission) external;
}

/**
 * @title CommissionEscrow
 * @author Kalpana & the Berlin collector's engineers (built for the commission-escrow challenge)
 * @notice One `CommissionEscrow` instance represents exactly ONE commission deal between exactly
 *         ONE collector (the buyer, e.g. the Berlin collector) and exactly ONE artisan (the seller,
 *         e.g. Kalpana). The collector's payment is locked inside this contract the moment the
 *         commission is created, and it can only leave the contract in one of three ways:
 *           1. `release()`      -> paid out to the artisan, once delivery has been confirmed.
 *           2. `cancel()`       -> refunded to the collector, if the artisan backs out early.
 *           3. `refundAfterDeadline()` -> refunded to the collector if the deadline passes with no
 *              delivery confirmation and no dispute.
 *           4. `resolveDispute()` -> split between the winning party and the arbiter who resolved
 *              the disagreement, if either side raised a dispute.
 *
 * @dev DESIGN NOTES FOR NEWCOMERS
 *
 * Why is this contract "Initializable" instead of using a normal constructor?
 *   Because we never deploy `CommissionEscrow` directly for each commission (that would cost a lot
 *   of gas every single time). Instead, `CommissionEscrowFactory` deploys this contract ONCE as an
 *   "implementation", and then creates a cheap EIP-1167 minimal proxy ("clone") for every new
 *   commission. A clone shares the implementation's *code* but has its own, completely empty
 *   *storage*. Because storage starts empty and a clone never runs the implementation's
 *   constructor, we replace the constructor with a regular function - `initialize()` - protected by
 *   OpenZeppelin's `initializer` modifier so it can only ever run once per clone. The constructor
 *   that does exist below only runs on the one-off implementation contract, and it calls
 *   `_disableInitializers()` so that nobody can trick the *implementation* itself into thinking it
 *   is a live commission.
 *
 * Why is `ReentrancyGuard` safe to use on a clone that never runs a constructor?
 *   `ReentrancyGuard` normally sets its internal flag to `NOT_ENTERED` in its constructor. A clone's
 *   storage starts at `0`, and OpenZeppelin's guard only ever checks for equality with `ENTERED`
 *   (which is deliberately not `0`), so an unset flag behaves exactly like `NOT_ENTERED`. This is a
 *   well known, safe pattern for reentrancy guards on minimal proxies.
 *
 * Why "Checks-Effects-Interactions" (CEI)?
 *   Every function that moves ETH out of this contract first updates `status` (and any other
 *   storage this contract cares about) to its new, final value, and only *afterwards* makes the
 *   external call that actually sends the ETH. That way, even if the receiving address is a
 *   malicious contract that tries to call back into this escrow, it will find `status` already
 *   flipped to a terminal value and every guarded function will revert. `nonReentrant` is a second,
 *   belt-and-braces layer on top of that.
 */
contract CommissionEscrow is Initializable, ReentrancyGuard {
    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Every possible state a commission can be in, in the order they were called out in the
     *         project brief.
     *
     *  ORDER_PLACED                         Commission created & funded. Waiting for the artisan to
     *                                        confirm delivery, for the deadline to pass, or for
     *                                        either party to raise a dispute.
     *  ORDER_RECEIVED                       The artisan has confirmed the work was delivered. Funds
     *                                        are still sitting in the contract until `release()` (or
     *                                        a dispute) is called - this is the "distinct
     *                                        delivery-confirmation state" that gates payout.
     *  ORDER_FULFILLED                      Terminal. Funds have been paid out to the artisan.
     *  ORDER_CANCELLED                      Terminal. The artisan backed out before confirming
     *                                        delivery; funds were refunded to the collector.
     *  ORDER_CANCELLED_DUE_TO_TIMELINE_EXCEEDED
     *                                        Terminal. The deadline passed with no delivery
     *                                        confirmed and no dispute raised; funds were refunded to
     *                                        the collector.
     *  ORDER_DISPUTED                       Either party disagrees about delivery. Funds are frozen -
     *                                        no release, no refund - until an approved arbiter steps
     *                                        in and calls `resolveDispute()`.
     *  ORDER_DISPUTE_RESOLVED               Terminal. An arbiter decided the dispute; the winning
     *                                        party was paid (minus a 1% arbiter fee) and the losing
     *                                        party got nothing.
     */
    enum Status {
        ORDER_PLACED,
        ORDER_RECEIVED,
        ORDER_FULFILLED,
        ORDER_CANCELLED,
        ORDER_CANCELLED_DUE_TO_TIMELINE_EXCEEDED,
        ORDER_DISPUTED,
        ORDER_DISPUTE_RESOLVED
    }

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice The role identifier that `CommissionEscrowFactory` uses to mark an address as an
    /// approved arbiter. Declared here too so this contract can check `IAccessControl.hasRole`
    /// against the factory without needing to import the whole factory contract.
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");

    /// @notice The cut an arbiter earns for resolving a dispute, expressed in basis points (1% = 100
    /// basis points out of 10_000). Paying arbiters for their work is what keeps disputed deals from
    /// sitting unresolved forever.
    uint256 public constant ARBITER_FEE_BPS = 100;

    /// @notice The denominator basis-point fees are calculated against (10_000 = 100%).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------
    // NOTE: because this contract is used behind minimal proxy clones, every one of these variables
    // lives in the *clone's* storage, not the shared implementation's storage. Each commission gets
    // its own totally independent copy.

    /// @notice The buyer who opened this commission and whose ETH is locked here.
    address public collector;

    /// @notice The seller/creator who is expected to deliver the commissioned work.
    address public artisan;

    /// @notice The address of `CommissionEscrowFactory` that created this clone. Used to look up the
    /// current set of approved arbiters and to report dispute status back to the factory.
    address public factory;

    /// @notice The exact amount of ETH (in wei) locked for this commission. Always set from the
    /// actual `msg.value` received in `initialize`, never from a caller-supplied number, so it can
    /// never drift from what is actually held in this contract.
    uint256 public amount;

    /// @notice The unix timestamp after which the collector is entitled to a refund, provided
    /// delivery has not been confirmed and no dispute is open.
    uint256 public deadline;

    /// @notice The current stage of the commission's lifecycle. See {Status} for what each value
    /// means and consult the modifiers below for which functions are reachable from which stage.
    Status public status;

    /// @notice Whichever party (collector or artisan) called `raiseDispute()`. Purely informational,
    /// useful for arbiters and front-ends deciding how to weigh the dispute.
    address public disputeInitiator;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    /// @notice Emitted once, inside `initialize`, the moment the collector's payment lands in escrow.
    event CommissionFunded(address indexed collector, address indexed artisan, uint256 amount, uint256 deadline);

    /// @notice Emitted when the artisan marks the commissioned work as delivered.
    event DeliveryConfirmed(address indexed artisan, uint256 timestamp);

    /// @notice Emitted when funds are finally paid out to the artisan.
    event CommissionReleased(address indexed artisan, uint256 amount);

    /// @notice Emitted when the artisan cancels the commission before confirming delivery.
    event CommissionCancelled(address indexed artisan, address indexed collector, uint256 refundedAmount);

    /// @notice Emitted when the deadline passes with no delivery confirmed and the collector is
    /// refunded automatically.
    event CommissionRefunded(address indexed collector, uint256 refundedAmount);

    /// @notice Emitted when either party opens a dispute.
    event DisputeRaised(address indexed initiator, uint256 timestamp);

    /// @notice Emitted when an arbiter resolves an open dispute.
    event DisputeResolved(
        address indexed arbiter, bool releasedToArtisan, uint256 arbiterFee, uint256 partyPayout, address indexed paidTo
    );

    // ---------------------------------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------------------------------

    /// @dev Restricts a function to the collector who opened this commission.
    modifier onlyCollector() {
        require(msg.sender == collector, "CommissionEscrow: caller is not the collector");
        _;
    }

    /// @dev Restricts a function to the artisan this commission was created for.
    modifier onlyArtisan() {
        require(msg.sender == artisan, "CommissionEscrow: caller is not the artisan");
        _;
    }

    /// @dev Restricts a function to addresses the factory has granted `ARBITER_ROLE` to. Because the
    /// role lives on the factory (not on this clone), any address the factory approves can resolve
    /// disputes on *any* commission - that shared "marketplace" of arbiters is what lets whichever
    /// arbiter gets there first earn the 1% fee, which is the incentive that keeps disputes from
    /// sitting open forever.
    modifier onlyArbiter() {
        require(IAccessControl(factory).hasRole(ARBITER_ROLE, msg.sender), "CommissionEscrow: caller is not an arbiter");
        _;
    }

    /// @dev Guards a function so it can only run while the commission is in a specific `Status`.
    /// This is the mechanism that makes double-release/double-refund impossible: once a payout
    /// function runs, it moves `status` to a terminal value, so calling it (or any other
    /// payout function) again will always fail this check.
    modifier inStatus(Status expected) {
        require(status == expected, "CommissionEscrow: invalid status for this action");
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Constructor (implementation contract only - clones never run this)
    // ---------------------------------------------------------------------------------------------

    /**
     * @dev Locks the *implementation* contract the instant it is deployed by
     * `CommissionEscrowFactory`, so nobody can call `initialize` on it directly and pretend it is a
     * real commission. Clones are unaffected: they get their own fresh storage and their own,
     * separate `initializer` slot.
     */
    constructor() {
        _disableInitializers();
    }

    // ---------------------------------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Turns a freshly-cloned, empty contract into a live, funded commission. This is the
     * clone equivalent of a constructor and can only ever succeed once per clone (enforced by the
     * `initializer` modifier).
     * @dev Must be called with `msg.value` equal to the agreed commission price - that ETH is what
     * gets locked in escrow. `_factory` is trusted input, always supplied by
     * `CommissionEscrowFactory` itself at clone-creation time, never by an external caller.
     * @param _collector The buyer funding this commission.
     * @param _artisan The seller expected to deliver the commissioned work.
     * @param _deadline Unix timestamp after which an unconfirmed, undisputed commission becomes
     * refundable to the collector.
     * @param _factory The `CommissionEscrowFactory` that deployed this clone (used later for arbiter
     * lookups and dispute-marketplace bookkeeping).
     */
    function initialize(address _collector, address _artisan, uint256 _deadline, address _factory)
        external
        payable
        initializer
    {
        require(msg.value > 0, "CommissionEscrow: no funds sent");
        require(_collector != address(0), "CommissionEscrow: collector is the zero address");
        require(_artisan != address(0), "CommissionEscrow: artisan is the zero address");
        require(_artisan != _collector, "CommissionEscrow: artisan and collector must differ");
        require(_deadline > block.timestamp, "CommissionEscrow: deadline must be in the future");

        collector = _collector;
        artisan = _artisan;
        // The stored amount always comes straight from the ETH actually attached to this call - there
        // is no separate "amount" argument a caller could set independently of what was transferred.
        amount = msg.value;
        deadline = _deadline;
        factory = _factory;
        status = Status.ORDER_PLACED;

        emit CommissionFunded(_collector, _artisan, msg.value, _deadline);
    }

    // ---------------------------------------------------------------------------------------------
    // Happy path: delivery -> release
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Called by the artisan to mark the commissioned work as delivered. This is the
     * "distinct delivery-confirmation state" the funds cannot move without - the collector cannot
     * skip it, fake it, or call it themselves.
     * @dev Only callable while the commission is still `ORDER_PLACED`. Moves the commission to
     * `ORDER_RECEIVED`, one step short of payout. A real deployment would typically have this call
     * triggered once an off-chain oracle/keeper confirms the shipment's AWB (air waybill) tracking
     * number shows "delivered" with the carrier; here it is a direct call so the whole lifecycle is
     * testable without an external oracle dependency.
     */
    function confirmDelivery() external onlyArtisan inStatus(Status.ORDER_PLACED) {
        status = Status.ORDER_RECEIVED;
        emit DeliveryConfirmed(msg.sender, block.timestamp);
    }

    /**
     * @notice Pays the locked commission amount to the artisan. Reachable by anyone (there's nothing
     * to gain by restricting who can *trigger* the payment), but only once delivery has actually
     * been confirmed.
     * @dev Follows Checks-Effects-Interactions: `status` is flipped to the terminal
     * `ORDER_FULFILLED` value *before* the external ETH transfer, and `nonReentrant` blocks any
     * reentrant call for good measure. Together these two mean a malicious `artisan` contract cannot
     * re-enter this function (or any other payout function) to drain the escrow twice.
     */
    function release() external nonReentrant inStatus(Status.ORDER_RECEIVED) {
        status = Status.ORDER_FULFILLED;
        uint256 payout = amount;

        (bool success,) = artisan.call{ value: payout }("");
        require(success, "CommissionEscrow: transfer to artisan failed");

        emit CommissionReleased(artisan, payout);
    }

    // ---------------------------------------------------------------------------------------------
    // Early exit: artisan-initiated cancellation
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Lets the artisan call off a commission they have not yet delivered, refunding the
     * collector in full. Useful if the artisan realizes they cannot complete the piece.
     * @dev Only reachable from `ORDER_PLACED` - once delivery has been confirmed the artisan should
     * be paid via `release()`, not refund the collector.
     */
    function cancel() external onlyArtisan nonReentrant inStatus(Status.ORDER_PLACED) {
        status = Status.ORDER_CANCELLED;
        uint256 refundAmount = amount;

        (bool success,) = collector.call{ value: refundAmount }("");
        require(success, "CommissionEscrow: refund to collector failed");

        emit CommissionCancelled(artisan, collector, refundAmount);
    }

    // ---------------------------------------------------------------------------------------------
    // Timeout path
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Returns the locked funds to the collector once the deadline has passed with delivery
     * still unconfirmed. Callable by anyone, so the collector is never dependent on the artisan (or
     * anyone else) cooperating to get their money back.
     * @dev Only reachable from `ORDER_PLACED`. This is what makes the "no dispute -> no refund"
     * requirement automatic rather than something we have to special-case: once a dispute is raised
     * the status moves to `ORDER_DISPUTED`, so `inStatus(Status.ORDER_PLACED)` below will already
     * fail on its own - there is no separate "is this disputed" check needed.
     */
    function refundAfterDeadline() external nonReentrant inStatus(Status.ORDER_PLACED) {
        require(block.timestamp > deadline, "CommissionEscrow: deadline has not passed yet");

        status = Status.ORDER_CANCELLED_DUE_TO_TIMELINE_EXCEEDED;
        uint256 refundAmount = amount;

        (bool success,) = collector.call{ value: refundAmount }("");
        require(success, "CommissionEscrow: refund to collector failed");

        emit CommissionRefunded(collector, refundAmount);
    }

    // ---------------------------------------------------------------------------------------------
    // Dispute path
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Lets either the collector or the artisan flag that they disagree about whether the
     * work was actually delivered. Freezes the commission so neither `release()` nor
     * `refundAfterDeadline()` (nor `cancel()`) can move funds until an arbiter steps in.
     * @dev Reachable from `ORDER_PLACED` (e.g. the collector believes the artisan will never
     * deliver) or `ORDER_RECEIVED` (e.g. the artisan claims delivery but the collector says the
     * package never arrived, or arrived empty). Also registers this commission with the factory's
     * public "disputed commissions" list so any approved arbiter can find and resolve it.
     */
    function raiseDispute() external {
        require(
            msg.sender == collector || msg.sender == artisan, "CommissionEscrow: caller is not a party to this deal"
        );
        require(
            status == Status.ORDER_PLACED || status == Status.ORDER_RECEIVED,
            "CommissionEscrow: commission cannot be disputed in its current status"
        );

        status = Status.ORDER_DISPUTED;
        disputeInitiator = msg.sender;

        ICommissionEscrowFactory(factory).notifyDisputed(address(this));

        emit DisputeRaised(msg.sender, block.timestamp);
    }

    /**
     * @notice Lets an approved arbiter (an address the factory has granted `ARBITER_ROLE`, and
     * therefore, critically, an address distinct from both `collector` and `artisan`) settle a
     * disputed commission one way or the other.
     * @dev Pays the resolving arbiter a 1% fee (see {ARBITER_FEE_BPS}) out of the escrowed amount as
     * a reward for doing the work of resolving the disagreement, and sends the remaining 99% to
     * whichever side the arbiter decided should receive it. Follows Checks-Effects-Interactions:
     * `status` moves to the terminal `ORDER_DISPUTE_RESOLVED` value, and this commission is removed
     * from the factory's disputed-commissions list, before either ETH transfer is attempted.
     * @param releaseToArtisan Pass `true` if the arbiter decided delivery genuinely happened (pay
     * the artisan); pass `false` if the arbiter sided with the collector (refund the collector).
     */
    function resolveDispute(bool releaseToArtisan) external nonReentrant onlyArbiter inStatus(Status.ORDER_DISPUTED) {
        status = Status.ORDER_DISPUTE_RESOLVED;
        ICommissionEscrowFactory(factory).notifyDisputeSettled(address(this));

        uint256 totalAmount = amount;
        uint256 arbiterFee = (totalAmount * ARBITER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 partyPayout = totalAmount - arbiterFee;
        address recipient = releaseToArtisan ? artisan : collector;

        (bool feePaid,) = msg.sender.call{ value: arbiterFee }("");
        require(feePaid, "CommissionEscrow: arbiter fee transfer failed");

        (bool partyPaid,) = recipient.call{ value: partyPayout }("");
        require(partyPaid, "CommissionEscrow: payout to resolved party failed");

        emit DisputeResolved(msg.sender, releaseToArtisan, arbiterFee, partyPayout, recipient);
    }
}
