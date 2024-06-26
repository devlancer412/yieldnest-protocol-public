// SPDX-License-Identifier: BSD 3-Clause License
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {depositRootGenerator} from "contracts/external/ethereum/DepositRootGenerator.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IDepositContract} from "contracts/external/ethereum/IDepositContract.sol";
import {IDelegationManager} from "contracts/external/eigenlayer-contracts/IDelegationManager.sol";
import {IDelayedWithdrawalRouter} from "contracts/external/eigenlayer-contracts/IDelayedWithdrawalRouter.sol";
import {IRewardsDistributor, IRewardsReceiver, RewardsType} from "contracts/interfaces/IRewardsDistributor.sol";
import {IEigenPodManager, IEigenPod} from "contracts/external/eigenlayer-contracts/IEigenPodManager.sol";
import {IStrategyManager} from "contracts/external/eigenlayer-contracts/IStrategyManager.sol";
import {IStakingNode} from "contracts/interfaces/IStakingNode.sol";
import {IStakingNodesManager} from "contracts/interfaces/IStakingNodesManager.sol";
import {IynETH} from "contracts/interfaces/IynETH.sol";

interface StakingNodesManagerEvents {
  event StakingNodeCreated(address indexed nodeAddress, address indexed podAddress);
  event ValidatorRegistered(
    uint256 nodeId,
    bytes signature,
    bytes pubKey,
    bytes32 depositRoot,
    bytes withdrawalCredentials
  );
  event MaxNodeCountUpdated(uint256 maxNodeCount);
  event ValidatorRegistrationPausedSet(bool isPaused);
  event WithdrawnETHRewardsProcessed(uint256 nodeId, RewardsType rewardsType, uint256 rewards);
  event RegisteredStakingNodeImplementationContract(
    address upgradeableBeaconAddress,
    address implementationContract
  );
  event UpgradedStakingNodeImplementationContract(
    address implementationContract,
    uint256 nodesCount
  );
  event NodeInitialized(address nodeAddress, uint64 initializedVersion);
}

