// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {SaveFundsInvestCREReceiver} from "contracts/helpers/chainlink/automation/SaveFundsInvestCREReceiver.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract SaveFundsInvestCREReceiverTest is Test {
    string internal constant CRE_FORWARDER_NAME = "EXTERNAL__CL_CRE_FORWARDER";
    string internal constant SAVE_FUNDS_RUNNER_NAME = "HELPER__SF_INVEST_RUNNER";
    string internal constant CRE_WORKFLOW_OWNER_NAME = "ADMIN__CRE_WORKFLOW_OWNER";

    DeployManagers internal managerDeployer;
    AddressManager internal addressManager;
    SaveFundsInvestCREReceiver internal receiver;
    MockSaveFundsInvestRunner internal mockRunner;

    address internal owner;
    address internal operator;
    address internal forwarder;
    address internal workflowOwner;

    function setUp() public {
        managerDeployer = new DeployManagers();
        (, addressManager,) = managerDeployer.run();

        owner = addressManager.owner();
        operator = makeAddr("operator");
        forwarder = makeAddr("forwarder");
        workflowOwner = makeAddr("workflowOwner");

        mockRunner = new MockSaveFundsInvestRunner();

        vm.startPrank(owner);
        addressManager.createNewRole(Roles.OPERATOR);
        addressManager.proposeRoleHolder(Roles.OPERATOR, operator);
        addressManager.addProtocolAddress(SAVE_FUNDS_RUNNER_NAME, address(mockRunner), ProtocolAddressType.Helper);
        addressManager.addProtocolAddress(CRE_FORWARDER_NAME, forwarder, ProtocolAddressType.External);
        vm.stopPrank();

        vm.prank(operator);
        addressManager.acceptProposedRole(Roles.OPERATOR);

        receiver = new SaveFundsInvestCREReceiver(addressManager);
    }

    function testReceiver_onReport_ForwardsAuthorizedReportToRunner() public {
        bytes memory metadata = "";
        bytes memory report = hex"1234";
        bytes32 executionKey = keccak256(abi.encode(metadata, report));

        vm.prank(forwarder);
        receiver.onReport(metadata, report);

        assertEq(mockRunner.performCount(), 1, "performUpkeep call count");
        assertEq(mockRunner.lastPerformData(), bytes(""), "performData mismatch");
        assertTrue(receiver.consumedReports(executionKey), "report not marked consumed");
    }

    function testReceiver_onReport_RevertsForUnauthorizedCaller() public {
        address stranger = makeAddr("stranger");

        vm.expectRevert(
            abi.encodeWithSelector(
                SaveFundsInvestCREReceiver.SaveFundsInvestCREReceiver__InvalidSender.selector, stranger, forwarder
            )
        );
        vm.prank(stranger);
        receiver.onReport("", "");
    }

    function testReceiver_onReport_RevertsForDuplicateReport() public {
        bytes memory metadata = "";
        bytes memory report = hex"beef";
        bytes32 executionKey = keccak256(abi.encode(metadata, report));

        vm.prank(forwarder);
        receiver.onReport(metadata, report);

        vm.expectRevert(
            abi.encodeWithSelector(
                SaveFundsInvestCREReceiver.SaveFundsInvestCREReceiver__DuplicateReport.selector, executionKey
            )
        );
        vm.prank(forwarder);
        receiver.onReport(metadata, report);
    }

    function testReceiver_onReport_RevertsForInvalidWorkflowId() public {
        bytes32 expectedWorkflowId = keccak256("expected-workflow");
        bytes32 receivedWorkflowId = keccak256("received-workflow");

        vm.prank(operator);
        receiver.setExpectedWorkflowId(expectedWorkflowId);

        bytes memory metadata = _encodeMetadata(receivedWorkflowId, bytes10(0), address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                SaveFundsInvestCREReceiver.SaveFundsInvestCREReceiver__InvalidWorkflowId.selector,
                receivedWorkflowId,
                expectedWorkflowId
            )
        );
        vm.prank(forwarder);
        receiver.onReport(metadata, "");
    }

    function testReceiver_onReport_RevertsForInvalidWorkflowOwner() public {
        address wrongWorkflowOwner = makeAddr("wrongWorkflowOwner");
        bytes memory metadata = _encodeMetadata(bytes32(0), bytes10(0), wrongWorkflowOwner);

        vm.prank(owner);
        addressManager.addProtocolAddress(CRE_WORKFLOW_OWNER_NAME, workflowOwner, ProtocolAddressType.Admin);

        vm.expectRevert(
            abi.encodeWithSelector(
                SaveFundsInvestCREReceiver.SaveFundsInvestCREReceiver__InvalidAuthor.selector,
                wrongWorkflowOwner,
                workflowOwner
            )
        );
        vm.prank(forwarder);
        receiver.onReport(metadata, "");
    }

    function testReceiver_onReport_RevertsWhenWorkflowNameValidationHasNoAuthorConfigured() public {
        vm.prank(operator);
        receiver.setExpectedWorkflowName("save-funds-cre");

        bytes memory metadata = _encodeMetadata(bytes32(0), receiver.expectedWorkflowName(), address(0));

        vm.expectRevert(
            SaveFundsInvestCREReceiver.SaveFundsInvestCREReceiver__WorkflowNameRequiresAuthorValidation.selector
        );
        vm.prank(forwarder);
        receiver.onReport(metadata, "");
    }

    function _encodeMetadata(bytes32 workflowId, bytes10 workflowName, address owner_)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(workflowId, workflowName, owner_);
    }
}

contract MockSaveFundsInvestRunner {
    uint256 public performCount;
    bytes public lastPerformData;

    function performUpkeep(bytes calldata performData) external {
        ++performCount;
        lastPerformData = performData;
    }
}
