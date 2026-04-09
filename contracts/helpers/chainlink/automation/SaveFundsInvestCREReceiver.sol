// SPDX-License-Identifier: GPL-3.0

/**
 * @title SaveFundsInvestCREReceiver
 * @author Maikel Ordaz
 * @notice Chainlink CRE receiver/proxy for Save Funds automated investments.
 * @dev This contract is the CRE-facing entrypoint for Save Funds investment automation.
 *      A Chainlink `KeystoneForwarder` delivers validated workflow reports to `onReport`,
 *      this receiver validates the configured forwarder and can further restrict accepted
 *      reports by workflow identity metadata before forwarding execution to
 *      `SaveFundsInvestAutomationRunner.performUpkeep("")`.
 * @dev The contract follows the repository's shared address-resolution model by using
 *      `AddressManager` for environment-specific address discovery. The forwarder, runner,
 *      and optional workflow-author address are resolved from AddressManager instead of
 *      being stored and updated locally in this contract.
 * @dev The runner remains the canonical business-logic contract. This receiver is intentionally
 *      thin and should only handle CRE-specific concerns such as forwarder validation,
 *      workflow identity checks, and report replay protection.
 * @dev In this architecture, the receiver does not decode the workflow report into business
 *      parameters. The report is treated only as authenticated execution context and as an
 *      input to replay protection and observability, while the runner re-reads all required
 *      onchain state during `performUpkeep`. This avoids splitting execution rules across
 *      two contracts and keeps the runner as the single source of truth for investment logic.
 */

pragma solidity 0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ProtocolAddress} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {IReceiver} from "contracts/helpers/chainlink/automation/interfaces/IReceiver.sol";
import {
    ISaveFundsInvestAutomationRunnerExecutor
} from "contracts/helpers/chainlink/automation/interfaces/ISaveFundsInvestAutomationRunnerExecutor.sol";

