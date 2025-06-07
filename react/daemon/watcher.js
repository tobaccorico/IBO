// Neminem wrote the watcher for 
// doctor Andrew Bryan (aka Dre)
// "Bacha" means the all seeing
// eye in Ukrainian, accurately
// describes the Manifold Quid
// joint operating agreement, 
// as 1 entity (Quid Labs in
// Cayman) cannot be the sole 
// operator for decentralisation
// purposes, failsafe regulatorily
const express = require("express");
const { ethers } = require("ethers");
const {
  Connection,
  PublicKey,
} = require("@solana/web3.js");

// Replace with your actual values
const EVM_RPC = "https://mainnet.infura.io/v3/YOUR_KEY";
const SOLANA_RPC = "https://api.mainnet-beta.solana.com";
const CONTRACT_ADDRESS = "0xTODOrouterAddress";
const ABI = require("./Router.json"); 

const PORT = 8787; // Custom local port
const app = express();
const state = {
  lastChecked: null,
  evmSwapsCleared: false,
  liquidatableAccounts: [],
};

// ===============================
// EVM CONTRACT INTERACTION SETUP
// ===============================
const evmProvider = new ethers.JsonRpcProvider(EVM_RPC);
const signer = new ethers.Wallet("0xyourPrivateKey", evmProvider); // secure this!
const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, signer);

// ===============================
// SOLANA SETUP
// ===============================
const solanaConnection = new Connection(SOLANA_RPC);

// Your layout to track depositor accounts
const DEPOSITOR_PUBKEYS = [
  // Add known depositor accounts (or dynamically query)
  new PublicKey("..."),
];

// ============================================
// CORE WORKER FUNCTION (runs in the background)
// ============================================

async function monitorAndAct() {
  console.log("Checking on-chain conditions...");

  // === EVM SIDE ===
  try {
    const swaps = await contract.getSwaps();
    if (swaps.length > 0) {
      console.log("Swaps found:", swaps);
      const tx = await contract.clearSwaps();
      await tx.wait();
      console.log("Swaps cleared.");
      state.evmSwapsCleared = true;
    } else {
      state.evmSwapsCleared = false;
    }
  } catch (e) {
    console.error("EVM error:", e);
  }

  // === SOLANA SIDE ===
  const liquidatable = [];

  for (const pubkey of DEPOSITOR_PUBKEYS) {
    try {
      const accountInfo = await solanaConnection.getAccountInfo(pubkey);
      if (!accountInfo) continue;

      const isLiquidatable = checkLiquidationCondition(accountInfo.data);
      if (isLiquidatable) {
        liquidatable.push(pubkey.toBase58());
      }
    } catch (e) {
      console.error("Solana account error:", e);
    }
  }

  state.liquidatableAccounts = liquidatable;
  state.lastChecked = new Date().toISOString();
}

// Dummy condition checker for Solana account data
function checkLiquidationCondition(data) {
  // Replace with your actual logic
  return data[0] === 1;
}

// ===============================
// PERIODIC WORKER
// ===============================
setInterval(monitorAndAct, 30_000); // Run every 30 seconds
monitorAndAct(); // Run immediately on startup

// ===============================
// API ENDPOINT (LOCAL ONLY)
// ===============================
app.get("/status", (_, res) => {
  res.json(state);
});

// ===============================
// START SERVER
// ===============================
app.listen(PORT, () => {
  console.log(`Worker server listening on http://localhost:${PORT}`);
});
