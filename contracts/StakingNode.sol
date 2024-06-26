/// SPDX-License-Identifier: BSD 3-Clause License
pragma solidity ^0.8.24;

import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {BeaconChainProofs} from "contracts/external/eigenlayer-contracts/libraries/BeaconChainProofs.sol";
import {IDelegationManager} from "contracts/external/eigenlayer-contracts/IDelegationManager.sol";
import {IEigenPod} from "contracts/external/eigenlayer-contracts/IEigenPod.sol";
import {ISignatureUtils} from "contracts/external/eigenlayer-contracts/ISignatureUtils.sol";
import {IStrategy} from "contracts/external/eigenlayer-contracts/IStrategy.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {IEigenPodManager} from "contracts/external/eigenlayer-contracts/IEigenPodManager.sol";
import {IStakingNodesManager} from "contracts/interfaces/IStakingNodesManager.sol";
import {IStakingNode} from "contracts/interfaces/IStakingNode.sol";
import {RewardsType} from "contracts/interfaces/IRewardsDistributor.sol";

interface StakingNodeEvents {
  event EigenPodCreated(address indexed nodeAddress, address indexed podAddress);
  event Delegated(address indexed operator, bytes32 approverSalt);
  event Undelegated(address indexed operator);
  event NonBeaconChainETHWithdrawalsProcessed(uint256 claimedAmount);
  event ETHReceived(address sender, uint256 value);
  event WithdrawnNonBeaconChainETH(uint256 amount, uint256 remainingBalance);
  event AllocatedStakedETH(uint256 currenAllocatedStakedETH, uint256 newAmount);
  event ValidatorRestaked(
    uint40 indexed validatorIndex,
    uint64 oracleTimestamp,
    uint256 effectiveBalanceGwei
  );
  event WithdrawalProcessed(
    uint40 indexed validatorIndex,
    uint256 amount,
    bytes32 withdrawalCredentials,
    uint64 oracleTimestamp
  );
}

/**
 * @title StakingNode
 * @dev Implements staking node functionality for the YieldNest protocol, enabling ETH staking, delegation, and rewards management.
 * Each StakingNode owns exactl one EigenPod which acts as a delegation unit, as it can be associated with exactly one operator.
 */
