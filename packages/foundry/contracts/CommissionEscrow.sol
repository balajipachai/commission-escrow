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
 *         e.g. Kalpana). The collector locks 120% of the agreed price the moment the commission is
 *         created (see "THE 20% CONFIRMATION DEPOSIT" below for why), and it can only leave the
 *         contract in one of four ways:
 *           1. `release()`      -> the 100% commission price goes to the artisan and the 20%
 *              deposit goes back to the collector, once delivery has been confirmed on time.
 *           2. `cancel()`       -> the full 120% refunded to the collector, if either party backs
 *              out before the artisan has shipped.
 *           3. `refundAfterDeadline()` -> the full 120% refunded to the collector if the deadline
 *              passes before the artisan even ships - a failure that is the artisan's, not the
 *              collector's, fault.
 *           4. `resolveDispute()` -> the full 120% (minus a 1% arbiter fee) goes entirely to
 *              whichever party the arbiter sides with.
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
 *   storage this contract cares about) to its new, final value, and only *afterwards* calls
 *   `_transferETH`, which makes the external call that actually sends the ETH. That way, even if
 *   the receiving address is a malicious contract that tries to call back into this escrow, it will
 *   find `status` already flipped to a terminal value and every guarded function will revert.
 *   `nonReentrant` is a second, belt-and-braces layer on top of that.
 *
 * THE 20% CONFIRMATION DEPOSIT - why it exists and how it works:
 *   Once the artisan ships, the only person who can truthfully confirm delivery is the collector
 *   (see `confirmDelivery()`'s own docs for why it isn't the artisan). But that creates a new risk:
 *   what stops the collector from simply never confirming, leaving the escrow permanently stuck
 *   with a delivered commission and an unpaid artisan? The deposit is the answer. The collector
 *   locks 120% of the true price up front. If they confirm delivery before the deadline, they get
 *   their 20% back in the very same `release()` call that pays the artisan - confirming promptly
 *   costs them nothing. If they let the deadline pass while the artisan has already shipped
 *   (`ORDER_SHIPPED`), `confirmDelivery()` itself becomes permanently blocked (see its docs), and
 *   the artisan's only recourse is `raiseDispute()`. Critically, `resolveDispute()` does not need
 *   any special-cased "deposit forfeiture" logic to punish a stalling collector: it already splits
 *   the *entire* locked `amount` - deposit included - between the arbiter's fee and whichever party
 *   the arbiter sides with. So if the arbiter agrees the artisan was stiffed, the artisan
 *   automatically receives the full 120% (minus the arbiter's 1% cut), not just the 100% price -
 *   exactly the punishment a silent collector deserves, without a single extra line of "if the
 *   collector missed the deadline, pay extra" code.
 */
contract CommissionEscrow is Initializable, ReentrancyGuard {
    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Every possible state a commission can be in.
     *
     *  ORDER_PLACED                         Commission created & funded (120% of the price locked).
     *                                        Waiting for the artisan to acknowledge, for the
     *                                        deadline to pass, or for either party to raise a
     *                                        dispute.
     *  ORDER_ACKNOWLEDGED                   The artisan has accepted the commission and will work
     *                                        on it. Waiting for the artisan to ship, for the
     *                                        deadline to pass, or for either party to raise a
     *                                        dispute.
     *  ORDER_SHIPPED                        The artisan has shipped the work. Waiting for the
     *                                        collector to confirm delivery *before the deadline*,
     *                                        or for either party to raise a dispute. Once the
     *                                        deadline passes in this state, `confirmDelivery()` is
     *                                        permanently blocked - a dispute is the only way out.
     *  ORDER_DELIVERED                      The collector confirmed delivery in time. Funds are
     *                                        still sitting in the contract until `release()` (or a
     *                                        dispute) is called - this is the "distinct
     *                                        delivery-confirmation state" that gates payout.
     *  ORDER_FULFILLED                      Terminal. The 100% commission price was paid to the
     *                                        artisan and the 20% deposit was refunded to the
     *                                        collector.
     *  ORDER_CANCELLED                      Terminal. Either party backed out before the artisan
     *                                        shipped; the full 120% was refunded to the collector.
     *  ORDER_CANCELLED_DUE_TO_TIMELINE_EXCEEDED
     *                                        Terminal. The deadline passed before the artisan even
     *                                        shipped (their fault, not the collector's); the full
     *                                        120% was refunded to the collector.
     *  ORDER_DISPUTED                       Either party disagrees about delivery, or the collector
     *                                        has gone silent past the deadline after the artisan
     *                                        shipped. Funds are frozen - no release, no refund -
     *                                        until an approved arbiter steps in and calls
     *                                        `resolveDispute()`.
     *  ORDER_DISPUTE_RESOLVED               Terminal. An arbiter decided the dispute; the winning
     *                                        party was paid the full 120% (minus a 1% arbiter fee)
     *                                        and the losing party got nothing.
     *
     * The happy path is strictly linear:
     *   ORDER_PLACED --acknowledgeCommission()--> ORDER_ACKNOWLEDGED --orderShipped()-->
     *   ORDER_SHIPPED --confirmDelivery()--> ORDER_DELIVERED --release()--> ORDER_FULFILLED
     */
    enum Status {
        ORDER_PLACED,
        ORDER_ACKNOWLEDGED,
        ORDER_SHIPPED,
        ORDER_DELIVERED,
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

    /// @notice The denominator basis-point fees and prices are calculated against (10_000 = 100%).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The collector's refundable confirmation deposit, expressed in basis points of the
    /// true commission price (20% = 2_000 out of `BPS_DENOMINATOR`). See {commissionPrice} and
    /// {collectorDeposit} for the actual wei amounts this works out to for a given commission.
    uint256 public constant DEPOSIT_BPS = 2_000;

    /// @notice What the total locked `amount` represents as a percentage of the true commission
    /// price, in the same basis-point units as {DEPOSIT_BPS}: 100% price + 20% deposit = 120%
    /// (12_000). The collector sends this whole 120% as a single `msg.value` at creation time.
    uint256 public constant TOTAL_LOCKED_BPS = BPS_DENOMINATOR + DEPOSIT_BPS;

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------
    // Custom errors instead of `require(cond, "string")` - reverting with a selector instead of an
    // ABI-encoded string is meaningfully cheaper on both deployment and call gas, since the compiler
    // never has to embed/copy the message bytes.

    /// @notice Thrown when a function restricted to the collector is called by anyone else.
    error NotCollector();

    /// @notice Thrown when a function restricted to the artisan is called by anyone else.
    error NotArtisan();

    /// @notice Thrown when a function restricted to an approved arbiter is called by anyone else.
    error NotArbiter();

    /// @notice Thrown when a function restricted to the collector or the artisan is called by a
    /// third party.
    error NotPartyToDeal();

    /// @notice Thrown when a function is called while the commission is in the wrong `Status` for
    /// that action.
    error InvalidStatus();

    /// @notice Thrown when `initialize` is called with no ETH attached.
    error NoFundsSent();

    /// @notice Thrown when a required address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when the artisan and collector addresses passed to `initialize` are the same.
    error ArtisanEqualsCollector();

    /// @notice Thrown when a deadline passed to `initialize` is not in the future.
    error DeadlineNotInFuture();

    /// @notice Thrown when `refundAfterDeadline` is called before the deadline has passed.
    error DeadlineNotPassed();

    /// @notice Thrown when `confirmDelivery` is called after the deadline has already passed -
    /// past that point, `raiseDispute()` is the only way forward.
    error DeadlineAlreadyPassed();

    /// @notice Thrown when a native ETH transfer made by this contract fails.
    error EthTransferFailed();

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

    /// @notice The exact amount of ETH (in wei) locked for this commission - 120% of the true
    /// commission price (see {commissionPrice} and {collectorDeposit} for the split). Always set
    /// from the actual `msg.value` received in `initialize`, never from a caller-supplied number,
    /// so it can never drift from what is actually held in this contract.
    uint256 public amount;

    /// @notice The unix timestamp after which: (a) the collector is entitled to a full refund if
    /// the artisan has not yet shipped, or (b) `confirmDelivery()` becomes permanently blocked if
    /// the artisan has shipped but the collector has not yet confirmed.
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

    /// @notice Emitted when the artisan accepts the commission and commits to working on it.
    event CommissionAcknowledged(address indexed artisan, uint256 timestamp);

    /// @notice Emitted when the artisan marks the commissioned work as shipped.
    event OrderShipped(address indexed artisan, uint256 timestamp);

    /// @notice Emitted when the collector confirms the commissioned work actually arrived.
    event DeliveryConfirmed(address indexed collector, uint256 timestamp);

    /// @notice Emitted when funds are finally paid out: `commissionPaid` to the artisan and
    /// `depositRefunded` back to the collector.
    event CommissionReleased(
        address indexed artisan, uint256 commissionPaid, address indexed collector, uint256 depositRefunded
    );

    /// @notice Emitted when the commission is cancelled before the artisan ships.
    /// `initiator` is whichever party (collector or artisan) called `cancel()`.
    event CommissionCancelled(address indexed initiator, address indexed collector, uint256 refundedAmount);

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
        if (msg.sender != collector) revert NotCollector();
        _;
    }

    /// @dev Restricts a function to the artisan this commission was created for.
    modifier onlyArtisan() {
        if (msg.sender != artisan) revert NotArtisan();
        _;
    }

    /// @dev Restricts a function to addresses the factory has granted `ARBITER_ROLE` to. Because the
    /// role lives on the factory (not on this clone), any address the factory approves can resolve
    /// disputes on *any* commission - that shared "marketplace" of arbiters is what lets whichever
    /// arbiter gets there first earn the 1% fee, which is the incentive that keeps disputes from
    /// sitting open forever.
    modifier onlyArbiter() {
        if (!IAccessControl(factory).hasRole(ARBITER_ROLE, msg.sender)) revert NotArbiter();
        _;
    }

    /// @dev Restricts a function to either the collector or the artisan - the two addresses who are
    /// actually party to this deal. Shared by `cancel()` and `raiseDispute()`.
    modifier onlyParty() {
        if (msg.sender != collector && msg.sender != artisan) revert NotPartyToDeal();
        _;
    }

    /// @dev Guards a function so it can only run while the commission is in a specific `Status`.
    /// This is the mechanism that makes double-release/double-refund impossible: once a payout
    /// function runs, it moves `status` to a terminal value, so calling it (or any other
    /// payout function) again will always fail this check. Functions that are valid from more than
    /// one `Status` (e.g. `cancel`, `refundAfterDeadline`, `raiseDispute`) check `status` inline
    /// instead of using this modifier, since it only supports a single target value.
    modifier inStatus(Status expected) {
        if (status != expected) revert InvalidStatus();
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
     * @dev Must be called with `msg.value` equal to 120% of the agreed commission price - the extra
     * 20% is the collector's refundable confirmation deposit (see the contract-level docs for why).
     * `_factory` is trusted input, always supplied by `CommissionEscrowFactory` itself at
     * clone-creation time, never by an external caller.
     * @param _collector The buyer funding this commission.
     * @param _artisan The seller expected to deliver the commissioned work.
     * @param _deadline Unix timestamp after which an unshipped commission becomes refundable to the
     * collector, or after which `confirmDelivery()` becomes blocked if the artisan has shipped.
     * @param _factory The `CommissionEscrowFactory` that deployed this clone (used later for arbiter
     * lookups and dispute-marketplace bookkeeping).
     */
    function initialize(address _collector, address _artisan, uint256 _deadline, address _factory)
        external
        payable
        initializer
    {
        if (msg.value == 0) revert NoFundsSent();
        if (_collector == address(0)) revert ZeroAddress();
        if (_artisan == address(0)) revert ZeroAddress();
        if (_artisan == _collector) revert ArtisanEqualsCollector();
        if (_deadline <= block.timestamp) revert DeadlineNotInFuture();

        collector = _collector;
        artisan = _artisan;
        // The stored amount always comes straight from the ETH actually attached to this call - there
        // is no separate "amount" argument a caller could set independently of what was transferred.
        // It represents 120% of the true price; see {commissionPrice} and {collectorDeposit}.
        amount = msg.value;
        deadline = _deadline;
        factory = _factory;
        status = Status.ORDER_PLACED;

        emit CommissionFunded(_collector, _artisan, msg.value, _deadline);
    }

    // ---------------------------------------------------------------------------------------------
    // Views: splitting the locked amount into price + deposit
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice The true commission price the artisan will be paid - 100% of the agreed price, i.e.
     * `amount` with the 20% collector deposit backed out.
     */
    function commissionPrice() public view returns (uint256) {
        return (amount * BPS_DENOMINATOR) / TOTAL_LOCKED_BPS;
    }

    /**
     * @notice The collector's refundable confirmation deposit - the remaining 20% of `amount` after
     * {commissionPrice} is set aside. Defined as `amount - commissionPrice()` (rather than its own
     * basis-point division) so the two always sum to exactly `amount` with no rounding dust left
     * over in the contract.
     */
    function collectorDeposit() public view returns (uint256) {
        return amount - commissionPrice();
    }

    // ---------------------------------------------------------------------------------------------
    // Happy path: acknowledge -> ship -> deliver -> release
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Called by the artisan to accept the commission and commit to working on it.
     * @dev Only callable while the commission is still `ORDER_PLACED`. Moves the commission to
     * `ORDER_ACKNOWLEDGED`. This is also the cutoff for `cancel()`: once acknowledged and shipped,
     * neither party can walk away via `cancel()` any more - a dispute is the only way out from
     * there if something goes wrong.
     */
    function acknowledgeCommission() external onlyArtisan inStatus(Status.ORDER_PLACED) {
        status = Status.ORDER_ACKNOWLEDGED;
        emit CommissionAcknowledged(msg.sender, block.timestamp);
    }

    /**
     * @notice Called by the artisan to mark the commissioned work as shipped.
     * @dev Only callable while the commission is `ORDER_ACKNOWLEDGED`. Moves the commission to
     * `ORDER_SHIPPED`, starting the window in which the collector must call `confirmDelivery()`
     * before the deadline (see the contract-level docs on the confirmation deposit for why this
     * matters). No deadline check here - the deadline exists to pressure the collector into
     * confirming promptly, not to rush the artisan into shipping.
     */
    function orderShipped() external onlyArtisan inStatus(Status.ORDER_ACKNOWLEDGED) {
        status = Status.ORDER_SHIPPED;
        emit OrderShipped(msg.sender, block.timestamp);
    }

    /**
     * @notice Called by the collector to confirm the commissioned work actually arrived. This is the
     * "distinct delivery-confirmation state" the funds cannot move without.
     * @dev Deliberately `onlyCollector`, not `onlyArtisan`. If the artisan could confirm their own
     * delivery, a dishonest artisan could call this (and then `release()`) without ever doing the
     * work, walking away with the collector's money - exactly the scam this escrow exists to
     * prevent. The collector is the only party who actually receives the physical goods, so they are
     * the only one who can truthfully attest that delivery happened. `release()` itself stays open
     * to anyone precisely because, by the time it is callable, the collector has already vouched for
     * delivery here.
     *
     * Only callable while the commission is `ORDER_SHIPPED` (the artisan must have shipped first),
     * and only *before* the deadline - see {DeadlineAlreadyPassed}. That deadline is what stops a
     * collector from indefinitely sitting on a delivered commission and never confirming: if they
     * let the deadline pass while `ORDER_SHIPPED`, this function becomes permanently unreachable and
     * the artisan's only recourse is `raiseDispute()`, where an arbiter can award them the *entire*
     * 120% locked amount (see the contract-level docs on the confirmation deposit).
     */
    function confirmDelivery() external onlyCollector inStatus(Status.ORDER_SHIPPED) {
        if (block.timestamp > deadline) revert DeadlineAlreadyPassed();

        status = Status.ORDER_DELIVERED;
        emit DeliveryConfirmed(msg.sender, block.timestamp);
    }

    /**
     * @notice Pays out the commission: the 100% price to the artisan, and the 20% confirmation
     * deposit back to the collector. Reachable by anyone (there's nothing to gain by restricting who
     * can *trigger* the payment), but only once the collector has confirmed delivery in time.
     * @dev Follows Checks-Effects-Interactions: `status` is flipped to the terminal
     * `ORDER_FULFILLED` value *before* either external ETH transfer, and `nonReentrant` blocks any
     * reentrant call for good measure. Together these two mean a malicious `artisan` (or `collector`)
     * contract cannot re-enter this function (or any other payout function) to drain the escrow
     * twice.
     */
    function release() external nonReentrant inStatus(Status.ORDER_DELIVERED) {
        status = Status.ORDER_FULFILLED;

        uint256 commissionPayout = commissionPrice();
        uint256 depositRefund = collectorDeposit();

        _transferETH(artisan, commissionPayout);
        _transferETH(collector, depositRefund);

        emit CommissionReleased(artisan, commissionPayout, collector, depositRefund);
    }

    // ---------------------------------------------------------------------------------------------
    // Early exit: cancellation before shipping
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Lets either the collector or the artisan call off a commission before the artisan has
     * shipped, refunding the collector the full 120% they locked.
     * @dev Reachable from `ORDER_PLACED` or `ORDER_ACKNOWLEDGED` - once the artisan ships (moving
     * status to `ORDER_SHIPPED`), this function becomes unreachable for both parties. From that
     * point on, a dispute is the only way to unwind a commission that isn't going to be delivered.
     */
    function cancel() external onlyParty nonReentrant {
        if (status != Status.ORDER_PLACED && status != Status.ORDER_ACKNOWLEDGED) revert InvalidStatus();

        status = Status.ORDER_CANCELLED;
        uint256 refundAmount = amount;

        _transferETH(collector, refundAmount);

        emit CommissionCancelled(msg.sender, collector, refundAmount);
    }

    // ---------------------------------------------------------------------------------------------
    // Timeout path
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Returns the full 120% locked to the collector once the deadline has passed with the
     * artisan still not having shipped. Callable by anyone, so the collector is never dependent on
     * the artisan (or anyone else) cooperating to get their money back.
     * @dev Reachable from `ORDER_PLACED` (artisan never even acknowledged) or `ORDER_ACKNOWLEDGED`
     * (artisan accepted but never shipped) - i.e. any state where the *artisan* is the one who
     * failed to act in time, so a full, unilateral, no-questions-asked refund is fair. Deliberately
     * NOT reachable from `ORDER_SHIPPED`: once the artisan has shipped, a missed deadline is
     * presumptively the *collector's* fault for not confirming, so from that point on the only path
     * is `raiseDispute()` - letting the collector self-serve a refund here would let them exploit
     * their own silence. Not reachable from `ORDER_DELIVERED` (the artisan should be paid via
     * `release()` at that point) or `ORDER_DISPUTED` (which is what makes the "no dispute -> no
     * refund" requirement automatic: once a dispute is raised, `status` moves to `ORDER_DISPUTED`, a
     * value this function's allow-list below simply does not include).
     */
    function refundAfterDeadline() external nonReentrant {
        if (status != Status.ORDER_PLACED && status != Status.ORDER_ACKNOWLEDGED) revert InvalidStatus();
        if (block.timestamp <= deadline) revert DeadlineNotPassed();

        status = Status.ORDER_CANCELLED_DUE_TO_TIMELINE_EXCEEDED;
        uint256 refundAmount = amount;

        _transferETH(collector, refundAmount);

        emit CommissionRefunded(collector, refundAmount);
    }

    // ---------------------------------------------------------------------------------------------
    // Dispute path
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Lets either the collector or the artisan flag that they disagree about whether the
     * work was actually delivered - or, most importantly, lets the artisan flag that the collector
     * has gone silent past the deadline after shipping. Freezes the commission so neither
     * `release()` nor `refundAfterDeadline()` (nor `cancel()`, already unreachable past
     * `ORDER_PLACED`/`ORDER_ACKNOWLEDGED`) can move funds until an arbiter steps in.
     * @dev Reachable from `ORDER_PLACED`, `ORDER_ACKNOWLEDGED`, `ORDER_SHIPPED` (the key case: the
     * collector missed the confirmation deadline), or `ORDER_DELIVERED`. Also registers this
     * commission with the factory's public "disputed commissions" list so any approved arbiter can
     * find and resolve it.
     */
    function raiseDispute() external onlyParty {
        if (
            status != Status.ORDER_PLACED && status != Status.ORDER_ACKNOWLEDGED && status != Status.ORDER_SHIPPED
                && status != Status.ORDER_DELIVERED
        ) {
            revert InvalidStatus();
        }

        status = Status.ORDER_DISPUTED;
        disputeInitiator = msg.sender;

        ICommissionEscrowFactory(factory).notifyDisputed(address(this));

        emit DisputeRaised(msg.sender, block.timestamp);
    }

    /**
     * @notice Lets an approved arbiter (an address the factory has granted `ARBITER_ROLE`, and
     * therefore, critically, an address distinct from both `collector` and `artisan`) settle a
     * disputed commission one way or the other.
     * @dev Pays the resolving arbiter a 1% fee (see {ARBITER_FEE_BPS}) out of the *entire* locked
     * `amount` (100% price + 20% deposit) as a reward for doing the work of resolving the
     * disagreement, and sends the remaining 99% to whichever side the arbiter decided should
     * receive it - deliberately not just the 100% price. This is what makes disputing a silent,
     * past-deadline collector actually punitive: the artisan does not just recover the price they
     * were owed, they also receive the collector's own forfeited confirmation deposit, with no
     * extra "was the deadline missed" logic needed here at all - splitting the full `amount` this
     * way already produces that outcome automatically. Follows Checks-Effects-Interactions: `status`
     * moves to the terminal `ORDER_DISPUTE_RESOLVED` value, and this commission is removed from the
     * factory's disputed-commissions list, before either ETH transfer is attempted.
     *
     * WHY `releaseToArtisan` IS A FUNCTION PARAMETER, NOT SOMETHING READ FROM STORAGE:
     * There is no on-chain fact this contract could look up that would tell it whether the
     * collector's physical painting actually arrived - that is precisely the real-world question the
     * two parties disagree about, and precisely why a human arbiter is needed at all. If the answer
     * were derivable from contract storage, there would be nothing to dispute: the contract could
     * simply resolve itself. `releaseToArtisan` is not an input the contract trusts blindly - it *is*
     * the arbiter's verdict, which by definition cannot exist anywhere before the arbiter renders it.
     *
     * WHAT STOPS A COLLUDING ARBITER FROM LYING: nothing at the smart-contract level can force an
     * arbiter to tell the truth - that is an inherent limitation of trusting a single third party to
     * arbitrate, not a bug specific to this function. What this design *does* provide:
     *   - Every resolution is permanently, publicly logged via {DisputeResolved}, including the
     *     arbiter's own address and their exact verdict - a colluding arbiter cannot act
     *     anonymously or deniably.
     *   - `ARBITER_ROLE` is revocable at any time by the factory's `DEFAULT_ADMIN_ROLE` holder
     *     (`CommissionEscrowFactory.revokeRole`), so a caught-out arbiter can be removed from all
     *     future disputes immediately.
     *   - The original project brief explicitly treats "an arbiter, multisig, or DAO" as
     *     interchangeable resolution mechanisms and leaves the exact choice to the implementer. A
     *     single approved address is the simplest version of that spectrum; requiring several
     *     independent `ARBITER_ROLE` holders to agree (N-of-M voting) before funds move would raise
     *     the cost of collusion considerably and is the natural next step - tracked as a future-scope
     *     item in the README rather than built here, to keep this contract's trust model explicit
     *     and easy to reason about today.
     * @param releaseToArtisan Pass `true` if the arbiter decided delivery genuinely happened, or
     * that the collector wrongfully withheld confirmation (pay the artisan the full 120%); pass
     * `false` if the arbiter sided with the collector (refund the collector the full 120%).
     */
    function resolveDispute(bool releaseToArtisan) external nonReentrant onlyArbiter inStatus(Status.ORDER_DISPUTED) {
        status = Status.ORDER_DISPUTE_RESOLVED;
        ICommissionEscrowFactory(factory).notifyDisputeSettled(address(this));

        uint256 totalAmount = amount;
        uint256 arbiterFee = (totalAmount * ARBITER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 partyPayout = totalAmount - arbiterFee;
        address recipient = releaseToArtisan ? artisan : collector;

        _transferETH(msg.sender, arbiterFee);
        _transferETH(recipient, partyPayout);

        emit DisputeResolved(msg.sender, releaseToArtisan, arbiterFee, partyPayout, recipient);
    }

    // ---------------------------------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------------------------------

    /**
     * @dev Sends `value` wei of native ETH to `to`, reverting with {EthTransferFailed} on failure.
     * Every function above that moves funds out of this contract already updates `status` (its
     * "effect") before calling this helper (the "interaction"), so extracting the repeated
     * call-and-check into one place is a pure deduplication - it does not change
     * Checks-Effects-Interactions ordering at any call site.
     */
    function _transferETH(address to, uint256 value) private {
        (bool success,) = to.call{ value: value }("");
        if (!success) revert EthTransferFailed();
    }
}
