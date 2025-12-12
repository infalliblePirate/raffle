const { expect } = require("chai");
const { ethers } = require("hardhat");
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';

describe("Raffle (VRF local mock tests)", function () {
    async function deployFixture() {
        const [owner, user1] = await ethers.getSigners();

        // mocked
        const BASE_FEE = ethers.parseEther("0.1");
        const GAS_PRICE_LINK = 1e9;

        const VRFMockFactory = await ethers.getContractFactory("VRFCoordinatorV2Mock");
        const vrf = await VRFMockFactory.deploy(BASE_FEE, GAS_PRICE_LINK);
        await vrf.waitForDeployment();

        const tx = await vrf.createSubscription();
        const receipt = await tx.wait();
        const subId = receipt.logs[0].args.subId;

        await vrf.fundSubscription(subId, ethers.parseEther("10"));

        const keyHash = "0x" + "00".repeat(32);
        const RaffleFactory = await ethers.getContractFactory("Raffle");
        const raffle = await RaffleFactory.deploy(await vrf.getAddress(), keyHash);
        await raffle.waitForDeployment();

        await vrf.addConsumer(subId, await raffle.getAddress());

        await raffle.setSubscription(subId);

        return { owner, user1, vrf, raffle, subId };
    }

    it("Ensures uniqueness of randomResults", async function () {
        const { raffle, vrf } = await loadFixture(deployFixture);

        const seenRandoms = new Set<string>();

        for (let i = 0; i < 3; i++) {
            await raffle.selectWinner();
            const reqId = await raffle.lastRequestId();

            await vrf.fulfillRandomWords(reqId, await raffle.getAddress());

            const random = await raffle.randomResult();

            expect(seenRandoms.has(random.toString())).to.be.false;
            seenRandoms.add(random.toString());
        }
    });

});