contract StakingNode is IStakingNode, StakingNodeEvents, ReentrancyGuardUpgradeable {
  using BeaconChainProofs for *;

  //--------------------------------------------------------------------------------------
  //----------------------------------  ERRORS  ------------------------------------------
  //--------------------------------------------------------------------------------------

  error NotStakingNodesAdmin();
  error ETHDepositorNotDelayedWithdrawalRouter();
  error ClaimAmountTooLow(uint256 expected, uint256 actual);
  error ZeroAddress();
  error NotStakingNodesManager();
  error NotStakingNodesDelegator();
  error NoBalanceToProcess();

  //--------------------------------------------------------------------------------------
  //----------------------------------  CONSTANTS  ---------------------------------------
  //--------------------------------------------------------------------------------------

  IStrategy public constant beaconChainETHStrategy =
    IStrategy(0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0);

  //--------------------------------------------------------------------------------------
  //----------------------------------  VARIABLES  ---------------------------------------
  //--------------------------------------------------------------------------------------

  IStakingNodesManager public stakingNodesManager;
  IEigenPod public eigenPod;
  uint256 public nodeId;

  /// @dev Monitors the ETH balance that was committed to validators allocated to this StakingNode
  uint256 public allocatedETH;

  /// @dev Allows only a whitelisted address to configure the contract
  modifier onlyAdmin() {
    if (!stakingNodesManager.isStakingNodesOperator(msg.sender)) revert NotStakingNodesAdmin();
    _;
  }

  modifier onlyDelegator() {
    if (!stakingNodesManager.isStakingNodesDelegator(msg.sender)) revert NotStakingNodesDelegator();
    _;
  }

  modifier onlyStakingNodesManager() {
    if (msg.sender != address(stakingNodesManager)) revert NotStakingNodesManager();
    _;
  }

  //--------------------------------------------------------------------------------------
  //----------------------------------  INITIALIZATION  ----------------------------------
  //--------------------------------------------------------------------------------------

  receive() external payable {
    // Consensus Layer rewards and the validator principal will be sent this way.
    if (msg.sender != address(stakingNodesManager.delayedWithdrawalRouter())) {
      revert ETHDepositorNotDelayedWithdrawalRouter();
    }
    emit ETHReceived(msg.sender, msg.value);
  }

  constructor() {
    _disableInitializers();
  }

  function initialize(
    Init memory init
  ) external notZeroAddress(address(init.stakingNodesManager)) initializer {
    __ReentrancyGuard_init();

    stakingNodesManager = init.stakingNodesManager;
    nodeId = init.nodeId;
  }

  //--------------------------------------------------------------------------------------
  //----------------------------------  EIGENPOD CREATION   ------------------------------
  //--------------------------------------------------------------------------------------

  /**
   * @notice Creates an EigenPod if it does not already exist for this StakingNode.
   * @dev If it does not exist, it proceeds to create a new EigenPod via EigenPodManager
   * @return The address of the EigenPod associated with this StakingNode.
   */
  function createEigenPod() public nonReentrant returns (IEigenPod) {
    if (address(eigenPod) != address(0)) return eigenPod; // already have pod

    IEigenPodManager eigenPodManager = IEigenPodManager(
      IStakingNodesManager(stakingNodesManager).eigenPodManager()
    );
    eigenPodManager.createPod();
    eigenPod = eigenPodManager.getPod(address(this));
    emit EigenPodCreated(address(this), address(eigenPod));

    return eigenPod;
  }

  //--------------------------------------------------------------------------------------
  //----------------------------------  EXPEDITED WITHDRAWAL   ---------------------------
  //--------------------------------------------------------------------------------------

  /**
   * @notice  Allows the StakingNode to withdraw ETH from the EigenPod before restaking.
   * @dev  This allows StakingNode to retrieve rewards from the Consensus Layer that accrue over time as
   *       validators sweep them to the withdrawal address
   */
  function withdrawNonBeaconChainETHBalanceWei() external onlyAdmin {
    // withdraw all available balance to withdraw.
    //Warning: the ETH balance of the EigenPod may be higher in case there's beacon chain ETH there
    uint256 balanceToWithdraw = eigenPod.nonBeaconChainETHBalanceWei();
    eigenPod.withdrawNonBeaconChainETHBalanceWei(address(this), balanceToWithdraw);
    emit WithdrawnNonBeaconChainETH(balanceToWithdraw, address(eigenPod).balance);
  }

  /**
   * @notice Processes withdrawals by verifying the node's balance and transferring ETH to the StakingNodesManager.
   * @dev This function checks if the node's current balance matches the expected balance and then transfers the ETH to the StakingNodesManager.
   */
  function processDelayedWithdrawals() public nonReentrant onlyAdmin {
    uint256 balance = address(this).balance;
    if (balance == 0) {
      revert NoBalanceToProcess();
    }
    stakingNodesManager.processRewards{value: balance}(nodeId, RewardsType.ConsensusLayer);
    emit NonBeaconChainETHWithdrawalsProcessed(balance);
  }

  //--------------------------------------------------------------------------------------
  //----------------------------------  VERIFICATION AND DELEGATION   --------------------
  //--------------------------------------------------------------------------------------

  /// @dev Validates the withdrawal credentials for a withdrawal
  /// This activates the activation of the staked funds within EigenLayer
  /// @param oracleTimestamp The timestamp of the oracle that signed the block
  /// @param stateRootProof The state root proof
  /// @param validatorIndices The indices of the validators
  /// @param validatorFieldsProofs The validator fields proofs
  /// @param validatorFields The validator fields
  function verifyWithdrawalCredentials(
    uint64 oracleTimestamp,
    BeaconChainProofs.StateRootProof calldata stateRootProof,
    uint40[] calldata validatorIndices,
    bytes[] calldata validatorFieldsProofs,
    bytes32[][] calldata validatorFields
  ) external onlyAdmin {
    IEigenPod(address(eigenPod)).verifyWithdrawalCredentials(
      oracleTimestamp,
      stateRootProof,
      validatorIndices,
      validatorFieldsProofs,
      validatorFields
    );

    for (uint256 i = 0; i < validatorIndices.length; i++) {
      uint256 effectiveBalanceGwei = validatorFields[i].getEffectiveBalanceGwei();
      emit ValidatorRestaked(validatorIndices[i], oracleTimestamp, effectiveBalanceGwei);
    }
  }

  //--------------------------------------------------------------------------------------
  //----------------------------------  DELEGATION   -------------------------------------
  //--------------------------------------------------------------------------------------

  function delegate(
    address operator,
    ISignatureUtils.SignatureWithExpiry memory approverSignatureAndExpiry,
    bytes32 approverSalt
  ) public override onlyDelegator {
    IDelegationManager delegationManager = IDelegationManager(
      address(stakingNodesManager.delegationManager())
    );
    delegationManager.delegateTo(operator, approverSignatureAndExpiry, approverSalt);

    emit Delegated(operator, approverSalt);
  }

  function undelegate() public onlyDelegator {
    IDelegationManager delegationManager = IDelegationManager(
      address(stakingNodesManager.delegationManager())
    );

    address operator = delegationManager.delegatedTo(address(this));
    emit Undelegated(operator);

    delegationManager.undelegate(address(this));
  }

  //--------------------------------------------------------------------------------------
  //----------------------------------  WITHDRAWALS  -------------------------------------
  //--------------------------------------------------------------------------------------

  function verifyAndProcessWithdrawals(
    uint64 oracleTimestamp,
    BeaconChainProofs.StateRootProof calldata stateRootProof,
    BeaconChainProofs.WithdrawalProof[] calldata withdrawalProofs,
    bytes[] calldata validatorFieldsProofs,
    bytes32[][] calldata validatorFields,
    bytes32[][] calldata withdrawalFields
  ) external onlyAdmin {
    eigenPod.verifyAndProcessWithdrawals(
      oracleTimestamp,
      stateRootProof,
      withdrawalProofs,
      validatorFieldsProofs,
      validatorFields,
      withdrawalFields
    );

    for (uint256 i = 0; i < withdrawalProofs.length; i++) {
      emit WithdrawalProcessed(
        validatorFields[i].getValidatorIndex(),
        validatorFields[i].getEffectiveBalanceGwei(), // Assuming the first field in withdrawalFields array is the amount
        validatorFields[i].getWithdrawalCredentials(),
        oracleTimestamp
      );
    }
  }

  //--------------------------------------------------------------------------------------
  //----------------------------------  ETH BALANCE ACCOUNTING  --------------------------
  //--------------------------------------------------------------------------------------

  /// @dev Record total staked ETH for this StakingNode
  function allocateStakedETH(uint256 amount) external payable onlyStakingNodesManager {
    emit AllocatedStakedETH(allocatedETH, amount);
    allocatedETH += amount;
  }

  function getETHBalance() public view returns (uint256) {
    // NOTE: when verifyWithdrawalCredentials is enabled
    // the eigenpod will be credited with shares. Those shares represent 1 share = 1 ETH
    // To get the shares call: strategyManager.stakerStrategyShares(address(this), beaconChainETHStrategy)
    // This computation will need to be updated to factor in that.
    return allocatedETH;
  }

  //--------------------------------------------------------------------------------------
  //----------------------------------  BEACON IMPLEMENTATION  ---------------------------
  //--------------------------------------------------------------------------------------

  /**
      Beacons slot value is defined here:
      https://github.com/OpenZeppelin/openzeppelin-contracts/blob/afb20119b33072da041c97ea717d3ce4417b5e01/contracts/proxy/ERC1967/ERC1967Upgrade.sol#L142
     */
  function implementation() public view returns (address) {
    bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1);
    address implementationVariable;
    assembly {
      implementationVariable := sload(slot)
    }

    IBeacon beacon = IBeacon(implementationVariable);
    return beacon.implementation();
  }

  /// @notice Retrieve the version number of the highest/newest initialize
  ///         function that was executed.
  function getInitializedVersion() external view returns (uint64) {
    return _getInitializedVersion();
  }

  //--------------------------------------------------------------------------------------
  //----------------------------------  MODIFIERS  ---------------------------------------
  //--------------------------------------------------------------------------------------

  /// @notice Ensure that the given address is not the zero address.
  /// @param _address The address to check.
  modifier notZeroAddress(address _address) {
    if (_address == address(0)) {
      revert ZeroAddress();
    }
    _;
  }
}