contract SaveFundsInvestCREReceiver is IReceiver {
    bytes private constant HEX_CHARS = "0123456789abcdef";
    uint256 private constant WORKFLOW_METADATA_LENGTH = 62;
    string private constant CRE_FORWARDER_NAME = "EXTERNAL__CL_CRE_FORWARDER";
    string private constant SAVE_FUNDS_RUNNER_NAME = "HELPER__SF_INVEST_RUNNER"; // todo: review naming
    string private constant CRE_WORKFLOW_OWNER_NAME = "ADMIN__CRE_WORKFLOW_OWNER";

    IAddressManager private immutable addressManager;
    ISaveFundsInvestAutomationRunnerExecutor private immutable runner; // Business-logic contract that performs the investment cycle

    /// @notice Optional expected workflow name encoded in CRE's `bytes10` metadata format.
    bytes10 public expectedWorkflowName; // `bytes10(0)` disables workflow-name validation.

    /// @notice Optional expected workflow ID.
    bytes32 public expectedWorkflowId; // `bytes32(0)` disables workflow-ID validation.

    /// @notice Tracks metadata/report pairs already consumed by this receiver.
    mapping(bytes32 executionKey => bool consumed) public consumedReports; // The key is `keccak256(abi.encode(metadata, report))`.

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnExpectedWorkflowNameUpdated(bytes10 indexed previousName, bytes10 indexed newName);
    event OnExpectedWorkflowIdUpdated(bytes32 indexed previousId, bytes32 indexed newId);
    event OnReportReceived(
        bytes32 indexed executionKey,
        bytes32 indexed workflowId,
        address indexed workflowOwner,
        bytes10 workflowName,
        bytes32 reportHash
    );
    event OnReportConsumed(bytes32 indexed executionKey, bytes32 indexed reportHash);

    error SaveFundsInvestCREReceiver__NotAddressZero();
    error SaveFundsInvestCREReceiver__NotAuthorizedCaller();
    error SaveFundsInvestCREReceiver__InvalidSender(address sender, address expected);
    error SaveFundsInvestCREReceiver__InvalidMetadataLength(uint256 length);
    error SaveFundsInvestCREReceiver__InvalidAuthor(address received, address expected);
    error SaveFundsInvestCREReceiver__InvalidWorkflowName(bytes10 received, bytes10 expected);
    error SaveFundsInvestCREReceiver__InvalidWorkflowId(bytes32 received, bytes32 expected);
    error SaveFundsInvestCREReceiver__WorkflowNameRequiresAuthorValidation();
    error SaveFundsInvestCREReceiver__DuplicateReport(bytes32 executionKey);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyRole(bytes32 role) {
        require(addressManager.hasRole(role, msg.sender), SaveFundsInvestCREReceiver__NotAuthorizedCaller());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Forwarder, runner, and optional workflow-author addresses are resolved on demand from AddressManager using the following names:
     *      - `EXTERNAL__CL_CRE_FORWARDER`
     *      - `HELPER__SF_INVEST_RUNNER`
     *      - `ADMIN__CRE_WORKFLOW_OWNER`
     */
    constructor(IAddressManager _addressManager) {
        require(address(_addressManager) != address(0), SaveFundsInvestCREReceiver__NotAddressZero());
        addressManager = _addressManager;
        runner = ISaveFundsInvestAutomationRunnerExecutor(
            addressManager.getProtocolAddressByName(SAVE_FUNDS_RUNNER_NAME).addr
        );
    }

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the expected workflow name using the plaintext CRE workflow name.
     * @param _name Plaintext workflow name. Pass an empty string to disable this check.
     * @dev Workflow-name validation lets this receiver accept only reports associated with a
     *      specific named CRE workflow owned by `expectedAuthor`.
     * @dev CRE encodes workflow names as the first 10 ASCII characters of the SHA256 hash's
     *      hex string representation. This function applies the same transformation onchain.
     * @dev Workflow-name validation must never be used without author validation because
     *      workflow names are only unique per owner and use a truncated representation.
     * @custom:invariant After a successful call, `expectedWorkflowName` equals either
     *      `bytes10(0)` when `_name` is empty or the onchain-encoded CRE workflow name for `_name`.
     */
    function setExpectedWorkflowName(string calldata _name) external onlyRole(Roles.OPERATOR) {
        bytes10 previousName = expectedWorkflowName;

        if (bytes(_name).length == 0) {
            expectedWorkflowName = bytes10(0);
            emit OnExpectedWorkflowNameUpdated(previousName, bytes10(0));
            return;
        }

        expectedWorkflowName = _encodeWorkflowName(_name);
        emit OnExpectedWorkflowNameUpdated(previousName, expectedWorkflowName);
    }

    /**
     * @notice Updates the expected workflow ID.
     * @param _id Expected workflow ID. Set to `bytes32(0)` to disable this check.
     * @dev Workflow-ID validation lets this receiver accept only reports produced by one
     *      specific deployed CRE workflow.
     * @dev Use workflow-ID validation when only a single CRE workflow should ever write here.
     * @custom:invariant After a successful call, `expectedWorkflowId == _id`.
     */
    function setExpectedWorkflowId(bytes32 _id) external onlyRole(Roles.OPERATOR) {
        bytes32 previousId = expectedWorkflowId;
        expectedWorkflowId = _id;

        emit OnExpectedWorkflowIdUpdated(previousId, _id);
    }

    /*//////////////////////////////////////////////////////////////
                              CRE ENTRYPOINT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Processes a validated CRE report and forwards execution to the runner.
     * @param metadata Workflow metadata packed by the Chainlink forwarder.
     * @param report ABI-encoded workflow payload.
     * @dev Security checks are:
     *      1. configured forwarder validation via AddressManager
     *      2. optional workflow ID validation
     *      3. optional workflow owner validation
     *      4. optional workflow-name validation, which requires owner validation
     *      5. exact replay protection on `(metadata, report)`
     * @dev This function intentionally does not decode the report into investment parameters.
     *      The downstream runner re-reads live state and revalidates execution conditions
     *      onchain so investment logic remains centralized in the runner.
     * @dev The flow of this call will be:
     *      1. CRE workflow -> runner.checkUpkeep. If true, continue.
     *      2. CRE workflow -> forwarder
     *      3. forwarder -> receiver.onReport
     *      4. receiver.onReport -> runner.performUpkeep
     *      5. runner.performUpkeep -> vault.investIntoStrategy. Runner must hold KEEPER role
     * @custom:invariant A consumed `(metadata, report)` pair cannot be processed again.
     * @custom:invariant Successful executions always call `runner.performUpkeep("")` exactly once.
     * @custom:invariant Successful executions always mark `consumedReports[keccak256(abi.encode(metadata, report))]`
     *      as `true`.
     */
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        // Only the configured Chainlink forwarder may deliver reports to this receiver.
        // The forwarder is the Chainlink entrypoint authorized to deliver validated CRE workflow reports to `onReport`.
        address _forwarder = addressManager.getProtocolAddressByName(CRE_FORWARDER_NAME).addr;
        require(
            msg.sender == _forwarder,
            SaveFundsInvestCREReceiver__InvalidSender(msg.sender, _forwarder)
        );
        require(
            metadata.length == 0 || metadata.length == WORKFLOW_METADATA_LENGTH,
            SaveFundsInvestCREReceiver__InvalidMetadataLength(metadata.length)
        );

        // Replays are blocked per exact `(metadata, report)` pair.
        bytes32 executionKey = keccak256(abi.encode(metadata, report));
        require(!consumedReports[executionKey], SaveFundsInvestCREReceiver__DuplicateReport(executionKey));

        bytes32 workflowId;
        bytes10 workflowName;
        address workflowOwner;
        address _expectedAuthor = expectedAuthor();

        bool hasWorkflowChecks =
            expectedWorkflowId != bytes32(0) || _expectedAuthor != address(0) || expectedWorkflowName != bytes10(0);

        if (metadata.length == WORKFLOW_METADATA_LENGTH) {
            // Metadata is only decoded when present because author/name/id checks depend on it.
            (workflowId, workflowName, workflowOwner) = _decodeMetadata(metadata);
        }
        require(
            !hasWorkflowChecks || metadata.length == WORKFLOW_METADATA_LENGTH,
            SaveFundsInvestCREReceiver__InvalidMetadataLength(metadata.length)
        );

        require(
            expectedWorkflowId == bytes32(0) || workflowId == expectedWorkflowId,
            SaveFundsInvestCREReceiver__InvalidWorkflowId(workflowId, expectedWorkflowId)
        );
        require(
            _expectedAuthor == address(0) || workflowOwner == _expectedAuthor,
            SaveFundsInvestCREReceiver__InvalidAuthor(workflowOwner, _expectedAuthor)
        );

        if (expectedWorkflowName != bytes10(0)) {
            // Workflow names are only unique within a workflow owner namespace.
            require(_expectedAuthor != address(0), SaveFundsInvestCREReceiver__WorkflowNameRequiresAuthorValidation());
            require(
                workflowName == expectedWorkflowName,
                SaveFundsInvestCREReceiver__InvalidWorkflowName(workflowName, expectedWorkflowName)
            );
        }

        bytes32 reportHash = keccak256(report);
        emit OnReportReceived(executionKey, workflowId, workflowOwner, workflowName, reportHash);

        // The receiver authenticates CRE context; the runner remains the execution engine.
        runner.performUpkeep("");

        consumedReports[executionKey] = true;
        emit OnReportConsumed(executionKey, reportHash);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the resolved expected CRE workflow owner.
     * @return author_ Address registered in AddressManager under `ADMIN__CRE_WORKFLOW_OWNER`.
     *         Returns `address(0)` when no such protocol address is configured.
     * @dev `address(0)` disables owner validation.
     * @dev Owner validation remains optional. If this name is not configured in AddressManager,
     *      the receiver behaves as if author validation were disabled.
     * @dev The expected author is the workflow owner allowed to target this receiver when
     *      author-based workflow identity checks are enabled.
     * @custom:invariant Function never reverts for a missing `ADMIN__CRE_WORKFLOW_OWNER` entry;
     *      it returns `address(0)` instead.
     */
    function expectedAuthor() public view returns (address author_) {
        try addressManager.getProtocolAddressByName(CRE_WORKFLOW_OWNER_NAME) returns (
            ProtocolAddress memory protocolAddress
        ) {
            author_ = protocolAddress.addr;
        } catch {
            author_ = address(0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Decodes CRE workflow metadata delivered by the forwarder.
     * @param metadata Packed metadata bytes encoded as
     *        `abi.encodePacked(bytes32 workflowId, bytes10 workflowName, address workflowOwner)`.
     * @return workflowId Unique workflow identifier.
     * @return workflowName Encoded workflow name.
     * @return workflowOwner Workflow owner address.
     * @dev Reverts unless `metadata.length == 62`.
     * @custom:invariant On success, returned values are decoded from the exact packed metadata layout
     *      `(bytes32 workflowId, bytes10 workflowName, address workflowOwner)`.
     */
    function _decodeMetadata(bytes calldata metadata)
        internal
        pure
        returns (bytes32 workflowId, bytes10 workflowName, address workflowOwner)
    {
        require(
            metadata.length == WORKFLOW_METADATA_LENGTH,
            SaveFundsInvestCREReceiver__InvalidMetadataLength(metadata.length)
        );

        assembly {
            let offset := metadata.offset
            workflowId := calldataload(offset)
            workflowName := calldataload(add(offset, 32))
            workflowOwner := shr(96, calldataload(add(offset, 42)))
        }
    }

    /**
     * @notice Encodes a plaintext workflow name into CRE's `bytes10` metadata representation.
     * @param _name Plaintext workflow name.
     * @return encodedName Encoded `bytes10` workflow name.
     * @dev Encoding steps:
     *      1. SHA256 hash the plaintext name
     *      2. Convert the hash to a lowercase hex string
     *      3. Take the first 10 ASCII characters
     *      4. Treat those 10 ASCII bytes as `bytes10`
     * @custom:invariant On success, the return value is deterministic for `_name` and always has length 10 bytes.
     */
    function _encodeWorkflowName(string memory _name) internal pure returns (bytes10 encodedName) {
        // CRE workflow name are SHA-256 based, so keccak256 cannot be used here.
        bytes32 hash = sha256(bytes(_name));
        bytes memory hexString = _bytesToHexString(abi.encodePacked(hash));
        bytes memory first10 = new bytes(10);

        for (uint256 i; i < 10; ++i) {
            first10[i] = hexString[i];
        }

        assembly {
            encodedName := mload(add(first10, 32))
        }
    }

    /**
     * @notice Converts arbitrary bytes to a lowercase hex string without `0x` prefix.
     * @param data Bytes to convert.
     * @return hexString Lowercase hex string bytes.
     * @custom:invariant On success, `hexString.length == data.length * 2`.
     */
    function _bytesToHexString(bytes memory data) internal pure returns (bytes memory hexString) {
        hexString = new bytes(data.length * 2);

        for (uint256 i; i < data.length; ++i) {
            hexString[i * 2] = HEX_CHARS[uint8(data[i] >> 4)];
            hexString[i * 2 + 1] = HEX_CHARS[uint8(data[i] & 0x0f)];
        }
    }

    /**
     * @notice Advertises ERC165 and Chainlink receiver support.
     * @param interfaceId Interface identifier to query.
     * @return True when `interfaceId` is supported.
     * @custom:invariant Function always returns true for `type(IReceiver).interfaceId` and `type(IERC165).interfaceId`.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
