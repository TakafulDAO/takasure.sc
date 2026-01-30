//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

interface IRevShareModule {
    function emergencyMode() external view returns (bool);
    function rewardsDuration() external view returns (uint256);
    function periodFinish() external view returns (uint256);
    function approvedDeposits() external view returns (uint256);
    function revenuesAvailableDate() external view returns (uint256);
    function rewardRateTakadaoScaled() external view returns (uint256);
    function rewardRatePioneersScaled() external view returns (uint256);
    function lastUpdateTime() external view returns (uint256);
    function revenuePerNftOwnedByPioneers() external view returns (uint256);
    function takadaoRevenueScaled() external view returns (uint256);
    function revenuePerAccount(address account) external view returns (uint256);
    function pioneerRevenuePerNftPaid(address pioneer) external view returns (uint256);
    function initialize(address _addressManagerAddress, string calldata _moduleName) external;
    function setAvailableDate(uint256 timestamp) external;
    function setRewardsDuration(uint256 duration) external;
    function releaseRevenues() external;
    function notifyNewRevenue(uint256 amount) external;
    function sweepNonApprovedDeposits() external;
    function emergencyWithdraw() external;
    function depositNoStream(uint256 amount) external;
    function resumeAfterEmergency() external;
    function claimRevenueShare() external returns (uint256 revenue);
    function updateRevenue(address pioneer) external;
    function lastTimeApplicable() external view returns (uint256);
    function getRevenueForDuration(uint256 duration) external view returns (uint256, uint256);
    function earnedByPioneers(address account) external view returns (uint256);
    function earnedByTakadao(address account) external view returns (uint256);
    function getRevenuePerNftOwnedByPioneers() external view returns (uint256);
    function getTakadaoRevenueScaled() external view returns (uint256);
}
