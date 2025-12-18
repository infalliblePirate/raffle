import { ethers } from "hardhat";
import { Raffle } from "../typechain-types";
import feeds from "./feeds.sepolia.json";

async function main() {
    const [user1, user2] = await ethers.getSigners();
    const raffleAddress = "0x2e4fe74e1636040e583b6e86Eb084C1b4a8aFC2A";
    const linkAddress = "0x779877a7b0d9e8603169ddbd7836e478b4624789";

    const raffle = (await ethers.getContractAt("Raffle", raffleAddress)) as Raffle;
    const link = await ethers.getContractAt("ERC20", linkAddress);

    const tx = await raffle.startGame();
    await tx.wait();

    const isEnabled = await raffle.automationEnabled();
    if (!isEnabled) {
        console.log("enabling automation");
        const tx = await raffle.setAutomationEnabled(true);
        await tx.wait();
    }

    const firstFeed = Object.values(feeds)[0];
    try {
        await raffle.getTokenValueInUSD(firstFeed.address, 1n);
        console.log("feeds already configured");
    } catch {
        for (const token of Object.values(feeds)) {
            const tx = await raffle.addTokenFeed(token.address, token.feed);
            await tx.wait();
        }
        console.log("added feeds");
    }

    const activeGameId = await raffle.gameId();
    console.log(`gameId: ${activeGameId}`);

    const depositAmount = ethers.parseEther("0.0001");

    const tx1 = await link.connect(user1).approve(raffle.target, depositAmount);
    await tx1.wait();

    const tx2 = await link.connect(user2).approve(raffle.target, depositAmount);
    await tx2.wait();
    console.log("approved deposit");

    const d1 = await raffle.connect(user1).deposit(
        link.target, depositAmount, 0, 0, ethers.ZeroHash, ethers.ZeroHash
    );
    await d1.wait();
    console.log("user1 deposited");

    const d2 = await raffle.connect(user2).deposit(
        link.target, depositAmount, 0, 0, ethers.ZeroHash, ethers.ZeroHash
    );
    await d2.wait();
    console.log("user2 deposited");

    const [upkeepNeeded] = await raffle.checkUpkeep.staticCallResult("0x");
    console.log(`are upkeep requirements satisfied? ${upkeepNeeded}`);

    const startTime = Date.now();
    const timeout = 600_000; // 10 min (for keeper + vrf + keeper)

    let randomValue = await raffle.randomResult(activeGameId);
    let winnerAddress = await raffle.winner(activeGameId);

    console.log("wait for vrf fulfill random");
    while (randomValue === 0n) {
        if (Date.now() - startTime > timeout) {
            console.log("vrf timeout");
            process.exit(1);
        }
        await new Promise(resolve => setTimeout(resolve, 5000));
        randomValue = await raffle.randomResult(activeGameId);
    }
    console.log(`vrf fulfilled,andom: ${randomValue}`);

    console.log("wat for keeper to end game");
    while (winnerAddress === ethers.ZeroAddress) {
        if (Date.now() - startTime > timeout) {
            console.log("game end timeout");
            process.exit(1);
        }
        await new Promise(resolve => setTimeout(resolve, 5000));
        winnerAddress = await raffle.winner(activeGameId);
    }
    console.log(`\ngame ended winner: ${winnerAddress}`);

    const newGameId = await raffle.gameId();
    if (newGameId > activeGameId) {
        console.log(`new game ${newGameId} started automatically`);
    }
}

main().catch(console.error);