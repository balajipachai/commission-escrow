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
    address internal stranger = makeAddr("stranger");

    uint256 internal constant COMMISSION_PRICE = 2 ether;
    uint256 internal deadline;

    function setUp() public {
        // `admin` is passed as both the admin and the initial arbiter here purely for test
        // convenience (see CommissionEscrowFactory.t.sol for coverage of them being distinct).
        factory = new CommissionEscrowFactory(admin, admin);
        deadline = block.timestamp + 7 days;

        vm.deal(collector, 100 ether);
        vm.deal(artisan, 10 ether);
        vm.deal(arbiter, 10 ether);
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

    /// @dev Helper: walks a fresh commission all the way to ORDER_DELIVERED (artisan acknowledges,
    /// then collector confirms delivery), the prerequisite state for `release()`.
    function _acknowledgeAndConfirmDelivery(CommissionEscrow escrow) internal {
        _acknowledge(escrow);
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

    function test_RevertWhen_ConfirmDeliveryBeforeAcknowledgement() public {
        CommissionEscrow escrow = _createCommission();
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
    /// acknowledging the commission - must revert.
    function test_RevertWhen_ArtisanConfirmsOwnDelivery() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledge(escrow);

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

    function test_ReleaseSucceedsOnlyAfterCollectorConfirmsDelivery() public {
        CommissionEscrow escrow = _createCommission();

        _acknowledge(escrow);
        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_ACKNOWLEDGED));

        vm.prank(collector);
        escrow.confirmDelivery();
        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_DELIVERED));

        uint256 artisanBalanceBefore = artisan.balance;
        escrow.release();

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_FULFILLED));
        assertEq(artisan.balance, artisanBalanceBefore + COMMISSION_PRICE);
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

        vm.prank(address(malicious));
        escrow.acknowledgeCommission();

        vm.prank(collector);
        escrow.confirmDelivery();

        // This call must succeed exactly once. Inside it, `malicious.receive()` tries to call
        // `release()` again - that reentrant call must fail (status is already ORDER_FULFILLED and
        // `nonReentrant` is still active), while the original call still completes normally.
        escrow.release();

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_FULFILLED));
        assertEq(address(escrow).balance, 0, "escrow must not be drained twice");
        assertEq(address(malicious).balance, COMMISSION_PRICE, "artisan should still receive exactly one payout");
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

    function test_RevertWhen_RefundAttemptedAfterDeliveryConfirmed() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledgeAndConfirmDelivery(escrow);

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

    function test_RevertWhen_CollectorResolvesOwnDispute() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledgeAndConfirmDelivery(escrow);
        vm.prank(collector);
        escrow.raiseDispute();

        vm.prank(collector);
        vm.expectRevert(CommissionEscrow.NotArbiter.selector);
        escrow.resolveDispute(false);
    }

    function test_RevertWhen_ArtisanResolvesOwnDispute() public {
        CommissionEscrow escrow = _createCommission();
        vm.prank(collector);
        escrow.raiseDispute();

        vm.prank(artisan);
        vm.expectRevert(CommissionEscrow.NotArbiter.selector);
        escrow.resolveDispute(true);
    }

    function test_RevertWhen_ResolvingDisputeThatWasNeverRaised() public {
        CommissionEscrow escrow = _createCommission();
        vm.prank(admin); // admin holds ARBITER_ROLE from the factory constructor
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.resolveDispute(true);
    }

    function test_RaiseDisputeReachableFromAcknowledgedStatus() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledge(escrow);

        vm.prank(artisan);
        escrow.raiseDispute();

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_DISPUTED));
        assertEq(factory.getDisputedCommissions().length, 1);
    }

    function test_ApprovedArbiterResolvesDisputeInFavorOfArtisan() public {
        _grantArbiterRole(arbiter);

        CommissionEscrow escrow = _createCommission();
        _acknowledgeAndConfirmDelivery(escrow);
        vm.prank(collector);
        escrow.raiseDispute();

        assertEq(factory.getDisputedCommissions().length, 1, "commission should be listed as disputed");
        assertEq(factory.getDisputedCommissions()[0], address(escrow));

        uint256 artisanBalanceBefore = artisan.balance;
        uint256 arbiterBalanceBefore = arbiter.balance;
        uint256 expectedFee = (COMMISSION_PRICE * escrow.ARBITER_FEE_BPS()) / escrow.BPS_DENOMINATOR();

        vm.prank(arbiter);
        escrow.resolveDispute(true);

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_DISPUTE_RESOLVED));
        assertEq(arbiter.balance, arbiterBalanceBefore + expectedFee, "arbiter should earn the 1% fee");
        assertEq(artisan.balance, artisanBalanceBefore + (COMMISSION_PRICE - expectedFee));
        assertEq(factory.getDisputedCommissions().length, 0, "commission should leave the disputed list");
    }

    function test_ApprovedArbiterResolvesDisputeInFavorOfCollector() public {
        _grantArbiterRole(arbiter);

        CommissionEscrow escrow = _createCommission();
        vm.prank(collector);
        escrow.raiseDispute();

        uint256 collectorBalanceBefore = collector.balance;
        uint256 expectedFee = (COMMISSION_PRICE * escrow.ARBITER_FEE_BPS()) / escrow.BPS_DENOMINATOR();

        vm.prank(arbiter);
        escrow.resolveDispute(false);

        assertEq(uint256(escrow.status()), uint256(CommissionEscrow.Status.ORDER_DISPUTE_RESOLVED));
        assertEq(collector.balance, collectorBalanceBefore + (COMMISSION_PRICE - expectedFee));
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
        _acknowledgeAndConfirmDelivery(escrow);
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

    function test_RevertWhen_ResolveDisputeCalledTwice() public {
        _grantArbiterRole(arbiter);

        CommissionEscrow escrow = _createCommission();
        vm.prank(collector);
        escrow.raiseDispute();

        vm.prank(arbiter);
        escrow.resolveDispute(false);

        vm.prank(arbiter);
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.resolveDispute(false);
    }

    function test_RevertWhen_ReleaseCalledAfterRefund() public {
        CommissionEscrow escrow = _createCommission();
        vm.warp(deadline + 1);
        escrow.refundAfterDeadline();

        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.release();
    }

    // =================================================================================================
    // Cancellation (ORDER_CANCELLED) - either party, only before acknowledgment
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

    function test_RevertWhen_ArtisanCancelsAfterAcknowledgement() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledge(escrow);

        vm.prank(artisan);
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.cancel();
    }

    function test_RevertWhen_CollectorCancelsAfterAcknowledgement() public {
        CommissionEscrow escrow = _createCommission();
        _acknowledge(escrow);

        vm.prank(collector);
        vm.expectRevert(CommissionEscrow.InvalidStatus.selector);
        escrow.cancel();
    }
}
