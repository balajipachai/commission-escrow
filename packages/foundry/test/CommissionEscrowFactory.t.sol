// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { CommissionEscrow } from "../contracts/CommissionEscrow.sol";
import { CommissionEscrowFactory } from "../contracts/CommissionEscrowFactory.sol";

/**
 * @title CommissionEscrowFactoryTest
 * @notice Covers the factory's own responsibilities: cheap clone deployment, the global arbiter
 * roster (`AccessControl`), per-collector/per-artisan bookkeeping, and the disputed-commissions
 * "marketplace" list that only genuine commission clones may update.
 */
contract CommissionEscrowFactoryTest is Test {
    CommissionEscrowFactory internal factory;

    address internal admin = makeAddr("admin");
    address internal collector = makeAddr("collector");
    address internal artisan = makeAddr("artisan");
    address internal otherArtisan = makeAddr("otherArtisan");
    address internal arbiter = makeAddr("arbiter");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant COMMISSION_PRICE = 1 ether;
    uint256 internal deadline;

    function setUp() public {
        factory = new CommissionEscrowFactory(admin);
        deadline = block.timestamp + 7 days;
        vm.deal(collector, 100 ether);
    }

    function test_ConstructorGrantsAdminBothRoles() public view {
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(factory.hasRole(factory.ARBITER_ROLE(), admin));
    }

    function test_RevertWhen_ConstructorGivenZeroAddressAdmin() public {
        vm.expectRevert("CommissionEscrowFactory: admin is the zero address");
        new CommissionEscrowFactory(address(0));
    }

    function test_RevertWhen_NonAdminGrantsArbiterRole() public {
        // Both role constants must be read *before* pranking/expecting a revert: calling them inline
        // as arguments would fire as their own calls first and consume the single-shot cheatcode.
        bytes32 arbiterRole = factory.ARBITER_ROLE();
        bytes32 defaultAdminRole = factory.DEFAULT_ADMIN_ROLE();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, defaultAdminRole)
        );
        factory.grantRole(arbiterRole, arbiter);
    }

    function test_AdminCanGrantAndRevokeArbiterRole() public {
        vm.startPrank(admin);
        factory.grantRole(factory.ARBITER_ROLE(), arbiter);
        assertTrue(factory.hasRole(factory.ARBITER_ROLE(), arbiter));

        factory.revokeRole(factory.ARBITER_ROLE(), arbiter);
        assertFalse(factory.hasRole(factory.ARBITER_ROLE(), arbiter));
        vm.stopPrank();
    }

    function test_CreateCommissionClonesCheaplyAndTracksParties() public {
        vm.prank(collector);
        address commission = factory.createCommission{ value: COMMISSION_PRICE }(artisan, deadline);

        assertTrue(factory.isCommission(commission));
        assertEq(factory.totalCommissions(), 1);
        assertEq(factory.getAllCommissions()[0], commission);
        assertEq(factory.getCommissionsByCollector(collector)[0], commission);
        assertEq(factory.getCommissionsByArtisan(artisan)[0], commission);

        // Clones sharing one implementation must not be the same address as the implementation, but
        // every clone's code is far smaller than the implementation's - proving it really is a
        // lightweight EIP-1167 proxy rather than a full re-deployment of CommissionEscrow.
        assertTrue(commission != factory.escrowImplementation());
        assertLt(commission.code.length, factory.escrowImplementation().code.length);
    }

    function test_CreateCommissionForDifferentArtisansAreIndependent() public {
        vm.startPrank(collector);
        address commissionA = factory.createCommission{ value: COMMISSION_PRICE }(artisan, deadline);
        address commissionB = factory.createCommission{ value: COMMISSION_PRICE * 2 }(otherArtisan, deadline);
        vm.stopPrank();

        assertTrue(commissionA != commissionB);
        assertEq(CommissionEscrow(payable(commissionA)).amount(), COMMISSION_PRICE);
        assertEq(CommissionEscrow(payable(commissionB)).amount(), COMMISSION_PRICE * 2);
        assertEq(factory.totalCommissions(), 2);
    }

    function test_RevertWhen_StrangerCallsNotifyDisputedDirectly() public {
        vm.prank(stranger);
        vm.expectRevert("CommissionEscrowFactory: caller is not a commission created by this factory");
        factory.notifyDisputed(stranger);
    }

    function test_RevertWhen_StrangerCallsNotifyDisputeSettledDirectly() public {
        vm.prank(stranger);
        vm.expectRevert("CommissionEscrowFactory: caller is not a commission created by this factory");
        factory.notifyDisputeSettled(stranger);
    }

    function test_DisputedCommissionsListTracksLifecycle() public {
        vm.startPrank(collector);
        address commissionA = factory.createCommission{ value: COMMISSION_PRICE }(artisan, deadline);
        address commissionB = factory.createCommission{ value: COMMISSION_PRICE }(otherArtisan, deadline);
        vm.stopPrank();

        assertEq(factory.getDisputedCommissions().length, 0);

        vm.prank(collector);
        CommissionEscrow(payable(commissionA)).raiseDispute();
        assertEq(factory.getDisputedCommissions().length, 1);

        vm.prank(collector);
        CommissionEscrow(payable(commissionB)).raiseDispute();
        assertEq(factory.getDisputedCommissions().length, 2);

        vm.prank(admin);
        CommissionEscrow(payable(commissionA)).resolveDispute(false);
        assertEq(factory.getDisputedCommissions().length, 1);
        assertEq(factory.getDisputedCommissions()[0], commissionB);
    }
}
