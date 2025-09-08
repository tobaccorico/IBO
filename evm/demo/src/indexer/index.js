// src/indexer/index.js
const { ethers } = require('ethers');
const express = require('express');
const cors = require('cors');
const { Server } = require('socket.io');
const http = require('http');

// Import your contract ABIs and addresses
const CONTRACT_ADDRESSES = {
  aux: '0x2Ce5CfbA940b8e8791864307413bA1334BBd0CD1',
  v3Pool: '0xEcb04e075503Bd678241f00155AbCB532c0a15Eb',
  router: '0x7bAe2554ED287380941B1706DC8cFf665137ca58'
};

const AUX_ABI = [
  "event LeveragedPositionOpened(address indexed user, bool indexed isLong, uint256 supplied, uint256 borrowed, uint256 buffer, int256 entryPrice, uint256 breakeven, uint256 blockNumber)",
  "event PositionUnwound(address indexed user, bool indexed isLong, int256 exitPrice, int256 priceDelta, uint256 blockNumber)",
  "function unwindZeroForOne(address[] calldata whose)",
  "function unwindOneForZero(address[] calldata whose)"
];

const V3_POOL_ABI = [
  "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool)"
];

class LeverageIndexer {
  constructor() {
    this.positions = new Map();
    this.currentPrice = 0n;
    this.pendingUnwinds = new Map();
    this.UNWIND_THRESHOLD = 49; // 4.9%
    
    // Initialize provider and contracts
    this.provider = new ethers.JsonRpcProvider(
      'https://rpc.soniclabs.com'
    );
    
    // Use a wallet if you want automatic unwinds
    if (process.env.PRIVATE_KEY) {
      this.signer = new ethers.Wallet(
        process.env.PRIVATE_KEY,
        this.provider
      );
      this.auxContract = new ethers.Contract(
        CONTRACT_ADDRESSES.aux,
        AUX_ABI,
        this.signer
      );
    } else {
      this.auxContract = new ethers.Contract(
        CONTRACT_ADDRESSES.aux,
        AUX_ABI,
        this.provider
      );
    }
    
    this.v3Pool = new ethers.Contract(
      CONTRACT_ADDRESSES.v3Pool,
      V3_POOL_ABI,
      this.provider
    );
  }
  
  async start() {
    console.log('Starting indexer...');
    
    // Listen for events
    this.auxContract.on('LeveragedPositionOpened', (user, isLong, supplied, borrowed, buffer, entryPrice, breakeven, blockNumber) => {
      const key = `${user.toLowerCase()}-${isLong}`;
      const position = {
        user: user.toLowerCase(),
        isLong,
        supplied: supplied.toString(),
        borrowed: borrowed.toString(),
        buffer: buffer.toString(),
        entryPrice: entryPrice.toString(),
        breakeven: breakeven.toString(),
        blockNumber: blockNumber.toString()
      };
      
      this.positions.set(key, position);
      console.log(`New ${isLong ? 'LONG' : 'SHORT'} position:`, user);
      
      if (this.io) {
        this.io.emit('position:opened', position);
      }
    });
    
    this.auxContract.on('PositionUnwound', (user, isLong, exitPrice, priceDelta, blockNumber) => {
      const key = `${user.toLowerCase()}-${isLong}`;
      this.positions.delete(key);
      
      console.log(`Position unwound: ${user} at delta ${priceDelta.toString()}`);
      
      if (this.io) {
        this.io.emit('position:unwound', {
          user: user.toLowerCase(),
          isLong,
          exitPrice: exitPrice.toString(),
          priceDelta: priceDelta.toString()
        });
      }
    });
    
    // Update price periodically
    setInterval(() => this.updatePrice(), 2000);
    
    // Check for unwinds periodically
    if (this.signer) {
      setInterval(() => this.checkUnwinds(), 10000);
    }
  }
  
  async updatePrice() {
    try {
      const slot0 = await this.v3Pool.slot0();
      // Simple price calculation - adjust based on your needs
      this.currentPrice = slot0.sqrtPriceX96;
    } catch (error) {
      console.error('Error updating price:', error);
    }
  }
  
  async checkUnwinds() {
    // Simplified unwind checking
    for (const [key, position] of this.positions) {
      const priceDelta = this.calculateDelta(position.entryPrice);
      if (Math.abs(priceDelta) >= this.UNWIND_THRESHOLD) {
        this.pendingUnwinds.set(key, priceDelta);
      }
    }
    
    // Execute unwinds if any pending
    if (this.pendingUnwinds.size > 0 && this.signer) {
      await this.executeUnwinds();
    }
  }
  
  calculateDelta(entryPrice) {
    if (!this.currentPrice || !entryPrice) return 0;
    // Simplified calculation - adjust based on your contract's logic
    return 0; // Implement actual calculation
  }
  
  async executeUnwinds() {
    // Group by type and execute
    const longs = [];
    const shorts = [];
    
    for (const [key, delta] of this.pendingUnwinds) {
      const position = this.positions.get(key);
      if (position) {
        if (position.isLong) {
          longs.push(position.user);
        } else {
          shorts.push(position.user);
        }
      }
    }
    
    try {
      if (longs.length > 0) {
        const tx = await this.auxContract.unwindZeroForOne(longs);
        console.log('Unwinding longs:', tx.hash);
      }
      if (shorts.length > 0) {
        const tx = await this.auxContract.unwindOneForZero(shorts);
        console.log('Unwinding shorts:', tx.hash);
      }
      this.pendingUnwinds.clear();
    } catch (error) {
      console.error('Error executing unwinds:', error);
    }
  }
  
  getMetrics() {
    return {
      totalPositions: this.positions.size,
      pendingUnwinds: this.pendingUnwinds.size,
      positions: Array.from(this.positions.values())
    };
  }
}

// Create Express server
const app = express();
app.use(cors());
app.use(express.json());

const indexer = new LeverageIndexer();

// API endpoints
app.get('/api/positions', (req, res) => {
  res.json(Array.from(indexer.positions.values()));
});

app.get('/api/metrics', (req, res) => {
  res.json(indexer.getMetrics());
});

// Start server
const PORT = process.env.REACT_APP_INDEXER_PORT || 3001;
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: "http://localhost:3000",
    methods: ["GET", "POST"]
  }
});

indexer.io = io;

server.listen(PORT, () => {
  console.log(`Indexer API running on port ${PORT}`);
  indexer.start();
});