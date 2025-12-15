import { time } from '@nomicfoundation/hardhat-network-helpers';
import { expect } from "chai";
import { ethers } from "hardhat";
import {
    Raffle,
    MockERC20,
    MockV3Aggregator,
    MockWETH,
    MockSwapRouter,
    VRFCoordinatorV2Mock
} from "../../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("Raffle", function () {
    let raffle: Raffle;
    let vrfCoordinator: VRFCoordinatorV2Mock;
    let token1: MockERC20;
    let token2: MockERC20;
    let priceFeed1: MockV3Aggregator;
    let priceFeed2: MockV3Aggregator;
    let weth: MockWETH;
    let swapRouter: MockSwapRouter;

    let owner: HardhatEthersSigner;
    let user1: HardhatEthersSigner;
    let user2: HardhatEthersSigner;
    let user3: HardhatEthersSigner;

    const keyHash = "0x" + "00".repeat(32);
    let subscriptionId: bigint;

    function assertAddress(label: string, addr: any) {
        // console.log(`${label}:`, addr);
        if (!addr || addr === ethers.ZeroAddress) {
            throw new Error(`${label} is invalid`);
        }
    }

    async function deposit(
        user: HardhatEthersSigner,
        token: MockERC20,
        amount: string
    ) {
        await token.connect(user).approve(raffle, ethers.parseEther(amount));
        return await raffle.connect(user).deposit(
            token.target,
            ethers.parseEther(amount),
            0, 0, ethers.ZeroHash, ethers.ZeroHash
        );
    }

    async function fulfillRandomWords(requestId: number, randomness: number) {
        await vrfCoordinator.fulfillRandomWords(requestId, raffle);
    }

    async function findWinnerIndex(gameId: number): Promise<number> {
        const randomResult = await raffle.randomResult(gameId);
        const poolUSD = await raffle.poolUSD(gameId);
        const winningPoint = randomResult % poolUSD;

        const rangesArray = await raffle.getWinningRanges(gameId);

        for (let i = 0; i < rangesArray.length; i++) {
            const range = rangesArray[i];
            if (winningPoint >= range.min && winningPoint < range.max) {
                return i;
            }
        }
        throw new Error("Winner not found");
    }

    beforeEach(async function () {

        [owner, user1, user2, user3] = await ethers.getSigners();

        const VRFCoordinatorFactory = await ethers.getContractFactory("VRFCoordinatorV2Mock");
        vrfCoordinator = await VRFCoordinatorFactory.deploy(
            ethers.parseEther("0.1"),
            ethers.parseEther("0.000001")
        );
        await vrfCoordinator.waitForDeployment();
        assertAddress("VRFCoordinator", vrfCoordinator.target);

        const tx = await vrfCoordinator.createSubscription();
        const receipt = await tx.wait();
        subscriptionId = vrfCoordinator.interface.parseLog(receipt!.logs[0])!.args!.subId;

        const WETHFactory = await ethers.getContractFactory("MockWETH");
        weth = await WETHFactory.deploy();
        await weth.waitForDeployment();
        assertAddress("WETH", weth.target);

        await owner.sendTransaction({
            to: weth.target,
            value: ethers.parseEther("100")
        });

        const SwapRouterFactory = await ethers.getContractFactory("MockSwapRouter");
        swapRouter = await SwapRouterFactory.deploy(weth.target);
        await swapRouter.waitForDeployment();
        assertAddress("SwapRouter", swapRouter.target);

        const RaffleFactory = await ethers.getContractFactory("Raffle");
        raffle = await RaffleFactory.deploy(
            vrfCoordinator.target,
            keyHash,
            swapRouter.target
        );
        await raffle.waitForDeployment();
        assertAddress("Raffle", raffle.target);

        await raffle.setWETH(weth.target);

        await vrfCoordinator.addConsumer(subscriptionId, raffle.target);
        await vrfCoordinator.fundSubscription(subscriptionId, ethers.parseEther("1000"));
        await raffle.setSubscription(subscriptionId);

        await raffle.setAutomationConfig(1n, 60*3*60, 10000n);

        const ERC20Factory = await ethers.getContractFactory("MockERC20");

        token1 = await ERC20Factory.deploy();
        await token1.waitForDeployment();
        assertAddress("Token1", token1.target);

        token2 = await ERC20Factory.deploy();
        await token2.waitForDeployment();
        assertAddress("Token2", token2.target);

        const AggregatorFactory = await ethers.getContractFactory("MockV3Aggregator");

        priceFeed1 = await AggregatorFactory.deploy(8, ethers.parseUnits("1000", 8));
        await priceFeed1.waitForDeployment();
        assertAddress("PriceFeed1", priceFeed1.target);

        priceFeed2 = await AggregatorFactory.deploy(8, ethers.parseUnits("2000", 8));
        await priceFeed2.waitForDeployment();
        assertAddress("PriceFeed2", priceFeed2.target);

        await raffle.addTokenFeed(token1.target, priceFeed1.target);

        await raffle.addTokenFeed(token2.target, priceFeed2.target);

        const mintAmount = ethers.parseEther("1000");

        await token1.mint(user1, mintAmount);
        await token1.mint(user2, mintAmount);
        await token1.mint(user3, mintAmount);

        await token2.mint(user1, mintAmount);
        await token2.mint(user2, mintAmount);
        await token2.mint(user3, mintAmount);
    });

    describe("Initial State", function () {
        it("Should initialize with correct state", async function () {
            expect(await raffle.gameId()).to.equal(0n);
            expect(await raffle.gameState(0)).to.equal(0);
            expect(await raffle.poolUSD(0)).to.equal(0n);
        });

        it("Should have correct owner", async function () {
            expect(await raffle.owner()).to.equal(owner.address);
        });
    });

    describe("Deposits", function () {
        it("Should accept single deposit", async function () {
            const amount = "0.1";

            await expect(deposit(user1, token1, amount))
                .to.emit(raffle, "Deposit")
                .withArgs(
                    user1,
                    token1,
                    ethers.parseEther(amount),
                    ethers.parseEther("100")
                );

            expect(await raffle.poolUSD(0)).to.equal(ethers.parseEther("100"));
            expect(await raffle.tokenBalances(0, token1)).to.equal(ethers.parseEther(amount));
        });

        it("Should accept multiple deposits from different users", async function () {
            await deposit(user1, token1, "0.1"); // 100
            await deposit(user2, token1, "0.2"); // 200
            await deposit(user3, token2, "0.05"); // 50

            expect(await raffle.poolUSD(0)).to.equal(ethers.parseEther("400"));

            const users = await raffle.getUsers(0);
            expect(users.length).to.equal(3);
        });

        it("Should allow same user to deposit multiple times", async function () {
            await deposit(user1, token1, "0.1"); // 100
            await deposit(user1, token1, "0.1"); // 100

            expect(await raffle.poolUSD(0)).to.equal(ethers.parseEther("200"));

            const users = await raffle.getUsers(0);
            expect(users.length).to.equal(1);

            const ranges = await raffle.getWinningRanges(0);
            expect(ranges.length).to.equal(2);
        });

        it("Should revert on zero amount", async function () {
            await token1.connect(user1).approve(raffle, ethers.parseEther("1"));

            await expect(
                raffle.connect(user1).deposit(token1, 0, 0, 0, ethers.ZeroHash, ethers.ZeroHash)
            ).to.be.revertedWithCustomError(raffle, "ZeroAmount");
        });

        it("Should revert on unsupported token", async function () {
            const UnsupportedToken = await ethers.getContractFactory("MockERC20");
            const unsupported = await UnsupportedToken.deploy();

            await unsupported.mint(user1.address, ethers.parseEther("100"));
            await unsupported.connect(user1).approve(raffle, ethers.parseEther("1"));

            await expect(
                raffle.connect(user1).deposit(unsupported, ethers.parseEther("0.1"), 0, 0, ethers.ZeroHash, ethers.ZeroHash)
            ).to.be.revertedWithCustomError(raffle, "NotSupportedToken");
        });

        it("Should revert deposits after random requested", async function () {
            await deposit(user1, token1, "0.1");
            await raffle.requestRandom();

            await expect(
                deposit(user2, token1, "0.1")
            ).to.be.revertedWithCustomError(raffle, "NoActiveRound");
        });
    });


    describe("Complete Game Flow", function () {
        it("Should complete full game cycle", async function () {
            await deposit(user1, token1, "0.1"); // 100
            await deposit(user2, token1, "0.2"); // 200

            expect(await raffle.gameState(0)).to.equal(0); // aactive

            await expect(raffle.requestRandom())
                .to.emit(raffle, "GameStateChanged")
                .withArgs(0, 0, 1);

            expect(await raffle.gameState(0)).to.equal(1); // randomRequested

            const requestId = await raffle.lastRequestId();
            await fulfillRandomWords(Number(requestId), 12345);

            expect(await raffle.randomResult(0)).to.not.equal(0);

            const winnerIndex = await findWinnerIndex(0);

            await expect(raffle.endGame(winnerIndex))
                .to.emit(raffle, "GameEnded");

            expect(await raffle.gameState(0)).to.equal(2); // ended
            expect(await raffle.gameId()).to.equal(1);
            expect(await raffle.gameState(1)).to.equal(0); // active
        });

        it("Should run multiple games sequentially", async function () {
            await deposit(user1, token1, "0.1");
            await raffle.requestRandom();
            await fulfillRandomWords((Number(await raffle.lastRequestId())), 111);
            await raffle.endGame(await findWinnerIndex(0));

            expect(await raffle.gameId()).to.equal(1);

            await deposit(user2, token1, "0.1");
            await raffle.requestRandom();
            await fulfillRandomWords((Number(await raffle.lastRequestId())), 222);
            await raffle.endGame(await findWinnerIndex(1));

            expect(await raffle.gameId()).to.equal(2);

            expect(await raffle.gameState(0)).to.equal(2);
            expect(await raffle.gameState(1)).to.equal(2);
        });

        it("Should revert end game without random", async function () {
            await deposit(user1, token1, "0.1");
            await raffle.requestRandom();

            await expect(raffle.endGame(0)).to.be.revertedWith("incorrect conditions");
        });

        it("Should revert end game with wrong index", async function () {
            await deposit(user1, token1, "0.1"); // [0, 100)
            await deposit(user2, token1, "0.3"); // [100, 400)

            await raffle.requestRandom();
            await fulfillRandomWords((Number(await raffle.lastRequestId())), 12345);

            const correctIndex = await findWinnerIndex(0);
            const wrongIndex = correctIndex === 0 ? 1 : 0;

            await expect(raffle.endGame(wrongIndex)).to.be.revertedWith("incorrect winner idx");
        });
    });


    describe("VRF race condition protection (won't happen but just in case)", function () {

        it("Should track multiple requests correctly", async function () {
            await deposit(user1, token1, "0.1");
            await raffle.requestRandom();
            const requestId0 = await raffle.lastRequestId();
            await fulfillRandomWords(Number(requestId0), 111);
            await raffle.endGame(await findWinnerIndex(0));

            await deposit(user2, token1, "0.1");
            await raffle.requestRandom();
            const requestId1 = await raffle.lastRequestId();

            expect(requestId1).to.not.equal(requestId0);
            expect(await raffle.gameIdForRequest(requestId0)).to.equal(0);
            expect(await raffle.gameIdForRequest(requestId1)).to.equal(1);
        });
    });

    describe("Chainlink keeper", function () {
        beforeEach(async function () {
            await raffle.setAutomationEnabled(true);
        });

        it("Should return false when automation disabled", async function () {
            await raffle.setAutomationEnabled(false);
            const [upkeepNeeded] = await raffle.checkUpkeep("0x");
            expect(upkeepNeeded).to.be.false;
        });

        it("Should return false when no conditions met", async function () {
            const [upkeepNeeded] = await raffle.checkUpkeep("0x");
            expect(upkeepNeeded).to.be.false;
        });

        describe("Trigger conditions", function () {
            it("Should trigger on user threshold", async function () {
                await raffle.setAutomationConfig(2, 24 * 3600, ethers.parseEther("10000"));

                await deposit(user1, token1, "0.1");
                await deposit(user2, token1, "0.1");

                const [upkeepNeeded, performData] = await raffle.checkUpkeep("0x");

                expect(upkeepNeeded).to.be.true;
                const [action] = ethers.AbiCoder.defaultAbiCoder().decode(
                    ["uint8", "uint256", "string"],
                    performData
                );
                expect(action).to.equal(1);
            });

            it("Should trigger on time threshold", async function () {
                await deposit(user1, token1, "0.1");

                await time.increase(25 * 3600);

                const [upkeepNeeded, performData] = await raffle.checkUpkeep("0x");

                expect(upkeepNeeded).to.be.true;
                const [action] = ethers.AbiCoder.defaultAbiCoder().decode(
                    ["uint8", "uint256", "string"],
                    performData
                );
                expect(action).to.equal(1);
            });

            it("Should trigger on pool threshold", async function () {
                await raffle.setAutomationConfig(100, 24 * 3600, ethers.parseEther("100"));

                await deposit(user1, token1, "0.2");

                const [upkeepNeeded] = await raffle.checkUpkeep("0x");
                expect(upkeepNeeded).to.be.true;
            });
        });

        describe("upkeep: request random", function () {
            it("Should request random via automation", async function () {
                await raffle.setAutomationConfig(2, 24 * 3600, ethers.parseEther("10000"));

                await deposit(user1, token1, "0.1");
                await deposit(user2, token1, "0.1");

                const [, performData] = await raffle.checkUpkeep("0x");

                await expect(raffle.performUpkeep(performData))
                    .to.emit(raffle, "AutomationTriggered")
                    .withArgs(1, "valid_end_game_conditions", 0);

                expect(await raffle.gameState(0)).to.equal(1);
            });

            it("Should not request random twice", async function () {
                await raffle.setAutomationConfig(2, 24 * 3600, ethers.parseEther("10000"));

                await deposit(user1, token1, "0.1");
                await deposit(user2, token1, "0.1");

                const [, performData] = await raffle.checkUpkeep("0x");
                await raffle.performUpkeep(performData);

                await expect(raffle.performUpkeep(performData)).to.be.rejectedWith("Game not active");
            });
        });

        describe("upkeep: end game", function () {
            it("Should end game via automation with correct index", async function () {
                await raffle.setAutomationConfig(2, 24 * 3600, ethers.parseEther("10000"));

                await deposit(user1, token1, "0.1");
                await deposit(user2, token1, "0.2");

                const [, performData1] = await raffle.checkUpkeep("0x");
                await raffle.performUpkeep(performData1);

                await fulfillRandomWords((Number(await raffle.lastRequestId())), 12345);

                const winnerIndex = await findWinnerIndex(0);
                const checkData = ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [winnerIndex]);

                const [upkeepNeeded, performData2] = await raffle.checkUpkeep(checkData);

                expect(upkeepNeeded).to.be.true;

                await expect(raffle.performUpkeep(performData2))
                    .to.emit(raffle, "GameEnded");

                expect(await raffle.gameState(0)).to.equal(2);
                expect(await raffle.gameId()).to.equal(1);
            });

        });
    });
});
