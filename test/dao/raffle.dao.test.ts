
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
    RaffleGovernor,
    RaffleGovToken,
    RaffleTimelock,
    RaffleDao
} from "../../typechain-types";


// actor                  what can do
// token holder           delegate votes
// delegate               vote and propose
// governor               manges proposals
// timelock               executes changes (security layer, allows users to react, exit, prevents instant changes)
// raffle                 listens to governance


// https://github.com/OpenZeppelin/openzeppelin-contracts/tree/0e8e34ae536d939c8939c97c055022b8f6d9a598/test/governance
// https://deepwiki.com/OpenZeppelin/openzeppelin-contracts/4.1-governor
describe("Raffle DAO Governance", function () {
    let govToken: RaffleGovToken;
    let timelock: RaffleTimelock;
    let governor: RaffleGovernor;
    let raffle: RaffleDao;
    let deployer: SignerWithAddress;
    let alice: SignerWithAddress;
    let bob: SignerWithAddress;
    let carol: SignerWithAddress;
    let platform: SignerWithAddress;
    let founder: SignerWithAddress;
    let proposalId: bigint;

    // mocks
    const MOCK_VRF_COORDINATOR = "0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B";
    const MOCK_SWAP_ROUTER = "0x3344BBDCeb8f6fb52de759c127E4A44EFb40432A";
    const MOCK_WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";

    async function mineBlocks(n: number): Promise<void> {
        for (let i = 0; i < n; i++) {
            await ethers.provider.send("evm_mine", []);
        }
    }

    async function advanceTime(seconds: number): Promise<void> {
        await ethers.provider.send("evm_increaseTime", [seconds]);
        await ethers.provider.send("evm_mine", []);
    }

    beforeEach(async function () { // todo: move to fixture
        [deployer, alice, bob, carol, platform, founder] = await ethers.getSigners();

        const GovToken = await ethers.getContractFactory("RaffleGovToken");
        govToken = await GovToken.deploy(ethers.parseEther("1000000"));
        await govToken.waitForDeployment();

        const Timelock = await ethers.getContractFactory("RaffleTimelock");
        timelock = await Timelock.deploy(
            2 * 24 * 60 * 60, // 2 days
            [], // proposers (will add Governor)
            [], // executors (anyone)
            deployer.address // admin
        );
        await timelock.waitForDeployment();

        const Governor = await ethers.getContractFactory("RaffleGovernor");
        governor = await Governor.deploy(
            await govToken.getAddress(),
            await timelock.getAddress(),
            1, // votingDelay: 1 block 
            10, // votingPeriod: 10 blocks
            ethers.parseEther("1000"),
            4 // quorum
        );
        await governor.waitForDeployment();

        const Raffle = await ethers.getContractFactory("RaffleDao");
        raffle = await Raffle.deploy(
            deployer.address,
            await timelock.getAddress(), 
            platform,
            founder,
            MOCK_SWAP_ROUTER,
            MOCK_WETH,
            MOCK_VRF_COORDINATOR,
            12345
        );
        await raffle.waitForDeployment();

        const PROPOSER_ROLE = await timelock.PROPOSER_ROLE(); // who can scedule on timelock
        const EXECUTOR_ROLE = await timelock.EXECUTOR_ROLE();
        const ADMIN_ROLE = await timelock.DEFAULT_ADMIN_ROLE();

        await timelock.grantRole(PROPOSER_ROLE, await governor.getAddress());
        await timelock.grantRole(EXECUTOR_ROLE, ethers.ZeroAddress);
        await timelock.revokeRole(ADMIN_ROLE, deployer.address);

        // token holders -> vote -> Governor -> Timelock.schedule()
        await govToken.transfer(alice.address, ethers.parseEther("100000"));
        await govToken.transfer(bob.address, ethers.parseEther("100000")); 
        await govToken.transfer(carol.address, ethers.parseEther("50000"));

        await govToken.connect(alice).delegate(alice.address);
        await govToken.connect(bob).delegate(bob.address);
        await govToken.connect(carol).delegate(carol.address);
    });

    describe("setup validation", function () {
        it("should have correct initial fee percentages (100% to winner)", async function () {
            expect(await raffle.platformFeePercent()).to.equal(0);
            expect(await raffle.founderFeePercent()).to.equal(0);
            expect(await raffle.winnerFeePercent()).to.equal(100);
        });

        it("should have correct voting power after delegation", async function () {
            expect(await govToken.getVotes(alice.address)).to.equal(
                ethers.parseEther("100000")
            );
            expect(await govToken.getVotes(bob.address)).to.equal(
                ethers.parseEther("100000")
            );
            expect(await govToken.getVotes(carol.address)).to.equal(
                ethers.parseEther("50000")
            );
        });

        it("should prevent non-governance from changing parameters", async function () {
            await expect(
                raffle.connect(alice).setFeePercentages(5, 5, 90)
            ).to.be.revertedWithCustomError(raffle, "NotGovernance");
        });

        it("should prevent non-governance from transferring governance", async function () {
            await expect(
                raffle.connect(alice).transferGovernance(alice.address)
            ).to.be.revertedWithCustomError(raffle, "NotGovernance");
        });
    });

    describe("proposals", function () {
        it("should allow creating proposal with sufficient tokens", async function () {
            const targets = [await raffle.getAddress()];
            const values = [0n];
            const calldatas = [
                raffle.interface.encodeFunctionData("setFeePercentages", [5, 5, 90])
            ];
            const description = "Implement 5-5-90 fee split";

            const tx = await governor.connect(alice).propose(
                targets,
                values,
                calldatas,
                description
            );

            const receipt = await tx.wait();
            const event = receipt?.logs.find((log: any) => {
                try {
                    return governor.interface.parseLog(log)?.name === "ProposalCreated";
                } catch {
                    return false;
                }
            });

            const parsedEvent = governor.interface.parseLog(event as any);
            proposalId = parsedEvent?.args.proposalId;

            expect(proposalId).to.not.be.undefined;
        });

        it("should reject proposal from address without enough tokens", async function () {
            const signers = await ethers.getSigners();
            const newAddr = signers[6]; // no tokens

            const targets = [await raffle.getAddress()];
            const values = [0n];
            const calldatas = [
                raffle.interface.encodeFunctionData("setFeePercentages", [5, 5, 90])
            ];
            const description = "Should fail";

            await expect(
                governor.connect(newAddr).propose(targets, values, calldatas, description)
            ).to.be.revertedWithCustomError(governor, "GovernorInsufficientProposerVotes");
        });
    });

    describe("voting", function () {
        beforeEach(async function () {
            const targets = [await raffle.getAddress()];
            const values = [0n];
            const calldatas = [
                raffle.interface.encodeFunctionData("setFeePercentages", [5, 5, 90])
            ];
            const description = "Proposa1";

            const tx = await governor.connect(alice).propose(
                targets,
                values,
                calldatas,
                description
            );

            const receipt = await tx.wait();
            const event = receipt?.logs.find((log: any) => {
                try {
                    return governor.interface.parseLog(log)?.name === "ProposalCreated";
                } catch {
                    return false;
                }
            });

            const parsedEvent = governor.interface.parseLog(event as any);
            proposalId = parsedEvent?.args.proposalId;
        });

        it("should allow voting when active", async function () {
            await mineBlocks(2);

            await governor.connect(alice).castVote(proposalId, 1);
            await governor.connect(bob).castVote(proposalId, 1);  

            const votes = await governor.proposalVotes(proposalId);
            expect(votes.forVotes).to.equal(ethers.parseEther("200000"));
        });
    });

    describe("flow", function () {
        it("propose -> vote -> queue -> execute", async function () {

            expect(await raffle.platformFeePercent()).to.equal(0);
            expect(await raffle.founderFeePercent()).to.equal(0);
            expect(await raffle.winnerFeePercent()).to.equal(100);

            const targets = [await raffle.getAddress()];
            const values = [0n];
            const calldatas = [
                raffle.interface.encodeFunctionData("setFeePercentages", [5, 5, 90])
            ];
            const description = "Proposal implement fee split 5-5-90";

            const proposeTx = await governor.connect(alice).propose(
                targets,
                values,
                calldatas,
                description
            );

            const proposeReceipt = await proposeTx.wait();
            const proposeEvent = proposeReceipt?.logs.find((log: any) => {
                try {
                    return governor.interface.parseLog(log)?.name === "ProposalCreated";
                } catch {
                    return false;
                }
            });

            const parsedProposeEvent = governor.interface.parseLog(proposeEvent as any);
            const fullProposalId = parsedProposeEvent?.args.proposalId;
            const fullDescHash = ethers.id(description);

            await mineBlocks(2);
            const stateActive = await governor.state(fullProposalId);
            expect(stateActive).to.equal(1n); // activ

            await governor.connect(alice).castVote(fullProposalId, 1);

            await governor.connect(bob).castVote(fullProposalId, 1);

            await mineBlocks(11);
            const stateSucceeded = await governor.state(fullProposalId);
            expect(stateSucceeded).to.equal(4n); // succeeded

            await governor.queue(targets, values, calldatas, fullDescHash);
            const stateQueued = await governor.state(fullProposalId);
            expect(stateQueued).to.equal(5n); // queues

            await advanceTime(2 * 24 * 60 * 60 + 1);

            await governor.execute(targets, values, calldatas, fullDescHash);
            const stateExecuted = await governor.state(fullProposalId);
            expect(stateExecuted).to.equal(7n); // executed

            expect(await raffle.platformFeePercent()).to.equal(5);
            expect(await raffle.founderFeePercent()).to.equal(5);
            expect(await raffle.winnerFeePercent()).to.equal(90);
        
        });
    });
});