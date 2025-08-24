// Run this from your foundry project root after forge build
const fs = require('fs');
const path = require('path');

// Read the JSON files from forge output
const factoryJson = JSON.parse(fs.readFileSync('./out/AuctionFactory.sol/AuctionFactory.json', 'utf8'));
const helpersJson = JSON.parse(fs.readFileSync('./out/AuctionHelpers.sol/AuctionHelpers.json', 'utf8'));
const settlementJson = JSON.parse(fs.readFileSync('./out/Settlement.sol/Settlement.json', 'utf8'));
const auctionJson = JSON.parse(fs.readFileSync('./out/Auction.sol/Auction.json', 'utf8'));
const basketJson = JSON.parse(fs.readFileSync('./out/Basket.sol/Basket.json', 'utf8'));
const auxJson = JSON.parse(fs.readFileSync('./out/Aux.sol/Aux.json', 'utf8'));

const output = `
export const FACTORY_ABI = ${JSON.stringify(factoryJson.abi, null, 2)};

export const HELPERS_ABI = ${JSON.stringify(helpersJson.abi, null, 2)};

export const SETTLEMENT_ABI = ${JSON.stringify(settlementJson.abi, null, 2)};

export const AUCTION_ABI = ${JSON.stringify(auctionJson.abi, null, 2)};

export const BASKET_ABI = ${JSON.stringify(basketJson.abi, null, 2)};

export const AUX_ABI = ${JSON.stringify(auxJson.abi, null, 2)};
`;

fs.writeFileSync('demo/src/contracts/abis.ts', output);
console.log('ABIs extracted successfully!');