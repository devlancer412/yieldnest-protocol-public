// SPDX-License-Identifier: BSD 3-Clause License
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureUtils} from "contracts/external/eigenlayer-contracts/ISignatureUtils.sol";
import {IynLSD} from "contracts/interfaces/IynLSD.sol";

interface ILSDStakingNode {
  /// @notice Configuration for contract initialization.
  struct Init {
    IynLSD ynLSD;
    uint nodeId;
  }

  function nodeId() external returns (uint256);

  function initialize(Init calldata init) external;

  function depositAssetsToEigenlayer(IERC20[] memory assets, uint256[] memory amounts) external;

  function ynLSD() external view returns (IynLSD);

  function implementation() external view returns (address);

  function getInitializedVersion() external view returns (uint64);

  function delegate(
    address operator,
    ISignatureUtils.SignatureWithExpiry memory signature,
    bytes32 approverSalt
  ) external;

  function undelegate() external;

  function recoverAssets(IERC20 asset) external;
}
