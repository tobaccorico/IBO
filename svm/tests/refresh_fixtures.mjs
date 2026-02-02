#!/usr/bin/env node
// Refresh Pyth price feed fixtures from mainnet
// Handles large integers (rentEpoch) properly
//
// Usage:
//   node refresh_fixtures.mjs              # Refresh all fixtures
//   node refresh_fixtures.mjs --depeg      # Create depegged stablecoins ($0.85) AND crashed assets (50% price)
//   node refresh_fixtures.mjs --depeg 0.90 # Custom stablecoin price (assets still crash to 50%)
//
// The --depeg flag creates rogue fixtures for BOTH:
//   1. Stablecoins at $0.85 (below $0.96 DEPEG_THRESHOLD) - triggers depeg resolution
//   2. Assets (BTC/ETH/SOL/XAU/XAG) at 50% price - triggers liquidation of high-leverage positions

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Standard Pyth accounts - assets that can be used as collateral
const ASSET_ACCOUNTS = {
  XAG: "H9JxsWwtDZxjSL6m7cdCVsWibj3JBMD9sxqLjadoZnot",
  XAU: "2uPQGpm8X4ZkxMHxrAW1QuhXcse1AHEgPih6Xp9NuEWW",
  BTC: "4cSM2e6rvbGQUFiJbqytoVMi5GgghSMr8LwVrT9VPSPo",
  ETH: "42amVS4KgzR9rA28tkVYqVXjq9Qa8dcZQMbH5EYFX6XC",
  SOL: "7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE",
};

// Pyth receiver program (needed for price verification)
const PYTH_RECEIVER = "rec5EKMGg6MxZYaMdyBfgwp4d5rB9T1VQH5pJv5LtFJ";

// Stablecoin Pyth accounts (from etc.rs STABLECOINS_ACCOUNT_MAP)
const STABLECOIN_ACCOUNTS = {
  USDC: "Dpw1EAVrSB1ibxiDQyTAW6Zip3J4Btk2x4SgApQCeFbX",
  USDT: "HT2PLQBcG5EiCcNSaMHAjSgd9F98ecpATbk4Sk5oYuM",
  DAI: "FmfrxJ7YH8yVxoYpJ9ZDMeb8gUceYXYaSrQiBJ1uSZjN",
  PYUSD: "9zXQxpYH3kYhtoybmZfUNNCRVuud7fY9jswTg1hLyT8k",
};

// Pyth account data offsets (from fetch_price in etc.rs)
const PRICE_OFFSET = 73;        // i64 price
const EXPONENT_OFFSET = 89;     // i32 exponent  
const PUBLISH_TIME_OFFSET = 93; // i64 publish_time

// DEPEG_THRESHOLD from etc.rs = 960_000 ($0.96 with 6 decimals)
const DEPEG_THRESHOLD = 960_000;

// Crash ratio for liquidation testing (50% = position at 80% leverage becomes 160% underwater)
const ASSET_CRASH_RATIO = 0.50;

const RPC_URL = process.env.HELIUS_RPC || "https://api.mainnet-beta.solana.com";

async function fetchAccount(addr) {
  const resp = await fetch(RPC_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "getAccountInfo",
      params: [addr, { encoding: "base64" }],
    }),
  });

  const text = await resp.text();
  const json = JSON.parse(text);
  const value = json.result?.value;

  if (!value) return null;

  return {
    pubkey: addr,
    account: {
      lamports: value.lamports,
      data: value.data,
      owner: value.owner,
      executable: value.executable,
      rentEpoch: 0, // Set to 0 - it's deprecated anyway
    },
  };
}

function createModifiedPriceFixture(fixture, targetPriceRatio) {
  // Clone fixture
  const rogueFixture = JSON.parse(JSON.stringify(fixture));
  const data = Buffer.from(rogueFixture.account.data[0], "base64");

  // Read original price
  const originalPrice = data.readBigInt64LE(PRICE_OFFSET);
  const exponent = data.readInt32LE(EXPONENT_OFFSET);

  // Calculate new price (multiply original by ratio)
  const newPrice = BigInt(Math.round(Number(originalPrice) * targetPriceRatio));

  // Write new price
  data.writeBigInt64LE(newPrice, PRICE_OFFSET);

  // Update publish_time to now (avoid staleness check)
  const now = BigInt(Math.floor(Date.now() / 1000));
  data.writeBigInt64LE(now, PUBLISH_TIME_OFFSET);

  // Re-encode
  rogueFixture.account.data[0] = data.toString("base64");

  return {
    fixture: rogueFixture,
    originalPrice: Number(originalPrice),
    newPrice: Number(newPrice),
    exponent,
  };
}

