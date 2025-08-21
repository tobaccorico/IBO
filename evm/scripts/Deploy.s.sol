// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {Aux} from "../src/Aux.sol";
import {Rover} from "../src/Rover.sol";
import {BasketL2} from "../src/BasketL2.sol";
import {Settlement} from "../src/Settlement.sol";
import {AuctionFactory} from "../src/AuctionFactory.sol";
import {AuctionHelpers} from "../src/AuctionHelpers.sol";
import {Auction} from "../src/Auction.sol";

// import {IV3SwapRouter as ISwapRouter} from "../src/imports/V3/IV3SwapRouter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {ISwapRouter} from "../src/imports/v3/ISwapRouter.sol";

// ============ Enhanced Dummy Contracts for Testing ============

// Minimal Basket implementation for testing
contract DummyBasket {
    mapping(address => uint) public totalBalances;
    mapping(address => mapping(uint => uint)) public balances;
    mapping(address => bool) public isStable;
    mapping(address => bool) public isVault;
    mapping(uint => address) public holders;
    mapping(address => uint) public holder_to_id;
    mapping(address => bool) public hasClaimed;
    
    address public V4;
    address public SET;
    uint public latest_holder = 0;
    
    string public name = "QUID";
    string public symbol = "QD";
    uint8 public decimals = 18;
    
    constructor(address _v4) {
        V4 = _v4;
        isStable[address(this)] = true;
    }
    
    function _autoFaucet(address user) internal {
        if (!hasClaimed[user] && totalBalances[user] < 100e18) {
            totalBalances[user] = 1000e18;
            hasClaimed[user] = true;
            
            if (holder_to_id[user] == 0) {
                latest_holder++;
                holders[latest_holder] = user;
                holder_to_id[user] = latest_holder;
            }
        }
    }
    
    function transferFrom(address from, address to, uint amount) external returns (bool) {
        _autoFaucet(from);
        
        require(totalBalances[from] >= amount, "Insufficient balance");
        totalBalances[from] -= amount;
        totalBalances[to] += amount;
        
        if (holder_to_id[to] == 0 && to != address(0)) {
            latest_holder++;
            holders[latest_holder] = to;
            holder_to_id[to] = latest_holder;
        }
        
        return true;
    }
    
    function transfer(address to, uint amount) external returns (bool) {
        require(totalBalances[msg.sender] >= amount, "Insufficient balance");
        totalBalances[msg.sender] -= amount;
        totalBalances[to] += amount;
        
        if (holder_to_id[to] == 0 && to != address(0)) {
            latest_holder++;
            holders[latest_holder] = to;
            holder_to_id[to] = latest_holder;
        }
        
        return true;
    }
    
    function mint(address to, uint amount, address, uint) external {
        totalBalances[to] += amount;
        
        if (holder_to_id[to] == 0) {
            latest_holder++;
            holders[latest_holder] = to;
            holder_to_id[to] = latest_holder;
        }
    }
    
    function deposit(address from, address token, uint amount) external returns (uint) {
        _autoFaucet(from);
        
        if (token == address(this)) {
            totalBalances[from] += amount;
            return amount;
        }
        return amount * 1e12;
    }
    
    function take(address who, uint amount, address token, bool) external returns (uint) {
        if (token == address(this)) {
            require(totalBalances[who] >= amount, "Insufficient balance");
            totalBalances[who] -= amount;
            return amount;
        }
        return amount;
    }
    
    function turn(address from, uint value) external returns (uint) {
        require(totalBalances[from] >= value, "Insufficient balance");
        totalBalances[from] -= value;
        return value;
    }
    
    function setSettlement(address _settlement) external {
        SET = _settlement;
    }
    
    function faucet() external {
        require(!hasClaimed[msg.sender], "Already claimed");
        totalBalances[msg.sender] += 1000e18;
        hasClaimed[msg.sender] = true;
        
        if (holder_to_id[msg.sender] == 0) {
            latest_holder++;
            holders[latest_holder] = msg.sender;
            holder_to_id[msg.sender] = latest_holder;
        }
    }
    
    function balanceOf(address owner, uint) external view returns (uint) {
        return totalBalances[owner];
    }
    
    function balanceOf(address owner) external view returns (uint) {
        return totalBalances[owner];
    }
}

