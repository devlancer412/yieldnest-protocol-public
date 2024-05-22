// SPDX-License-Identifier: BSD 3-Clause License
pragma solidity ^0.8.24;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IDelayedWithdrawalRouter} from "contracts/external/eigenlayer-contracts/IDelayedWithdrawalRouter.sol";
import {IDelegationManager} from "contracts/external/eigenlayer-contracts/IDelegationManager.sol";
import {IStrategyManager} from "contracts/external/eigenlayer-contracts/IStrategyManager.sol";
import {RewardsType} from "contracts/interfaces/IRewardsDistributor.sol";
import {IEigenPodManager} from "contracts/external/eigenlayer-contracts/IEigenPodManager.sol";
import {IStakingNode} from "contracts/interfaces/IStakingNode.sol";

interface IStakingNodesManager {
  struct ValidatorData {
    bytes publicKey;
    bytes signature;
    bytes32 depositDataRoot;
    uint nodeId;
  }

  struct Validator {
    bytes publicKey;
    uint nodeId;
  }

  function eigenPodManager() external view returns (IEigenPodManager);
  function delegationManager() external view returns (IDelegationManager);
  function strategyManager() external view returns (IStrategyManager);

  function delayedWithdrawalRouter() external view returns (IDelayedWithdrawalRouter);
  function getAllValidators() external view returns (Validator[] memory);
  function getAllNodes() external view returns (IStakingNode[] memory);
  function isStakingNodesOperator(address) external view returns (bool);
  function isStakingNodesDelegator(address _address) external view returns (bool);
  function processRewards(uint nodeId, RewardsType rewardsType) external payable;
  function registerValidators(ValidatorData[] calldata _depositData) external;
  function nodesLength() external view returns (uint);

  function upgradeableBeacon() external returns (UpgradeableBeacon);
}