async function main() {
  const args = process.argv.slice(2);
  const createRogueFixtures = args.includes("--depeg");
  
  // Parse custom depeg price (default 0.85 = $0.85, well below $0.96 threshold)
  let depegPrice = 0.85;
  const depegIdx = args.indexOf("--depeg");
  if (depegIdx !== -1 && args[depegIdx + 1] && !args[depegIdx + 1].startsWith("-")) {
    depegPrice = parseFloat(args[depegIdx + 1]);
    if (isNaN(depegPrice) || depegPrice <= 0 || depegPrice >= 1) {
      console.error("Invalid depeg price. Must be between 0 and 1 (e.g., 0.85 for $0.85)");
      process.exit(1);
    }
  }

  const fixturesDir = path.join(__dirname, "../tests/fixtures");
  if (!fs.existsSync(fixturesDir)) {
    fs.mkdirSync(fixturesDir, { recursive: true });
  }

  console.log(`Using RPC: ${RPC_URL}\n`);

  // Fetch asset accounts (BTC, ETH, SOL, XAU, XAG)
  console.log("=== Asset Pyth Accounts ===\n");
  for (const [ticker, addr] of Object.entries(ASSET_ACCOUNTS)) {
    console.log(`Fetching ${ticker} (${addr.slice(0, 12)}...)...`);

    try {
      const fixture = await fetchAccount(addr);
      if (!fixture) {
        console.log(`  ✗ Account not found`);
        continue;
      }

      // Save original
      const filePath = path.join(fixturesDir, `${addr}.json`);
      fs.writeFileSync(filePath, JSON.stringify(fixture, null, 2));
      console.log(`  ✓ Saved original (${fs.statSync(filePath).size} bytes)`);

      // Create crashed version if --depeg mode
      if (createRogueFixtures) {
        const { fixture: crashedFixture, originalPrice, newPrice, exponent } = 
          createModifiedPriceFixture(fixture, ASSET_CRASH_RATIO);

        const crashedFilePath = path.join(fixturesDir, `${addr}_CRASHED.json`);
        fs.writeFileSync(crashedFilePath, JSON.stringify(crashedFixture, null, 2));

        const origPriceUsd = originalPrice * Math.pow(10, exponent);
        const newPriceUsd = newPrice * Math.pow(10, exponent);
        console.log(`  ✓ Saved CRASHED: $${origPriceUsd.toFixed(2)} → $${newPriceUsd.toFixed(2)} (${(ASSET_CRASH_RATIO * 100).toFixed(0)}%)`);
      }
    } catch (e) {
      console.log(`  ✗ Error: ${e.message}`);
    }
  }

  // Fetch Pyth receiver program
  console.log(`\nFetching Pyth Receiver (${PYTH_RECEIVER.slice(0, 12)}...)...`);
  try {
    const fixture = await fetchAccount(PYTH_RECEIVER);
    if (fixture) {
      const filePath = path.join(fixturesDir, `${PYTH_RECEIVER}.json`);
      fs.writeFileSync(filePath, JSON.stringify(fixture, null, 2));
      console.log(`  ✓ Saved`);
    }
  } catch (e) {
    console.log(`  ✗ Error: ${e.message}`);
  }

  // Fetch stablecoin accounts
  console.log("\n=== Stablecoin Pyth Accounts ===\n");
  for (const [ticker, addr] of Object.entries(STABLECOIN_ACCOUNTS)) {
    console.log(`Fetching ${ticker} (${addr.slice(0, 12)}...)...`);

    try {
      const fixture = await fetchAccount(addr);
      if (!fixture) {
        console.log(`  ✗ Account not found`);
        continue;
      }

      // Save original
      const filePath = path.join(fixturesDir, `${addr}.json`);
      fs.writeFileSync(filePath, JSON.stringify(fixture, null, 2));
      console.log(`  ✓ Saved original`);

      // Create depegged version if --depeg mode
      if (createRogueFixtures) {
        const { fixture: rogueFixture, originalPrice, newPrice, exponent } = 
          createModifiedPriceFixture(fixture, depegPrice);

        const rogueFilePath = path.join(fixturesDir, `${addr}_DEPEGGED.json`);
        fs.writeFileSync(rogueFilePath, JSON.stringify(rogueFixture, null, 2));

        const origPriceUsd = originalPrice * Math.pow(10, exponent);
        const newPriceUsd = newPrice * Math.pow(10, exponent);
        console.log(`  ✓ Saved DEPEGGED: $${origPriceUsd.toFixed(4)} → $${newPriceUsd.toFixed(4)}`);
      }
    } catch (e) {
      console.log(`  ✗ Error: ${e.message}`);
    }
  }

  // Summary
  console.log("\n" + "=".repeat(60));
  console.log("SUMMARY");
  console.log("=".repeat(60) + "\n");
  console.log(`Fixtures saved to: ${fixturesDir}`);

  if (createRogueFixtures) {
    console.log("\n┌─────────────────────────────────────────────────────────────┐");
    console.log("│ ROGUE FIXTURES CREATED                                      │");
    console.log("├─────────────────────────────────────────────────────────────┤");
    console.log(`│ Stablecoins: $${depegPrice.toFixed(2)} (threshold: $0.96)                       │`);
    console.log(`│ Assets:      ${(ASSET_CRASH_RATIO * 100).toFixed(0)}% of original (triggers liquidation)          │`);
    console.log("└─────────────────────────────────────────────────────────────┘");

    console.log("\n=== What This Enables ===\n");
    console.log("1. DEPEG TESTING:");
    console.log("   - Stablecoins priced at $" + depegPrice.toFixed(2) + " (below $0.96 threshold)");
    console.log("   - Markets with resolve_whenever=true auto-resolve on depeg");
    console.log("");
    console.log("2. LIQUIDATION TESTING:");
    console.log("   - Assets (BTC/ETH/SOL/XAU/XAG) at " + (ASSET_CRASH_RATIO * 100).toFixed(0) + "% of original price");
    console.log("   - Position at 80% leverage → 160% effective → liquidatable");
    console.log("   - Position at 60% leverage → 120% effective → liquidatable");
    console.log("");
    console.log("=== Usage ===\n");
    console.log("  ./start-validator.sh --depeg    # Loads all rogue fixtures");
    console.log("  anchor test --skip-local-validator");
    console.log("");
  } else {
    console.log("\nTo create rogue fixtures for depeg + liquidation testing:");
    console.log("  yarn refresh --depeg");
  }

  console.log("Done!");
}

main().catch(console.error);