// Enhanced Aux implementation for testing with auto-clearing
contract DummyAux {
    uint constant ETH_PRICE = 3000e18;
    address public WETH;
    address public basket;
    
    constructor(address _weth, address _basket) {
        WETH = _weth;
        basket = _basket;
    }
    
    function swap(address to, bool, uint ethAmount, uint) external payable returns (uint) {
        require(msg.value == ethAmount, "ETH mismatch");
        
        // Convert ETH to USD at $3000/ETH
        uint usdAmount = (ethAmount * 3000e6) / 1e18;
        
        // Mint QUID to user
        DummyBasket(basket).mint(to, usdAmount * 1e12, address(0), 0);
        
        // Auto-clear epochs for better UX
        _autoClearEpochs(msg.sender);
        
        return usdAmount;
    }
    
    function _autoClearEpochs(address potentialAuction) internal {
        try Auction(payable(potentialAuction)).getCurrentEpochInfo() returns (
            uint index,
            uint,
            uint timeRemaining,
            uint bidCount,
            bool
        ) {
            // Clear current epoch if it's ended and has bids
            if (timeRemaining == 0 && bidCount > 0) {
                try Auction(payable(potentialAuction)).clearEpoch(index) {} catch {}
            }
            
            // Clear previous epochs that might be pending
            if (index > 0) {
                for (uint i = index - 1; i >= 0 && i >= index - 3; i--) {
                    try Auction(payable(potentialAuction)).clearEpoch(i) {} catch {}
                    if (i == 0) break;
                }
            }
        } catch {
            // Not an auction contract, ignore
        }
    }
    
    function wethVault() external view returns (address) {
        return address(this);
    }
    
    function setQuid(address) external payable {}
    
    function getPrice(uint160, bool) external pure returns (uint) {
        return ETH_PRICE;
    }
    
    function untouchable() external pure returns (uint) {
        return 0;
    }
    
    function QUID() external view returns (address) {
        return basket;
    }
    
    function sendETH(uint amount, address to) external {
        payable(to).transfer(amount);
    }
    
    function putETH(uint) external pure returns (uint) {
        return 0;
    }
    
    receive() external payable {}
}

// Minimal Rover implementation for testing
contract DummyRover {
    address public owner;
    address public QUID;
    
    constructor() {
        owner = msg.sender;
    }
    
    function setup(address _quid, address, address) external {
        QUID = _quid;
    }
}

