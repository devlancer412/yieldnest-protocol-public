import { deployments } from "hardhat";
import chai from "chai";
import { Ship, advanceTimeAndBlock } from "../utils";
import { InvestingVault, InvestingVault__factory, MockUSDT, MockUSDT__factory } from "../types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { parseEther } from "ethers";

const { expect } = chai;

let ship: Ship;
let usdt: MockUSDT;
let vault: InvestingVault;

let owner: SignerWithAddress;
let alice: SignerWithAddress;
let bob: SignerWithAddress;
let lateComer: SignerWithAddress;

const setup = deployments.createFixture(async (hre) => {
  ship = await Ship.init(hre);
  const { accounts, users } = ship;
  await deployments.fixture(["vault"]);

  return {
    ship,
    accounts,
    users,
  };
});

describe("InvestingVault test", () => {
  describe("functionality", () => {
    before(async () => {
      const { accounts } = await setup();

      owner = accounts.deployer;
      alice = accounts.alice;
      bob = accounts.bob;
      lateComer = accounts.signer;

      vault = (await ship.connect(InvestingVault__factory)) as InvestingVault;
      usdt = (await ship.connect(MockUSDT__factory)) as MockUSDT;

      await usdt.connect(alice).mint(parseEther("1000000"));
      await usdt.connect(alice).approve(vault.target, parseEther("1000000"));
      await usdt.connect(bob).mint(parseEther("1000000"));
      await usdt.connect(bob).approve(vault.target, parseEther("1000000"));
      await usdt.connect(lateComer).mint(parseEther("1000000"));
      await usdt.connect(lateComer).approve(vault.target, parseEther("1000000"));
    });

    it("deposit on lock period", async () => {
      await expect(vault.connect(alice).deposit(parseEther("50"))).to.revertedWithCustomError(
        vault,
        "TooSmallAmount",
      );

      await expect(vault.connect(alice).deposit(parseEther("100")))
        .to.emit(vault, "InvestUpdated")
        .withArgs(alice.address, parseEther("100"));

      await expect(vault.connect(bob).deposit(parseEther("100000")))
        .to.emit(vault, "InvestUpdated")
        .withArgs(bob.address, parseEther("100000"));
    });

    it("withdraw", async () => {
      await expect(vault.connect(owner).withdraw(parseEther("50"))).to.revertedWithCustomError(
        vault,
        "NotAvailable",
      );
      await expect(vault.connect(alice).withdraw(parseEther("50"))).to.revertedWithCustomError(
        vault,
        "NotAvailable",
      );

      await advanceTimeAndBlock(183 * 24 * 60 * 60);

      await expect(vault.connect(alice).withdraw(parseEther("50")))
        .to.emit(vault, "InvestUpdated")
        .withArgs(alice.address, parseEther("50"));

      await expect(vault.connect(alice).withdraw(parseEther("100"))).to.revertedWithCustomError(
        vault,
        "NotAvailable",
      );
    });

    it("deposit after lock period", async () => {
      await advanceTimeAndBlock(24 * 60 * 60);

      await expect(vault.connect(lateComer).deposit(parseEther("1000"))).to.revertedWithCustomError(
        vault,
        "NotAvailable",
      );

      await expect(vault.connect(alice).deposit(parseEther("100")))
        .to.emit(vault, "InvestUpdated")
        .withArgs(alice.address, parseEther("150"));

      await expect(vault.connect(bob).deposit(parseEther("100")))
        .to.emit(vault, "InvestUpdated")
        .withArgs(bob.address, parseEther("100100"));
    });

    it("claim rewards", async () => {
      const pastReward = await vault.reward(alice.address);
      const pendingReward = await vault.getPendingReward(alice.address);
      const expectedReward = pastReward + pendingReward;

      // await expect(vault.connect(alice).claimReward()).to.changeTokenBalances(
      //   usdt,
      //   [alice.address, vault.target],
      //   [expectedReward, -1n * expectedReward],
      // );
      await vault.connect(alice).claimReward();
    });
  });

  describe("ownership test", () => {
    before(async () => {
      const { accounts } = await setup();

      owner = accounts.deployer;
      alice = accounts.alice;
      bob = accounts.bob;
      lateComer = accounts.signer;

      vault = (await ship.connect(InvestingVault__factory)) as InvestingVault;
      usdt = (await ship.connect(MockUSDT__factory)) as MockUSDT;

      await usdt.connect(alice).mint(parseEther("1000000"));
      await usdt.connect(alice).transfer(vault.target, parseEther("1000000"));
      await usdt.connect(owner).mint(parseEther("1000000"));
      await usdt.connect(owner).approve(vault.target, parseEther("1000000"));
    });

    it("invest", async () => {
      await expect(vault.connect(alice).invest(bob.address, parseEther("100")))
        .to.revertedWithCustomError(vault, "OwnableUnauthorizedAccount")
        .withArgs(alice.address);

      await expect(vault.connect(owner).invest(bob.address, parseEther("100"))).to.changeTokenBalances(
        usdt,
        [vault.target, bob.address],
        [-1n * parseEther("100"), parseEther("100")],
      );
    });

    it("return invest", async () => {
      await expect(vault.connect(alice).investReturn(parseEther("100")))
        .to.revertedWithCustomError(vault, "OwnableUnauthorizedAccount")
        .withArgs(alice.address);

      await expect(vault.connect(owner).investReturn(parseEther("100"))).to.changeTokenBalances(
        usdt,
        [vault.target, owner.address],
        [parseEther("100"), -1n * parseEther("100")],
      );
    });
  });
});
