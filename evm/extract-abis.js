// Run this from your foundry project root after forge build
const fs = require('fs');
const path = require('path');

// Read the JSON files from forge output
const factoryJson = JSON.parse(fs.readFileSync('./out/AuctionFactory.sol/AuctionFactory.json', 'utf8'));
const helpersJson = JSON.parse(fs.readFileSync('./out/AuctionHelpers.sol/AuctionHelpers.json', 'utf8'));
const settlementJson = JSON.parse(fs.readFileSync('./out/Settlement.sol/Settlement.json', 'utf8'));
const auctionJson = JSON.parse(fs.readFileSync('./out/Auction.sol/Auction.json', 'utf8'));

// Extract just the ABIs
const abis = {
  FACTORY_ABI: factoryJson.abi,
  HELPERS_ABI: helpersJson.abi,
  SETTLEMENT_ABI: settlementJson.abi,
  AUCTION_ABI: auctionJson.abi
};

// Write to a file that can be imported
const output = `
export const FACTORY_ABI = ${JSON.stringify(factoryJson.abi, null, 2)};

export const HELPERS_ABI = ${JSON.stringify(helpersJson.abi, null, 2)};

export const SETTLEMENT_ABI = ${JSON.stringify(settlementJson.abi, null, 2)};

export const AUCTION_ABI = ${JSON.stringify(auctionJson.abi, null, 2)};
`;

// Save to your React app's contracts folder
fs.writeFileSync('demo/src/contracts/abis.ts', output);
console.log('ABIs extracted successfully!');