contract StakingNodesManager is
  IStakingNodesManager,
  Initializable,
  AccessControlUpgradeable,
  ReentrancyGuardUpgradeable,
  StakingNodesManagerEvents
{
  //--------------------------------------------------------------------------------------
  //----------------------------------  ERRORS  ------------------------------------------
  //--------------------------------------------------------------------------------------

  error ValidatorAlreadyUsed(bytes publicKey);
  error DepositDataRootMismatch(bytes32 depositDataRoot, bytes32 expectedDepositDataRoot);
  error InvalidNodeId(uint256 nodeId);
  error ZeroAddress();
  error NotStakingNode(address caller, uint256 nodeId);
  error TooManyStakingNodes(uint256 maxNodeCount);
  error BeaconImplementationAlreadyExists();
  error NoBeaconImplementationExists();
  error DepositorNotYnETH();
  error TransferFailed();
  error NoValidatorsProvided();
  error ValidatorRegistrationPaused();
  error InvalidRewardsType(RewardsType rewardsType);

  //--------------------------------------------------------------------------------------
  //----------------------------------  ROLES  -------------------------------------------
  //--------------------------------------------------------------------------------------

  /// @notice  Role is allowed to set system parameters
  bytes32 public constant STAKING_ADMIN_ROLE = keccak256("STAKING_ADMIN_ROLE");

  /// @notice  Role controls all staking nodes
  bytes32 public constant STAKING_NODES_OPERATOR_ROLE = keccak256("STAKING_NODES_OPERATOR_ROLE");

  /// @notice Role is able to delegate staking operations
  bytes32 public constant STAKING_NODES_DELEGATOR_ROLE = keccak256("STAKING_NODES_DELEGATOR_ROLE");

  /// @notice  Role is able to register validators
  bytes32 public constant VALIDATOR_MANAGER_ROLE = keccak256("VALIDATOR_MANAGER_ROLE");

  /// @notice Role is able to create staking nodes
  bytes32 public constant STAKING_NODE_CREATOR_ROLE = keccak256("STAKING_NODE_CREATOR_ROLE");

  /// @notice  Role is allowed to set the pause state
  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

  /// @notice Role is able to unpause the system
  bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");

  //--------------------------------------------------------------------------------------
  //----------------------------------  CONSTANTS  ---------------------------------------
  //--------------------------------------------------------------------------------------

  uint256 constant DEFAULT_VALIDATOR_STAKE = 32 ether;

  //--------------------------------------------------------------------------------------
  //----------------------------------  VARIABLES  ---------------------------------------
  //--------------------------------------------------------------------------------------

  IEigenPodManager public eigenPodManager;
  IDepositContract public depositContractEth2;
  IDelegationManager public delegationManager;
  IDelayedWithdrawalRouter public delayedWithdrawalRouter;
  IStrategyManager public strategyManager;

  UpgradeableBeacon public upgradeableBeacon;

  IynETH public ynETH;
  IRewardsDistributor public rewardsDistributor;

  /**
    /**
     * @notice Each node in the StakingNodesManager manages an EigenPod.
     * An EigenPod represents a collection of validators and their associated staking activities within the EigenLayer protocol.
     * The StakingNode contract, which each node is an instance of, interacts with the EigenPod to perform various operations such as:
     * - Creating the EigenPod upon the node's initialization if it does not already exist.
     * - Delegating staking operations to the EigenPod, including processing rewards and managing withdrawals.
     * - Verifying withdrawal credentials and managing expedited withdrawals before restaking.
     *
     * This design allows for delegating to multiple operators simultaneously while also being gas efficient.
     * Grouping multuple validators per EigenPod allows delegation of all their stake with 1 delegationManager.delegateTo(operator) call.
     */
  IStakingNode[] public nodes;
  uint256 public maxNodeCount;

  Validator[] public validators;
  mapping(bytes pubkey => bool) usedValidators;

  bool public validatorRegistrationPaused;

  //--------------------------------------------------------------------------------------
  //----------------------------------  INITIALIZATION  ----------------------------------
  //--------------------------------------------------------------------------------------

  constructor() {
    _disableInitializers();
  }

  /// @notice Configuration for contract initialization.
  struct Init {
    // roles
    address admin;
    address stakingAdmin;
    address stakingNodesOperator;
    address stakingNodesDelegator;
    address validatorManager;
    address stakingNodeCreatorRole;
    address pauser;
    address unpauser;
    // internal
    uint256 maxNodeCount;
    IynETH ynETH;
    IRewardsDistributor rewardsDistributor;
    // external contracts
    IDepositContract depositContract;
    IEigenPodManager eigenPodManager;
    IDelegationManager delegationManager;
    IDelayedWithdrawalRouter delayedWithdrawalRouter;
    IStrategyManager strategyManager;
  }

  function initialize(
    Init calldata init
  )
    external
    notZeroAddress(address(init.ynETH))
    notZeroAddress(address(init.rewardsDistributor))
    initializer
  {
    __AccessControl_init();
    __ReentrancyGuard_init();

    initializeRoles(init);
    initializeExternalContracts(init);

    rewardsDistributor = init.rewardsDistributor;
    maxNodeCount = init.maxNodeCount;
    ynETH = init.ynETH;
  }

  function initializeRoles(
    Init calldata init
  )
    internal
    notZeroAddress(init.admin)
    notZeroAddress(init.stakingAdmin)
    notZeroAddress(init.stakingNodesOperator)
    notZeroAddress(init.validatorManager)
    notZeroAddress(init.stakingNodeCreatorRole)
    notZeroAddress(init.pauser)
    notZeroAddress(init.unpauser)
  {
    _grantRole(DEFAULT_ADMIN_ROLE, init.admin);
    _grantRole(STAKING_ADMIN_ROLE, init.stakingAdmin);
    _grantRole(STAKING_NODES_DELEGATOR_ROLE, init.stakingNodesDelegator);
    _grantRole(VALIDATOR_MANAGER_ROLE, init.validatorManager);
    _grantRole(STAKING_NODES_OPERATOR_ROLE, init.stakingNodesOperator);
    _grantRole(STAKING_NODE_CREATOR_ROLE, init.stakingNodeCreatorRole);
    _grantRole(PAUSER_ROLE, init.pauser);
    _grantRole(UNPAUSER_ROLE, init.unpauser);
  }

  function initializeExternalContracts(
    Init calldata init
  )
    internal
    notZeroAddress(address(init.depositContract))
    notZeroAddress(address(init.eigenPodManager))
    notZeroAddress(address(init.delegationManager))
    notZeroAddress(address(init.delayedWithdrawalRouter))
    notZeroAddress(address(init.strategyManager))
  {
    // Ethereum
    depositContractEth2 = init.depositContract;

    // Eigenlayer
    eigenPodManager = init.eigenPodManager;
    delegationManager = init.delegationManager;
    delayedWithdrawalRouter = init.delayedWithdrawalRouter;
    strategyManager = init.strategyManager;
  }

  receive() external payable {
    if (msg.sender != address(ynETH)) {
      revert DepositorNotYnETH();
    }
  }

  //--------------------------------------------------------------------------------------
  //----------------------------------  VALIDATOR REGISTRATION  --------------------------
  //--------------------------------------------------------------------------------------

  function registerValidators(
    ValidatorData[] calldata newValidators
  ) public onlyRole(VALIDATOR_MANAGER_ROLE) nonReentrant {
    if (validatorRegistrationPaused) {
      revert ValidatorRegistrationPaused();
    }

    if (newValidators.length == 0) {
      revert NoValidatorsProvided();
    }

    validateNodes(newValidators);

    uint256 totalDepositAmount = newValidators.length * DEFAULT_VALIDATOR_STAKE;
    ynETH.withdrawETH(totalDepositAmount); // Withdraw ETH from depositPool

    uint256 newValidatorCount = newValidators.length;
    for (uint256 i = 0; i < newValidatorCount; i++) {
      ValidatorData calldata validator = newValidators[i];
      if (usedValidators[validator.publicKey]) {
        revert ValidatorAlreadyUsed(validator.publicKey);
      }
      usedValidators[validator.publicKey] = true;

      _registerValidator(validator, DEFAULT_VALIDATOR_STAKE);
    }
  }

  /**
   * @notice Validates the correct number of nodes
   * @param newValidators An array of `ValidatorData` structures
   */
  function validateNodes(ValidatorData[] calldata newValidators) public view {
    uint256 nodeCount = nodes.length;

    for (uint256 i = 0; i < newValidators.length; i++) {
      uint256 nodeId = newValidators[i].nodeId;

      if (nodeId >= nodeCount) {
        revert InvalidNodeId(nodeId);
      }
    }
  }

  /// @notice Creates validator object and deposits into beacon chain
  /// @param validator Data structure to hold all data needed for depositing to the beacon chain
  function _registerValidator(ValidatorData calldata validator, uint256 _depositAmount) internal {
    uint256 nodeId = validator.nodeId;
    bytes memory withdrawalCredentials = getWithdrawalCredentials(nodeId);
    bytes32 depositDataRoot = depositRootGenerator.generateDepositRoot(
      validator.publicKey,
      validator.signature,
      withdrawalCredentials,
      _depositAmount
    );
    if (depositDataRoot != validator.depositDataRoot) {
      revert DepositDataRootMismatch(depositDataRoot, validator.depositDataRoot);
    }

    // Deposit to the Beacon Chain
    depositContractEth2.deposit{value: _depositAmount}(
      validator.publicKey,
      withdrawalCredentials,
      validator.signature,
      depositDataRoot
    );
    validators.push(Validator({publicKey: validator.publicKey, nodeId: validator.nodeId}));

    // notify node of ETH _depositAmount
    IStakingNode(nodes[nodeId]).allocateStakedETH(_depositAmount);

    emit ValidatorRegistered(
      nodeId,
      validator.signature,
      validator.publicKey,
      depositDataRoot,
      withdrawalCredentials
    );
  }

  function generateDepositRoot(
    bytes calldata publicKey,
    bytes calldata signature,
    bytes memory withdrawalCredentials,
    uint256 depositAmount
  ) public pure returns (bytes32) {
    return
      depositRootGenerator.generateDepositRoot(
        publicKey,
        signature,
        withdrawalCredentials,
        depositAmount
      );
  }

  function getWithdrawalCredentials(uint256 nodeId) public view returns (bytes memory) {
    address eigenPodAddress = address(IStakingNode(nodes[nodeId]).eigenPod());
    return generateWithdrawalCredentials(eigenPodAddress);
  }

  /// @notice Generates withdraw credentials for a validator
  /// @param _address associated with the validator for the withdraw credentials
  /// @return the generated withdraw key for the node
  function generateWithdrawalCredentials(address _address) public pure returns (bytes memory) {
    return abi.encodePacked(bytes1(0x01), bytes11(0x0), _address);
  }

  /// @notice Pauses validator registration.
  function pauseValidatorRegistration() external onlyRole(PAUSER_ROLE) {
    validatorRegistrationPaused = true;
    emit ValidatorRegistrationPausedSet(true);
  }

  /// @notice Unpauses validator registration.
  function unpauseValidatorRegistration() external onlyRole(UNPAUSER_ROLE) {
    validatorRegistrationPaused = false;
    emit ValidatorRegistrationPausedSet(false);
  }
  //--------------------------------------------------------------------------------------
  //----------------------------------  STAKING NODE CREATION  ---------------------------
  //--------------------------------------------------------------------------------------

  function createStakingNode()
    public
    notZeroAddress((address(upgradeableBeacon)))
    onlyRole(STAKING_NODE_CREATOR_ROLE)
    returns (IStakingNode)
  {
    uint256 nodeCount = nodes.length;

    if (nodeCount >= maxNodeCount) {
      revert TooManyStakingNodes(maxNodeCount);
    }

    BeaconProxy proxy = new BeaconProxy(address(upgradeableBeacon), "");
    IStakingNode node = IStakingNode(payable(proxy));

    initializeStakingNode(node, nodeCount);

    IEigenPod eigenPod = node.createEigenPod();

    nodes.push(node);

    emit StakingNodeCreated(address(node), address(eigenPod));

    return node;
  }

  function initializeStakingNode(IStakingNode node, uint256 nodeCount) internal virtual {
    uint64 initializedVersion = node.getInitializedVersion();
    if (initializedVersion == 0) {
      node.initialize(IStakingNode.Init(IStakingNodesManager(address(this)), nodeCount));

      // update to the newly upgraded version.
      initializedVersion = node.getInitializedVersion();
      emit NodeInitialized(address(node), initializedVersion);
    }
    // NOTE: for future versions add additional if clauses that initialize the node
    // for the next version while keeping the previous initializers
  }

  function registerStakingNodeImplementationContract(
    address _implementationContract
  ) public onlyRole(STAKING_ADMIN_ROLE) notZeroAddress(_implementationContract) {
    if (address(upgradeableBeacon) != address(0)) {
      revert BeaconImplementationAlreadyExists();
    }

    upgradeableBeacon = new UpgradeableBeacon(_implementationContract, address(this));

    emit RegisteredStakingNodeImplementationContract(
      address(upgradeableBeacon),
      _implementationContract
    );
  }

  function upgradeStakingNodeImplementation(
    address _implementationContract
  ) public onlyRole(STAKING_ADMIN_ROLE) notZeroAddress(_implementationContract) {
    if (address(upgradeableBeacon) == address(0)) {
      revert NoBeaconImplementationExists();
    }
    upgradeableBeacon.upgradeTo(_implementationContract);

    uint256 nodeCount = nodes.length;

    // reinitialize all nodes
    for (uint256 i = 0; i < nodeCount; i++) {
      initializeStakingNode(nodes[i], nodeCount);
    }

    emit UpgradedStakingNodeImplementationContract(_implementationContract, nodeCount);
  }

  /// @notice Sets the maximum number of staking nodes allowed
  /// @param _maxNodeCount The maximum number of staking nodes
  function setMaxNodeCount(uint256 _maxNodeCount) public onlyRole(STAKING_ADMIN_ROLE) {
    maxNodeCount = _maxNodeCount;
    emit MaxNodeCountUpdated(_maxNodeCount);
  }

  //--------------------------------------------------------------------------------------
  //----------------------------------  WITHDRAWALS  -------------------------------------
  //--------------------------------------------------------------------------------------

  function processRewards(uint256 nodeId, RewardsType rewardsType) external payable {
    if (address(nodes[nodeId]) != msg.sender) {
      revert NotStakingNode(msg.sender, nodeId);
    }

    uint256 rewards = msg.value;
    IRewardsReceiver receiver;

    if (rewardsType == RewardsType.ConsensusLayer) {
      receiver = rewardsDistributor.consensusLayerReceiver();
    } else if (rewardsType == RewardsType.ExecutionLayer) {
      receiver = rewardsDistributor.executionLayerReceiver();
    } else {
      revert InvalidRewardsType(rewardsType);
    }

    (bool sent, ) = address(receiver).call{value: rewards}("");
    if (!sent) {
      revert TransferFailed();
    }

    emit WithdrawnETHRewardsProcessed(nodeId, rewardsType, msg.value);
  }

  //--------------------------------------------------------------------------------------
  //----------------------------------  VIEWS  -------------------------------------------
  //--------------------------------------------------------------------------------------

  function getAllValidators() public view returns (Validator[] memory) {
    return validators;
  }

  function getAllNodes() public view returns (IStakingNode[] memory) {
    return nodes;
  }

  function nodesLength() public view returns (uint256) {
    return nodes.length;
  }

  function isStakingNodesOperator(address _address) public view returns (bool) {
    return hasRole(STAKING_NODES_OPERATOR_ROLE, _address);
  }

  function isStakingNodesDelegator(address _address) public view returns (bool) {
    return hasRole(STAKING_NODES_DELEGATOR_ROLE, _address);
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
