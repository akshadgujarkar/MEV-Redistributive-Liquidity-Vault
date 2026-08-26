const { ethers } = require("ethers");

// Configuration - Replace with actual deployed addresses and RPC URL
const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
const PRIVATE_KEY = process.env.PRIVATE_KEY; 

const ANALYTICS_EMITTER_ADDRESS = process.env.ANALYTICS_EMITTER_ADDRESS;
const SCOUT_POINTS_ORACLE_ADDRESS = process.env.SCOUT_POINTS_ORACLE_ADDRESS;
const MEV_SCOUT_LEAGUE_ADDRESS = process.env.MEV_SCOUT_LEAGUE_ADDRESS;

if (!PRIVATE_KEY || !ANALYTICS_EMITTER_ADDRESS || !SCOUT_POINTS_ORACLE_ADDRESS || !MEV_SCOUT_LEAGUE_ADDRESS) {
    console.error("Missing required environment variables. Please set PRIVATE_KEY, ANALYTICS_EMITTER_ADDRESS, SCOUT_POINTS_ORACLE_ADDRESS, and MEV_SCOUT_LEAGUE_ADDRESS.");
    process.exit(1);
}

// ABIs
const ANALYTICS_EMITTER_ABI = [
    "event MEVDetected(bytes32 indexed poolId, address indexed trader, uint256 riskScore, uint24 feeSurcharge)"
];

const SCOUT_POINTS_ORACLE_ABI = [
    "function reportDetection(address trader, uint256 seasonId, bytes32 signalType, address[] calldata lps) external"
];

const MEV_SCOUT_LEAGUE_ABI = [
    "function currentSeasonId() external view returns (uint256)",
    "function getSeasonParticipants(uint256 seasonId) external view returns (address[] memory)"
];

async function main() {
    const provider = new ethers.JsonRpcProvider(RPC_URL);
    const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

    const analyticsEmitter = new ethers.Contract(ANALYTICS_EMITTER_ADDRESS, ANALYTICS_EMITTER_ABI, provider);
    const oracle = new ethers.Contract(SCOUT_POINTS_ORACLE_ADDRESS, SCOUT_POINTS_ORACLE_ABI, wallet);
    const league = new ethers.Contract(MEV_SCOUT_LEAGUE_ADDRESS, MEV_SCOUT_LEAGUE_ABI, provider);

    console.log("Starting relayer...");
    console.log("Listening to AnalyticsEmitter at", ANALYTICS_EMITTER_ADDRESS);

    analyticsEmitter.on("MEVDetected", async (poolId, trader, riskScore, feeSurcharge, event) => {
        console.log(`\nMEVDetected event caught!`);
        console.log(`Trader: ${trader}`);
        console.log(`Risk Score: ${riskScore.toString()}`);
        console.log(`Fee Surcharge: ${feeSurcharge.toString()}`);

        try {
            // Get current active season
            const currentSeasonId = await league.currentSeasonId();

            // Determine signal type based on risk score (simplified heuristic for demo)
            // In a production environment, the relayer might decode this more precisely if the contract emitted the exact sub-signals.
            // But based on our weight tables: PRIORITY_FEE(25), PRICE_IMPACT(20), REVERSAL(30)
            let signalTypeStr = "UNKNOWN";
            if (riskScore >= 30) signalTypeStr = "REVERSAL";
            else if (riskScore >= 25) signalTypeStr = "PRIORITY_FEE";
            else if (riskScore >= 20) signalTypeStr = "PRICE_IMPACT";

            const signalTypeHash = ethers.id(signalTypeStr); // keccak256

            // Get participants to pass to Oracle
            const participants = await league.getSeasonParticipants(currentSeasonId);
            
            console.log(`Reporting to Oracle for Season ${currentSeasonId} with Signal Type ${signalTypeStr}...`);
            const tx = await oracle.reportDetection(trader, currentSeasonId, signalTypeHash, participants);
            
            console.log(`Transaction submitted! Hash: ${tx.hash}`);
            await tx.wait();
            console.log(`Transaction confirmed.`);
        } catch (error) {
            console.error("Error processing MEVDetected event:", error);
        }
    });
}

main().catch(console.error);
