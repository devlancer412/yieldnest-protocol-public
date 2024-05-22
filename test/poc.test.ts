import { deployments } from "hardhat";
import chai from "chai";
import { Ship } from "../utils";
import {
  RewardsDistributor,
  RewardsDistributor__factory,
  RewardsReceiver,
  RewardsReceiver__factory,
  StakingNodesManager,
  StakingNodesManager__factory,
  YnETH,
  YnETH__factory,
} from "../types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { formatEther, parseEther } from "ethers";

const { expect } = chai;

let ship: Ship;
let ynETH: YnETH;
let stakingNodesManager: StakingNodesManager;
let rewardsDistributor: RewardsDistributor;
let executionLayerReceiver: RewardsReceiver;
let consensusLayerReceiver: RewardsReceiver;

let owner: SignerWithAddress;
let alice: SignerWithAddress;
let bob: SignerWithAddress;
let lateComer: SignerWithAddress;

const setup = deployments.createFixture(async (hre) => {
  ship = await Ship.init(hre);
  const { accounts, users } = ship;

  return {
    ship,
    accounts,
    users,
  };
});

describe("POC", () => {
  before(async () => {
    const { accounts } = await setup();

    owner = accounts.deployer;
    alice = accounts.alice;
    bob = accounts.bob;
    lateComer = accounts.signer;

    ynETH = YnETH__factory.connect("0x09db87A538BD693E9d08544577d5cCfAA6373A48", owner);
    stakingNodesManager = StakingNodesManager__factory.connect(
      "0x8C33A1d6d062dB7b51f79702355771d44359cD7d",
      owner,
    );
    rewardsDistributor = RewardsDistributor__factory.connect(
      "0x40d5FF3E218f54f4982661a0464a298Cf6652351",
      owner,
    );
    executionLayerReceiver = RewardsReceiver__factory.connect(
      "0x1D6b2a11FFEa5F9a8Ed85A02581910b3d695C12b",
      owner,
    );
    consensusLayerReceiver = RewardsReceiver__factory.connect(
      "0xE439fe4563F7666FCd7405BEC24aE7B0d226536e",
      owner,
    );
  });

  it("poc", async () => {
    const shareAmount = await ynETH.previewDeposit(parseEther("1"));
    console.log(shareAmount);

    const totalAssets = await ynETH.totalAssets();
    const totalDepositedInPool = await ynETH.totalDepositedInPool();
    console.log(formatEther(totalAssets), formatEther(totalDepositedInPool));
  });
});
