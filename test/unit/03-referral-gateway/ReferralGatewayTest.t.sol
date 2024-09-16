// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployReferralGateway} from "test/utils/TestDeployReferralGateway.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";

contract ReferralGatewayTest is Test {
    TestDeployReferralGateway deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    address proxy;
    address takadao;
    address ambassador = makeAddr("ambassador");

    bytes32 private constant AMBASSADOR = keccak256("AMBASSADOR");

    event OnPreJoinEnabledChanged(bool indexed isPreJoinEnabled);
    event OnNewAmbassadorProposal(address indexed proposedAmbassador);
    event OnNewAmbassador(address indexed ambassador);

    function setUp() public {
        deployer = new TestDeployReferralGateway();
        (, proxy, helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        takadao = config.takadaoOperator;

        referralGateway = ReferralGateway(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/
    function testSetIsPreJoinEnabled() public {
        assert(referralGateway.isPreJoinEnabled());

        vm.prank(takadao);
        vm.expectEmit(true, false, false, false, address(referralGateway));
        emit OnPreJoinEnabledChanged(false);
        referralGateway.setPreJoinEnabled(false);

        assert(!referralGateway.isPreJoinEnabled());
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testPropossedAmbassadorMustRevertIfIsAddressZero() public {
        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.proposeAsAmbassador(address(0));
    }

    function testApproveAmbassadorMustRevertIfIsAddressZero() public {
        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.approveAsAmbassador(address(0));
    }

    function testMustRevertIfAmbassadorIsNotPreviouslyProposed() public {
        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__OnlyProposedAmbassadors.selector);
        referralGateway.approveAsAmbassador(ambassador);
    }

    /*//////////////////////////////////////////////////////////////
                              AMBASSADORS
    //////////////////////////////////////////////////////////////*/

    function testProposeAsAmbassadorCalledByOther() public {
        assert(!referralGateway.proposedAmbassadors(ambassador));
        vm.prank(takadao);
        vm.expectEmit(true, false, false, false, address(referralGateway));
        emit OnNewAmbassadorProposal(ambassador);
        referralGateway.proposeAsAmbassador(ambassador);

        assert(referralGateway.proposedAmbassadors(ambassador));
    }

    function testProposeAsAmbassadorCalledBySelf() public {
        assert(!referralGateway.proposedAmbassadors(ambassador));
        vm.prank(ambassador);
        vm.expectEmit(true, false, false, false, address(referralGateway));
        emit OnNewAmbassadorProposal(ambassador);
        referralGateway.proposeAsAmbassador();

        assert(referralGateway.proposedAmbassadors(ambassador));
    }

    modifier proposeAsAmbassador() {
        vm.prank(takadao);
        referralGateway.proposeAsAmbassador(ambassador);
        _;
    }

    function testApproveAsAmbassador() public proposeAsAmbassador {
        assert(!referralGateway.hasRole(AMBASSADOR, ambassador));
        vm.prank(takadao);
        vm.expectEmit(true, false, false, false, address(referralGateway));
        emit OnNewAmbassador(ambassador);
        referralGateway.approveAsAmbassador(ambassador);

        assert(referralGateway.hasRole(AMBASSADOR, ambassador));
        assertEq(referralGateway.parentRewards(ambassador), 0);
    }
}
