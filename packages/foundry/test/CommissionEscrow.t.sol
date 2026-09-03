// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { CommissionEscrow } from "../contracts/CommissionEscrow.sol";
import { CommissionEscrowFactory } from "../contracts/CommissionEscrowFactory.sol";
import { MaliciousArtisan } from "./mocks/MaliciousArtisan.sol";

/**
 * @title CommissionEscrowTest
 * @notice Exercises the full lifecycle of a single {CommissionEscrow} commission created through
 * {CommissionEscrowFactory}. Each group of tests below is labelled with the numbered test case
 * from the project brief it covers, so it is easy to see which requirement each test is proving.
 */
contract CommissionEscrowTest is Test {
    CommissionEscrowFactory internal factory;

    address internal admin = makeAddr("admin");
    address internal collector = makeAddr("collector");
    address internal artisan = makeAddr("artisan");
    address internal arbiter = makeAddr("arbiter");
    address internal arbiterTwo = makeAddr("arbiterTwo");
    address internal arbiterThree = makeAddr("arbiterThree");
    address internal stranger = makeAddr("stranger");

    // `COMMISSION_PRICE` here is the total ETH locked at creation - 120% of the true commission
    // price (100% price + the collector's 20% refundable confirmation deposit). Use
    // `escrow.commissionPrice()` / `escrow.collectorDeposit()` when a test needs the split.
    uint256 internal constant COMMISSION_PRICE = 2 ether;
    uint256 internal deadline;

    function setUp() public {
        // `admin` is passed as both the admin and the initial arbiter here purely for test
        // convenience (see CommissionEscrowFactory.t.sol for coverage of them being distinct). The
        // threshold starts at `1` so a lone arbiter's vote still finalizes a dispute immediately -
        // the N-of-M voting tests below raise it explicitly where they need more than one voter.
        factory = new CommissionEscrowFactory(admin, admin, 1);
        deadline = block.timestamp + 7 days;

        vm.deal(collector, 100 ether);
        vm.deal(artisan, 10 ether);
        vm.deal(arbiter, 10 ether);
        vm.deal(arbiterTwo, 10 ether);
        vm.deal(arbiterThree, 10 ether);
    }

    /// @dev Helper: opens a standard commission from `collector` to `artisan` for `COMMISSION_PRICE`.
    function _createCommission() internal returns (CommissionEscrow escrow) {
        vm.prank(collector);
        address commission = factory.createCommission{ value: COMMISSION_PRICE }(artisan, deadline);
        escrow = CommissionEscrow(payable(commission));
    }

    /// @dev Helper: grants `account` the factory's `ARBITER_ROLE` as `admin`.
    /// NOTE: `factory.ARBITER_ROLE()` is read into a local variable *before* pranking, because
    /// evaluating it inline as a call argument (e.g. `factory.grantRole(factory.ARBITER_ROLE(), x)`)
    /// would itself count as "the next call" and silently consume a single-shot `vm.prank`.
    function _grantArbiterRole(address account) internal {
        bytes32 arbiterRole = factory.ARBITER_ROLE();
        vm.prank(admin);
        factory.grantRole(arbiterRole, account);
    }

    /// @dev Helper: artisan accepts the commission, moving it from ORDER_PLACED to ORDER_ACKNOWLEDGED.
    function _acknowledge(CommissionEscrow escrow) internal {
        vm.prank(artisan);
        escrow.acknowledgeCommission();
    }

    /// @dev Helper: artisan marks the (already acknowledged) commission as shipped.
    function _ship(CommissionEscrow escrow) internal {
        vm.prank(artisan);
        escrow.orderShipped();
    }

    /// @dev Helper: artisan acknowledges then ships, moving a fresh commission to ORDER_SHIPPED.
    function _acknowledgeAndShip(CommissionEscrow escrow) internal {
        _acknowledge(escrow);
        _ship(escrow);
    }

    /// @dev Helper: walks a fresh commission all the way to ORDER_DELIVERED (artisan acknowledges,
    /// artisan ships, collector confirms delivery before the deadline), the prerequisite state for
    /// `release()`.
    function _fullyDeliver(CommissionEscrow escrow) internal {
        _acknowledgeAndShip(escrow);
        vm.prank(collector);
        escrow.confirmDelivery();
    }

    // =================================================================================================
    // Test Case 1 - Escrow holds funds before work begins
    // =================================================================================================

    function test_EscrowHoldsFundsAtCreation() public {
        CommissionEscrow escrow = _createCommission();

        assertEq(address(escrow).balance, COMMISSION_PRICE, "commission balance should equal the price paid");
        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_PLACED), "should start ORDER_PLACED");
    }

    function test_RevertWhen_CreatingCommissionWithNoValue() public {
        vm.prank(collector);
        vm.expectRevert(CommissionEscrowFactory.NoCommissionAmountSent.selector);
        factory.createCommission(artisan, deadline);
    }

    // =================================================================================================
    // Test Case 6 - Commission amount comes from value actually sent
    // =================================================================================================

    function test_AmountIsSetFromActualMsgValueNotACallerArgument() public {
        CommissionEscrow escrow = _createCommission();
        // CommissionEscrow.initialize() has no separate "amount" parameter at all - `amount` is always
        // `msg.value` from the funding call, so this is the only way it could ever be set.
        assertEq(escrow.amount(), COMMISSION_PRICE);
    }

    function test_CommissionPriceAndCollectorDepositSplitTheLockedAmount() public {
        CommissionEscrow escrow = _createCommission();

        uint256 price = escrow.commissionPrice();
        uint256 deposit = escrow.collectorDeposit();

        // The two must always sum to exactly the locked amount, with no rounding dust left behind.
        assertEq(price + deposit, COMMISSION_PRICE);
        // The deposit is ~20% of the price (i.e. price is ~5x the deposit) - integer division on a
        // COMMISSION_PRICE that isn't a clean multiple of 12 leaves a few wei of rounding, which
        // `commissionPrice()`'s floor() division always resolves in the collector's favor (their
        // deposit absorbs the remainder), so allow a small absolute tolerance here.
        assertApproxEqAbs(deposit * 5, price, 10);
    }

    function test_RevertWhen_ImplementationInitializedDirectly() public {
        // The one-off implementation contract disables its own initializer in its constructor, so it
        // can never be tricked into thinking it is a live, funded commission.
        CommissionEscrow implementation = CommissionEscrow(payable(factory.escrowImplementation()));
        vm.expectRevert();
        implementation.initialize{ value: 1 ether }(collector, artisan, deadline, address(factory));
    }

    // =================================================================================================
    // Test Case 2 - Release requires confirmed delivery
    // =================================================================================================

    function test_ArtisanCanAcknowledgeCommission() public {
        CommissionEscrow escrow = _createCommission();

        _acknowledge(escrow);

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_ACKNOWLEDGED));
    }

    function test_RevertWhen_CollectorAcknowledgesCommission() public {
        CommissionEscrow escrow = _createCommission();
        vm.prank(collector);
        vm.expectRevert(CommissionEscrow.NotArtisan.selector);
        escrow.acknowledgeCommission();
    }

    function test_RevertWhen_StrangerAcknowledgesCommission() public {
        CommissionEscrow escrow = _createCommission();
        vm.prank(stranger);
        vm.expectRevert(CommissionEscrow.NotArtisan.selector);
        escrow.acknowledgeCommission();
    }

    function test_ArtisanCanShipAfterAcknowledging() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledge(escrow);

        _ship(escrow);

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_SHIPPED));
    }

    function test_RevertWhen_OrderShippedBeforeAcknowledgement() public {
        CommissionEscrow escrow = _createCommission();
        vm.prank(artisan);
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.orderShipped();
    }

    function test_RevertWhen_CollectorShipsOrder() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledge(escrow);

        vm.prank(collector);
        vm.expectRevert(CommissionEscrow.NotArtisan.selector);
        escrow.orderShipped();
    }

    function test_RevertWhen_ConfirmDeliveryBeforeAcknowledgement() public {
        CommissionEscrow escrow = _createCommission();
        vm.prank(collector);
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.confirmDelivery();
    }

    function test_RevertWhen_ConfirmDeliveryBeforeShipping() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledge(escrow);

        vm.prank(collector);
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.confirmDelivery();
    }

    function test_RevertWhen_ReleaseCalledBeforeDeliveryConfirmed() public {
        CommissionEscrow escrow = _createCommission();
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.release();
    }

    /// @notice This is the regression test for the fix requested in review: previously
    /// `confirmDelivery()` was `onlyArtisan`, which meant a dishonest artisan could confirm their
    /// own "delivery" and walk away with `release()` without ever doing the work. Now that
    /// `confirmDelivery()` is `onlyCollector`, the artisan calling it - even after legitimately
    /// acknowledging and shipping the commission - must revert.
    function test_RevertWhen_ArtisanConfirmsOwnDelivery() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledgeAndShip(escrow);

        vm.prank(artisan);
        vm.expectRevert(CommissionEscrow.NotCollector.selector);
        escrow.confirmDelivery();
    }

    function test_RevertWhen_StrangerConfirmsDelivery() public {
        CommissionEscrow escrow = _createCommission();
        vm.prank(stranger);
        vm.expectRevert(CommissionEscrow.NotCollector.selector);
        escrow.confirmDelivery();
    }

    /// @notice This is the regression test for the "what stops the collector from just never
    /// confirming" gap: once the artisan has shipped, the collector has exactly until `deadline` to
    /// call `confirmDelivery()`. After that, the function is permanently blocked and the artisan's
    /// only recourse is `raiseDispute()`.
    function test_RevertWhen_ConfirmDeliveryAfterDeadline() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledgeAndShip(escrow);

        vm.warp(deadline + 1);

        vm.prank(collector);
        vm.expectRevert(CommissionEscrow.DeadlineAlreadyPassed.selector);
        escrow.confirmDelivery();
    }

    function test_ReleaseSucceedsOnlyAfterCollectorConfirmsDeliveryOnTime() public {
        CommissionEscrow escrow = _createCommission();

        _acknowledge(escrow);
        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_ACKNOWLEDGED));

        _ship(escrow);
        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_SHIPPED));

        vm.prank(collector);
        escrow.confirmDelivery();
        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_DELIVERED));

        uint256 expectedPrice = escrow.commissionPrice();
        uint256 expectedDeposit = escrow.collectorDeposit();
        uint256 artisanBalanceBefore = artisan.balance;
        uint256 collectorBalanceBefore = collector.balance;

        escrow.release();

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_FULFILLED));
        assertEq(artisan.balance, artisanBalanceBefore + expectedPrice, "artisan should receive the 100% price");
        assertEq(
            collector.balance, collectorBalanceBefore + expectedDeposit, "collector should get their 20% deposit back"
        );
        assertEq(address(escrow).balance, 0);
    }

    // =================================================================================================
    // Test Case 3 - State updated before external transfer (reentrancy safety)
    // =================================================================================================

    function test_RevertWhen_MaliciousArtisanReentersOnRelease() public {
        MaliciousArtisan malicious = new MaliciousArtisan();

        vm.prank(collector);
        address commission = factory.createCommission{ value: COMMISSION_PRICE }(address(malicious), deadline);
        CommissionEscrow escrow = CommissionEscrow(payable(commission));
        malicious.setEscrow(escrow);

        vm.startPrank(address(malicious));
        escrow.acknowledgeCommission();
        escrow.orderShipped();
        vm.stopPrank();

        vm.prank(collector);
        escrow.confirmDelivery();

        uint256 expectedPrice = escrow.commissionPrice();
        uint256 expectedDeposit = escrow.collectorDeposit();
        uint256 collectorBalanceBefore = collector.balance;

        // This call must succeed exactly once. Inside it, `malicious.receive()` tries to call
        // `release()` again - that reentrant call must fail (status is already ORDER_FULFILLED and
        // `nonReentrant` is still active), while the original call still completes normally.
        escrow.release();

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_FULFILLED));
        assertEq(address(escrow).balance, 0, "escrow must not be drained twice");
        assertEq(address(malicious).balance, expectedPrice, "artisan should still receive exactly one payout");
        assertEq(
            collector.balance, collectorBalanceBefore + expectedDeposit, "collector should still get their deposit back"
        );
        assertTrue(malicious.reentrancyAttempted(), "the mock should have actually attempted reentrancy");
        assertFalse(malicious.reentrancySucceeded(), "the reentrant call must have failed");
    }

    // =================================================================================================
    // Test Case 4 - Timeout produces an explicit refund path
    // =================================================================================================

    function test_RevertWhen_RefundCalledBeforeDeadline() public {
        CommissionEscrow escrow = _createCommission();
        vm.expectRevert(CommissionEscrow.DeadlineNotPassed.selector);
        escrow.refundAfterDeadline();
    }

    function test_RefundAfterDeadlineReturnsFundsToCollector() public {
        CommissionEscrow escrow = _createCommission();
        vm.warp(deadline + 1);

        uint256 collectorBalanceBefore = collector.balance;
        escrow.refundAfterDeadline();

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_CANCELLED_DUE_TO_TIMELINE_EXCEEDED));
        assertEq(collector.balance, collectorBalanceBefore + COMMISSION_PRICE);
        assertEq(address(escrow).balance, 0);
    }

    function test_RefundAfterDeadlineReachableFromAcknowledgedStatus() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledge(escrow);

        vm.warp(deadline + 1);
        uint256 collectorBalanceBefore = collector.balance;
        escrow.refundAfterDeadline();

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_CANCELLED_DUE_TO_TIMELINE_EXCEEDED));
        assertEq(collector.balance, collectorBalanceBefore + COMMISSION_PRICE);
    }

    /// @notice Once the artisan has shipped, a missed deadline is presumptively the *collector's*
    /// fault for not confirming - so self-serve refund must stop working here. Otherwise a silent
    /// collector could simply refund themselves the instant the deadline passes, before the artisan
    /// gets a chance to dispute, defeating the whole confirmation-deposit mechanism.
    function test_RevertWhen_RefundAttemptedAfterShipped() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledgeAndShip(escrow);

        vm.warp(deadline + 1);
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.refundAfterDeadline();
    }

    function test_RevertWhen_RefundAttemptedAfterDeliveryConfirmed() public {
        CommissionEscrow escrow = _createCommission();
        _fullyDeliver(escrow);

        vm.warp(deadline + 1);
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.refundAfterDeadline();
    }

    function test_RevertWhen_RefundAttemptedOnDisputedCommissionAfterDeadline() public {
        CommissionEscrow escrow = _createCommission();

        vm.prank(collector);
        escrow.raiseDispute();

        vm.warp(deadline + 1);
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.refundAfterDeadline();
    }

    // =================================================================================================
    // Test Case 5 - Disputes aren't resolved by either party alone
    // =================================================================================================

    function test_RevertWhen_CollectorVotesOnOwnDispute() public {
        CommissionEscrow escrow = _createCommission();
        _fullyDeliver(escrow);
        vm.prank(collector);
        escrow.raiseDispute();

        vm.prank(collector);
        vm.expectRevert(CommissionEscrow.NotArbiter.selector);
        escrow.castArbiterVote(false);
    }

    function test_RevertWhen_ArtisanVotesOnOwnDispute() public {
        CommissionEscrow escrow = _createCommission();
        vm.prank(collector);
        escrow.raiseDispute();

        vm.prank(artisan);
        vm.expectRevert(CommissionEscrow.NotArbiter.selector);
        escrow.castArbiterVote(true);
    }

    function test_RevertWhen_VotingOnDisputeThatWasNeverRaised() public {
        CommissionEscrow escrow = _createCommission();
        vm.prank(admin); // admin holds ARBITER_ROLE from the factory constructor
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.castArbiterVote(true);
    }

    function test_RaiseDisputeReachableFromAcknowledgedStatus() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledge(escrow);

        vm.prank(artisan);
        escrow.raiseDispute();

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_DISPUTED));
        assertEq(factory.getDisputedCommissions().length, 1);
    }

    function test_RaiseDisputeReachableFromShippedStatus() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledgeAndShip(escrow);

        vm.prank(artisan);
        escrow.raiseDispute();

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_DISPUTED));
    }

    /// @notice The key end-to-end proof of the confirmation-deposit "punishment" mechanism: the
    /// artisan ships, the collector lets the deadline pass without confirming, the artisan disputes,
    /// and the arbiter sides with the artisan. The artisan must receive the *entire* 120% locked
    /// amount (minus the arbiter's 1% fee) - not just the 100% price - with no special-cased
    /// "forfeited deposit" logic required anywhere: `castArbiterVote` already splits the full `amount`.
    function test_ArbiterAwardsFullAmountToArtisanWhenCollectorMissesConfirmationDeadline() public {
        _grantArbiterRole(arbiter);

        CommissionEscrow escrow = _createCommission();
        _acknowledgeAndShip(escrow);
        vm.warp(deadline + 1);

        vm.prank(artisan);
        escrow.raiseDispute();

        uint256 arbiterFee = (COMMISSION_PRICE * escrow.ARBITER_FEE_BPS()) / escrow.BPS_DENOMINATOR();
        uint256 expectedArtisanPayout = COMMISSION_PRICE - arbiterFee;
        uint256 artisanBalanceBefore = artisan.balance;

        vm.prank(arbiter);
        escrow.castArbiterVote(true);

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_DISPUTE_RESOLVED));
        assertEq(
            artisan.balance,
            artisanBalanceBefore + expectedArtisanPayout,
            "artisan should receive the full 120% (minus the arbiter fee), including the forfeited deposit"
        );
        assertGt(
            expectedArtisanPayout,
            escrow.commissionPrice(),
            "payout must exceed the bare price - the deposit was forfeited too"
        );
    }

    function test_SingleArbiterVoteFinalizesDisputeInFavorOfArtisan() public {
        _grantArbiterRole(arbiter);

        CommissionEscrow escrow = _createCommission();
        _fullyDeliver(escrow);
        vm.prank(collector);
        escrow.raiseDispute();

        assertEq(factory.getDisputedCommissions().length, 1, "commission should be listed as disputed");
        assertEq(factory.getDisputedCommissions()[0], address(escrow));

        uint256 artisanBalanceBefore = artisan.balance;
        uint256 arbiterBalanceBefore = arbiter.balance;
        uint256 expectedFee = (COMMISSION_PRICE * escrow.ARBITER_FEE_BPS()) / escrow.BPS_DENOMINATOR();

        vm.prank(arbiter);
        escrow.castArbiterVote(true);

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_DISPUTE_RESOLVED));
        assertEq(
            arbiter.balance, arbiterBalanceBefore + expectedFee, "the lone voting arbiter should earn the full 1% fee"
        );
        assertEq(artisan.balance, artisanBalanceBefore + (COMMISSION_PRICE - expectedFee));
        assertEq(factory.getDisputedCommissions().length, 0, "commission should leave the disputed list");
    }

    function test_SingleArbiterVoteFinalizesDisputeInFavorOfCollector() public {
        _grantArbiterRole(arbiter);

        CommissionEscrow escrow = _createCommission();
        vm.prank(collector);
        escrow.raiseDispute();

        uint256 collectorBalanceBefore = collector.balance;
        uint256 expectedFee = (COMMISSION_PRICE * escrow.ARBITER_FEE_BPS()) / escrow.BPS_DENOMINATOR();

        vm.prank(arbiter);
        escrow.castArbiterVote(false);

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_DISPUTE_RESOLVED));
        assertEq(collector.balance, collectorBalanceBefore + (COMMISSION_PRICE - expectedFee));
    }

    // =================================================================================================
    // Test Case 5b - N-of-M arbiter voting (multi-signature dispute resolution)
    // =================================================================================================

    /// @dev Helper: grants three distinct addresses `ARBITER_ROLE` and raises the factory's
    /// threshold to 2, the shared setup for every multi-arbiter-vote test below.
    function _setUpThreeArbitersWithThresholdOf(uint256 threshold) internal {
        _grantArbiterRole(arbiter);
        _grantArbiterRole(arbiterTwo);
        _grantArbiterRole(arbiterThree);
        vm.prank(admin);
        factory.setArbiterThreshold(threshold);
    }

    function test_SingleVoteDoesNotFinalizeWhenThresholdIsTwo() public {
        _setUpThreeArbitersWithThresholdOf(2);
        CommissionEscrow escrow = _createCommission();
        vm.prank(collector);
        escrow.raiseDispute();

        vm.prank(arbiter);
        escrow.castArbiterVote(true);

        assertEq(
            uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_DISPUTED), "must stay open below threshold"
        );
        assertEq(escrow.getArtisanVoters().length, 1);
        assertEq(factory.getDisputedCommissions().length, 1, "commission stays on the disputed list until finalized");
    }

    function test_SecondMatchingVoteFinalizesAndSplitsFeeEvenlyAmongWinners() public {
        _setUpThreeArbitersWithThresholdOf(2);
        CommissionEscrow escrow = _createCommission();
        vm.prank(collector);
        escrow.raiseDispute();

        vm.prank(arbiter);
        escrow.castArbiterVote(true);

        uint256 totalFee = (COMMISSION_PRICE * escrow.ARBITER_FEE_BPS()) / escrow.BPS_DENOMINATOR();
        uint256 feePerArbiter = totalFee / 2;
        uint256 artisanBalanceBefore = artisan.balance;
        uint256 arbiterBalanceBefore = arbiter.balance;
        uint256 arbiterTwoBalanceBefore = arbiterTwo.balance;

        vm.prank(arbiterTwo);
        escrow.castArbiterVote(true);

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_DISPUTE_RESOLVED));
        assertEq(arbiter.balance, arbiterBalanceBefore + feePerArbiter, "first winning voter gets an equal share");
        assertEq(
            arbiterTwo.balance, arbiterTwoBalanceBefore + feePerArbiter, "second winning voter gets an equal share"
        );
        assertEq(artisan.balance, artisanBalanceBefore + (COMMISSION_PRICE - totalFee));
        assertEq(factory.getDisputedCommissions().length, 0);
    }

    /// @notice The incentive-compatibility proof for N-of-M voting: an arbiter who votes for the
    /// side that does *not* reach the threshold first earns nothing, even though they voted.
    function test_LosingSideVoterReceivesNoFee() public {
        _setUpThreeArbitersWithThresholdOf(2);
        CommissionEscrow escrow = _createCommission();
        vm.prank(collector);
        escrow.raiseDispute();

        vm.prank(arbiter);
        escrow.castArbiterVote(false); // sides with the collector - ends up on the losing side
        uint256 arbiterBalanceBefore = arbiter.balance;

        vm.prank(arbiterTwo);
        escrow.castArbiterVote(true);
        vm.prank(arbiterThree);
        escrow.castArbiterVote(true); // 2 artisan votes reach the threshold first

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_DISPUTE_RESOLVED));
        assertEq(arbiter.balance, arbiterBalanceBefore, "arbiter who voted for the losing side earns nothing");
    }

    function test_RevertWhen_ArbiterVotesTwiceOnSameDispute() public {
        _setUpThreeArbitersWithThresholdOf(2);
        CommissionEscrow escrow = _createCommission();
        vm.prank(collector);
        escrow.raiseDispute();

        vm.prank(arbiter);
        escrow.castArbiterVote(true);

        vm.prank(arbiter);
        vm.expectRevert(CommissionEscrow.AlreadyVoted.selector);
        escrow.castArbiterVote(true);
    }

    /// @notice Proves the full locked `amount` is always accounted for even when the 1% fee doesn't
    /// divide evenly across the winning arbiters - the leftover wei must go to the winning party,
    /// not get stranded in the contract.
    function test_ArbiterFeeDustFoldsIntoPartyPayoutNotStranded() public {
        _setUpThreeArbitersWithThresholdOf(3);
        CommissionEscrow escrow = _createCommission();
        vm.prank(collector);
        escrow.raiseDispute();

        vm.prank(arbiter);
        escrow.castArbiterVote(false);
        vm.prank(arbiterTwo);
        escrow.castArbiterVote(false);

        uint256 collectorBalanceBefore = collector.balance;
        uint256 arbiterBalanceBefore = arbiter.balance;

        vm.prank(arbiterThree);
        escrow.castArbiterVote(false);

        uint256 totalFee = (COMMISSION_PRICE * escrow.ARBITER_FEE_BPS()) / escrow.BPS_DENOMINATOR();
        uint256 feePerArbiter = totalFee / 3;
        uint256 dust = totalFee - (feePerArbiter * 3);
        assertGt(dust, 0, "this test is only meaningful when the fee doesn't divide evenly by 3");

        assertEq(arbiter.balance, arbiterBalanceBefore + feePerArbiter);
        assertEq(collector.balance, collectorBalanceBefore + (COMMISSION_PRICE - totalFee) + dust);
        assertEq(address(escrow).balance, 0, "every wei of the locked amount must be accounted for");
    }

    function test_RevertWhen_StrangerRaisesDispute() public {
        CommissionEscrow escrow = _createCommission();
        vm.prank(stranger);
        vm.expectRevert(CommissionEscrow.NotPartyToDeal.selector);
        escrow.raiseDispute();
    }

    // =================================================================================================
    // Test Case 7 - No double release of the same commission
    // =================================================================================================

    function test_RevertWhen_ReleaseCalledTwice() public {
        CommissionEscrow escrow = _createCommission();
        _fullyDeliver(escrow);
        escrow.release();

        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.release();
    }

    function test_RevertWhen_RefundAfterDeadlineCalledTwice() public {
        CommissionEscrow escrow = _createCommission();
        vm.warp(deadline + 1);
        escrow.refundAfterDeadline();

        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.refundAfterDeadline();
    }

    function test_RevertWhen_VotingAgainAfterDisputeAlreadyResolved() public {
        _grantArbiterRole(arbiter);

        CommissionEscrow escrow = _createCommission();
        vm.prank(collector);
        escrow.raiseDispute();

        // Threshold is 1 by default (see setUp), so this single vote already finalizes the dispute.
        vm.prank(arbiter);
        escrow.castArbiterVote(false);

        vm.prank(arbiter);
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.castArbiterVote(false);
    }

    function test_RevertWhen_ReleaseCalledAfterRefund() public {
        CommissionEscrow escrow = _createCommission();
        vm.warp(deadline + 1);
        escrow.refundAfterDeadline();

        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.release();
    }

    // =================================================================================================
    // Cancellation (ORDER_CANCELLED) - either party, only before shipping
    // =================================================================================================

    function test_ArtisanCancelRefundsCollector() public {
        CommissionEscrow escrow = _createCommission();
        uint256 collectorBalanceBefore = collector.balance;

        vm.prank(artisan);
        escrow.cancel();

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_CANCELLED));
        assertEq(collector.balance, collectorBalanceBefore + COMMISSION_PRICE);
        assertEq(address(escrow).balance, 0);
    }

    function test_CollectorCancelRefundsCollector() public {
        CommissionEscrow escrow = _createCommission();
        uint256 collectorBalanceBefore = collector.balance;

        vm.prank(collector);
        escrow.cancel();

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_CANCELLED));
        assertEq(collector.balance, collectorBalanceBefore + COMMISSION_PRICE);
        assertEq(address(escrow).balance, 0);
    }

    function test_RevertWhen_StrangerCancels() public {
        CommissionEscrow escrow = _createCommission();
        vm.prank(stranger);
        vm.expectRevert(CommissionEscrow.NotPartyToDeal.selector);
        escrow.cancel();
    }

    function test_ArtisanCancelSucceedsAfterAcknowledgement() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledge(escrow);
        uint256 collectorBalanceBefore = collector.balance;

        vm.prank(artisan);
        escrow.cancel();

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_CANCELLED));
        assertEq(collector.balance, collectorBalanceBefore + COMMISSION_PRICE);
    }

    function test_CollectorCancelSucceedsAfterAcknowledgement() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledge(escrow);
        uint256 collectorBalanceBefore = collector.balance;

        vm.prank(collector);
        escrow.cancel();

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_CANCELLED));
        assertEq(collector.balance, collectorBalanceBefore + COMMISSION_PRICE);
    }

    function test_RevertWhen_ArtisanCancelsAfterShipping() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledgeAndShip(escrow);

        vm.prank(artisan);
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.cancel();
    }

    function test_RevertWhen_CollectorCancelsAfterShipping() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledgeAndShip(escrow);

        vm.prank(collector);
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.cancel();
    }
}