// Minimal WETH for testing
contract DummyWETH {
    mapping(address => uint) public balanceOf;
    
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
    
    function withdraw(uint amount) external {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
    
    function transfer(address to, uint amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint amount) external returns (bool) {
        require(balanceOf[from] >= amount);
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function approve(address, uint) external pure returns (bool) {
        return true;
    }
    
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract Deploy is Script {
    address[] public STABLECOINS;
    
    // IPoolAddressesProvider
    address public aaveAddr = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D;
    // Ethereum : 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e
    // Polygon : 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb
    // Unichain : 
    // Arbi : 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb
    // Base : 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D

    // IUiPoolDataProvider
    address public aaveData = 0x68100bD5345eA474D93577127C11F39FF8463e93;
    // Ethereum : 0x3F78BBD206e4D3c504Eb854232EdA7e47E9Fd8FC
    // Polygon : 0x68100bD5345eA474D93577127C11F39FF8463e93
    // Unichain :
    // Arbi : 0x5c5228aC8BC1528482514aF3e27E692495148717
    // Base : 0x68100bD5345eA474D93577127C11F39FF8463e93

    address public aavePool = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    // Ethereum : 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
    // Polygon : 0x794a61358D6845594F94dc1DB02A252b5b4814aD
    // Unichain : 
    // Arbi : 0x794a61358D6845594F94dc1DB02A252b5b4814aD
    // Base : 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5

    IERC20 public USDT = IERC20(0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2);
    IERC20 public USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 public DAI = IERC20(0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb);
    IERC20 public USDS = IERC20(0x820C137fa70C8691f0e44Dc420a5e53c168921Dc);
    IERC20 public USDE = IERC20(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34);
    IERC20 public CRVUSD = IERC20(0x417Ac0e078398C154EdFadD9Ef675d30Be60Af93);

    address[] public VAULTS;
    IERC4626 public gauntletWETHvault = IERC4626(0x27D8c7273fd3fcC6956a0B370cE5Fd4A7fc65c18);
    IERC4626 public USDCvault = IERC4626(0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183);
    IERC4626 public sUSDSvault = IERC4626(0xB17B070A56043e1a5a1AB7443AfAFDEbcc1168D7);
    IERC4626 public SUSDS = IERC4626(0x5875eEE11Cf8398102FdAd704C9E96607675467a);
    IERC4626 public SUSDE = IERC4626(0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2);
    IERC4626 public SCRVUSD = IERC4626(0x646A737B9B6024e49f5908762B3fF73e65B5160c);

    IPoolManager public poolManager = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    ISwapRouter public V3router = ISwapRouter(0x2626664c2603336E57B271c5C0b26F421741e481);
    IUniswapV3Pool public V3pool = IUniswapV3Pool(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59);

    // Deploy contracts
    function run() public {
        // Handle private key
        string memory privateKeyStr = vm.envString("PRIVATE_KEY");
        uint256 deployerPrivateKey;
        
        if (bytes(privateKeyStr).length > 2 && 
            bytes(privateKeyStr)[0] == 0x30 && 
            bytes(privateKeyStr)[1] == 0x78) {
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        } else {
            deployerPrivateKey = vm.parseUint(string(abi.encodePacked("0x", privateKeyStr)));
        }
        
        vm.startBroadcast(deployerPrivateKey);

       /* COMMENTED OUT - Real deployments
        Rover V4router = new Rover(poolManager);
        
        Aux AUX = new Aux(address(V4router),
            address(V3pool), address(V3router),
            address(gauntletWETHvault), aavePool,
            aaveData, aaveAddr);
      
        Basket QUID = new BasketL2(
            address(V4router), address(AUX), 
            address(USDCvault), address(sUSDSvault),
            address(USDC), address(DAI),
            address(USDS), address(SUSDS),
           address(USDE), address(SUSDE), 
            address(CRVUSD), address(SCRVUSD)
        );  

        // TODO send WETH and USDC to AUX for linking AAVE

        V4router.setup(address(QUID),
            address(AUX), address(V3pool));
        
        USDC.transfer(address(AUX), 1000000);
        AUX.setQuid{value: 1 wei}(address(QUID));
        */

        console.log("Deploying dummy contracts for testing...");
        
        // Deploy dummy contracts
        DummyWETH dummyWETH = new DummyWETH();
        console.log("Dummy WETH:", address(dummyWETH));
        
        DummyRover V4router = new DummyRover();
        console.log("Dummy Rover:", address(V4router));
        
        DummyBasket QUID = new DummyBasket(address(V4router));
        console.log("Dummy Basket:", address(QUID));
        
        DummyAux AUX = new DummyAux(address(dummyWETH), address(QUID));
        console.log("Dummy Aux:", address(AUX));
        
        // Setup connections
        V4router.setup(address(QUID), address(AUX), address(0));
        
        // Fund Aux with ETH for auto-clearing
        payable(address(AUX)).transfer(0.1 ether);
        console.log("Sent ETH to Aux for auto-clearing: 0.1 ether");

        // Deploy core contracts
        Settlement settlement = new Settlement();
        settlement.initialize(address(QUID), address(0));
        
        AuctionFactory factory = new AuctionFactory(
            address(settlement),
            address(V4router),
            address(AUX),
            address(QUID)
        );
        
        AuctionHelpers helpers = new AuctionHelpers(
            address(factory),
            address(settlement),
            address(QUID)
        );
        
        // Connect Settlement to Basket
        QUID.setSettlement(address(settlement));
        
        // Mint tokens to deployer for testing
        QUID.mint(msg.sender, 10000e18, address(QUID), 0);
        console.log("Minted 10,000 QUID to deployer:", msg.sender);

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("QUID (Dummy Basket)", address(QUID));
        console.log("AUX (Dummy Aux)", address(AUX));
        console.log("V4 (Dummy Rover)", address(V4router));
        console.log("Settlement", address(settlement));
        console.log("Factory", address(factory));
        console.log("Helpers", address(helpers));
        
        console.log("");
        console.log("=== Test Instructions ===");
        console.log("1. Deployer has 10,000 QUID tokens for testing");
        console.log("2. Users automatically receive 1000 QUID when placing bets");
        console.log("3. Epochs auto-clear when new bets are placed (MEV protection)");
        console.log("4. No commit-reveal needed - uses velocity-based MEV protection");
        console.log("5. Use helpers.createRapBattle() for dare markets");
        
        // Create the deployment info for writing to file
        string memory addresses = string(abi.encodePacked(
            '// Auto-generated by deployment script\n',
            'export const FACTORY_ADDRESS = "', addressToString(address(factory)), '";\n',
            'export const HELPERS_ADDRESS = "', addressToString(address(helpers)), '";\n',
            'export const SETTLEMENT_ADDRESS = "', addressToString(address(settlement)), '";\n',
            'export const BASKET_ADDRESS = "', addressToString(address(QUID)), '";\n',
            'export const CHAIN_ID = ', uint2str(block.chainid), ';\n'
        ));
        
        // Try to write to the correct path that matches foundry.toml permissions
        try vm.writeFile("demo/src/contracts/addresses.ts", addresses) {
            console.log("Addresses written to demo/src/contracts/addresses.ts");
        } catch {
            console.log("Failed to write to demo/src/contracts/addresses.ts");
            console.log("Trying alternative path: src/contracts/addresses.ts");
            try vm.writeFile("src/contracts/addresses.ts", addresses) {
                console.log("Addresses written to src/contracts/addresses.ts");
            } catch {
                console.log("Failed to write to alternative path");
                console.log("Please manually create the file with this content:");
                console.log(addresses);
            }
        }
    
        vm.stopBroadcast();
    }
    
    function addressToString(address addr) internal pure returns (string memory) {
        bytes memory data = abi.encodePacked(addr);
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint i = 0; i < data.length; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
    
    function uint2str(uint value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint temp = value;
        uint digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}