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

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {ISwapRouter} from "../src/imports/v3/ISwapRouter.sol"; // < L1 and Arbi
// import {IV3SwapRouter as ISwapRouter} from "../src/imports/V3/IV3SwapRouter.sol";

// ============ Dummy Contracts for Testing ============

// Minimal Basket implementation for testing
contract DummyBasket {
    mapping(address => uint) public totalBalances;
    mapping(address => mapping(uint => uint)) public balanceOf; // For 6909
    mapping(address => bool) public isStable;
    mapping(address => bool) public isVault;
    mapping(uint => address) public holders;
    mapping(address => uint) public holder_to_id;
    mapping(address => bool) public hasClaimed; // Track faucet claims
    
    address public V4;
    address public SET; // Settlement contract
    uint public latest_holder = 0;
    
    string public name = "QUID";
    string public symbol = "QD";
    uint8 public decimals = 18;
    
    constructor(address _v4) {
        V4 = _v4;
        isStable[address(this)] = true;
    }
    
    // Auto-faucet helper
    function _autoFaucet(address user) internal {
        if (!hasClaimed[user] && totalBalances[user] < 100e18) {
            // TODO: Remove this auto-faucet in production - only for testing
            totalBalances[user] = 1000e18; // Give 1000 QUID
            hasClaimed[user] = true;
            
            if (holder_to_id[user] == 0) {
                latest_holder++;
                holders[latest_holder] = user;
                holder_to_id[user] = latest_holder;
            }
        }
    }
    
    // Core ERC20 functions
    function transferFrom(address from, address to, uint amount) external returns (bool) {
        // Auto-faucet for testing convenience
        _autoFaucet(from);
        
        require(totalBalances[from] >= amount, "Insufficient balance");
        totalBalances[from] -= amount;
        totalBalances[to] += amount;
        
        // Track holders for jury selection
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
        
        // Track holders
        if (holder_to_id[to] == 0 && to != address(0)) {
            latest_holder++;
            holders[latest_holder] = to;
            holder_to_id[to] = latest_holder;
        }
        
        return true;
    }
    
    function mint(address to, uint amount, address, uint) external {
        totalBalances[to] += amount;
        
        // Track holders
        if (holder_to_id[to] == 0) {
            latest_holder++;
            holders[latest_holder] = to;
            holder_to_id[to] = latest_holder;
        }
    }
    
    function deposit(address from, address token, uint amount) external returns (uint) {
        // Auto-faucet for testing convenience
        _autoFaucet(from);
        
        // Mock deposit - just return scaled amount
        if (token == address(this)) {
            totalBalances[from] += amount;
            return amount;
        }
        // Assume USD tokens have 6 decimals
        return amount * 1e12;
    }
    
    function take(address who, uint amount, address token, bool) external returns (uint) {
        // Mock withdrawal
        if (token == address(this)) {
            require(totalBalances[who] >= amount, "Insufficient balance");
            totalBalances[who] -= amount;
            return amount;
        }
        return amount;
    }
    
    function turn(address from, uint value) external returns (uint) {
        // Mock burn for Settlement slashing
        require(totalBalances[from] >= value, "Insufficient balance");
        totalBalances[from] -= value;
        return value;
    }
    
    function setSettlement(address _settlement) external {
        SET = _settlement;
    }
    
    // Test faucet - gives users tokens for testing
    function faucet() external {
        require(!hasClaimed[msg.sender], "Already claimed");
        totalBalances[msg.sender] += 1000e18; // 1000 QUID
        hasClaimed[msg.sender] = true;
        
        if (holder_to_id[msg.sender] == 0) {
            latest_holder++;
            holders[latest_holder] = msg.sender;
            holder_to_id[msg.sender] = latest_holder;
        }
    }
    
    // For AuctionHelpers
    function balanceOf(address owner, uint) external view returns (uint) {
        return totalBalances[owner];
    }
}

// Minimal Aux implementation for testing
contract DummyAux {
    uint constant ETH_PRICE = 3000e18; // $3000 per ETH
    address public WETH;
    address public basket;
    
    constructor(address _weth, address _basket) {
        WETH = _weth;
        basket = _basket;
    }
    
    // Mock swap function - Auction calls this
    function swap(address to, bool, uint ethAmount, uint) external payable returns (uint) {
        require(msg.value == ethAmount, "ETH mismatch");
        
        // Calculate USD amount (6 decimals)
        uint usdAmount = (ethAmount * 3000e6) / 1e18;
        
        // Mock the basket deposit
        DummyBasket(basket).mint(to, usdAmount * 1e12, address(0), 0);
        
        return usdAmount;
    }
    
    // For Aux initialization check
    function wethVault() external view returns (address) {
        return address(this); // dummy
    }
    
    function setQuid(address) external payable {
        // Mock initialization
    }
    
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
        return 0; // dummy
    }
    
    receive() external payable {} // Accept ETH
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

// TODO morpho addresses across chains

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

    // IPool
    address public aavePool = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    // Ethereum : 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
    // Polygon : 0x794a61358D6845594F94dc1DB02A252b5b4814aD
    // Unichain : 
    // Arbi : 0x794a61358D6845594F94dc1DB02A252b5b4814aD
    // Base : 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5

    // IERC20 public GHO = IERC20();
    // Ethereum : 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f
    // Arbi : 0x7dfF72693f6A4149b17e7C6314655f6A9F7c8B33

    IERC20 public USDT = IERC20(0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2);
    // Ethereum : 0xdAC17F958D2ee523a2206206994597C13D831ec7
    // Polygon : 0xc2132D05D31c914a87C6611C10748AEb04B58e8F
    // Unichain : 0x588CE4F028D8e7B53B687865d6A67b3A54C75518
    // Arbi : 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9
    // Base : 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2

    IERC20 public USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    // Ethereum : 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    // Polygon : 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359
    // Unichain : 0x078D782b760474a361dDA0AF3839290b0EF57AD6
    // Arbi : 0xaf88d065e77c8cC2239327C5EDb3A432268e5831
    // Base : 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913

    IERC20 public DAI = IERC20(0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb);
    // Ethereum : 0x6B175474E89094C44Da98b954EedeAC495271d0F
    // Polygon : 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063
    // Unichain : 0x20CAb320A855b39F724131C69424240519573f81
    // Base : 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb
    // Arbi : 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1

    IERC20 public USDS = IERC20(0x820C137fa70C8691f0e44Dc420a5e53c168921Dc);
    // Ethereum : 0xdC035D45d973E3EC169d2276DDab16f1e407384F
    // Base : 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc
    // Arbi : 0x6491c05a82219b8d1479057361ff1654749b876b

    IERC20 public USDE = IERC20(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34);
    // Ethereum : 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3
    // Base : 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34
    // Arbi : 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34

    IERC20 public CRVUSD = IERC20(0x417Ac0e078398C154EdFadD9Ef675d30Be60Af93);
    // Ethereum : 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E
    // Polygon : 0xc4ce1d6f5d98d65ee25cf85e9f2e9dcfee6cb5d6
    // Base : 0x417Ac0e078398C154EdFadD9Ef675d30Be60Af93
    // Arbi : 0x498bf2b1e120fed3ad3d42ea2165e9b73f99c1e5

    // IERC20 public FRAX = IERC20(0x80Eede496655FB9047dd39d9f418d5483ED600df);
    // Ethereum : 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29
    // Polygon : 0x80Eede496655FB9047dd39d9f418d5483ED600df
    // Arbi : 0x80Eede496655FB9047dd39d9f418d5483ED600df
    
    address[] public VAULTS;
    IERC4626 public gauntletWETHvault = IERC4626(0x27D8c7273fd3fcC6956a0B370cE5Fd4A7fc65c18);
    // ^ L1 Ethereum : 0x4881Ef0BF6d2365D3dd6499ccd7532bcdBCE0658
    // Base : 
  
    IERC4626 public USDCvault = IERC4626(0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183);
    // ^ L1 Ethereum : 0xBEeFFF209270748ddd194831b3fa287a5386f5bC
    
    IERC4626 public sUSDSvault = IERC4626(0xB17B070A56043e1a5a1AB7443AfAFDEbcc1168D7);
    // ^ only on Base

    // 0xBEef03f0BF3cb2e348393008a826538AaDD7d183
    // wUSDM

    // IERC4626 public smokehouseUSDTvault = IERC4626(0xA0804346780b4c2e3bE118ac957D1DB82F9d7484);
    // ^ L1 Ethereum : 

    // unlike other vaults, SGHO has its own interface (similar to ERC4626)
    // IERC20 public SGHO = IERC20(0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d);
    // ^ L1 Ethereum :

    // IERC4626 public SDAI = IERC4626(0x83F20F44975D03b1b09e64809B757c47f942BEeA);
    // ^ L1 Ethereum :
    
    // IERC4626 public SFRAX = IERC4626(0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6);
    // ^ L1 Ethereum : 
    // IERC20 public SFRAX = IERC20(0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0);
    // ^ Polygon : 
    // Arbi : 0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0

    IERC4626 public SUSDS = IERC4626(0x5875eEE11Cf8398102FdAd704C9E96607675467a);
    // Arbi : 0xdDb46999F8891663a8F2828d25298f70416d7610
    
    IERC4626 public SUSDE = IERC4626(0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2);
    // Arbi : 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2

    IERC4626 public SCRVUSD = IERC4626(0x646A737B9B6024e49f5908762B3fF73e65B5160c);
    // Arbi : 0xEfB6601Df148677A338720156E2eFd3c5Ba8809d

    IPoolManager public poolManager = IPoolManager(0x498581ff718922c3f8e6a244956af099b2652b2b);
    // Ethereum : 0x000000000004444c5dc75cB358380D2e3dE08A90
    // Polygon : 0x67366782805870060151383f4bbff9dab53e5cd6
    // Unichain : 0x1f98400000000000000000000000000000000004
    // Arbi : 0x360e68faccca8ca495c1b759fd9eee466db9fb32
    // Base : 0x498581ff718922c3f8e6a244956af099b2652b2b
  
    ISwapRouter public V3router = ISwapRouter(0x2626664c2603336E57B271c5C0b26F421741e481);
    // Ethereum : 0xE592427A0AEce92De3Edee1F18E0157C05861564
    // Polygon : 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
    // Unichain : 0xd1AAE39293221B77B0C71fBD6dCb7Ea29Bb5B166
    // Arbi : 0xE592427A0AEce92De3Edee1F18E0157C05861564
    // Base : 0x2626664c2603336E57B271c5C0b26F421741e481

    IUniswapV3Pool public V3pool = IUniswapV3Pool(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59);
    // Ethereum : 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640
    // Polygon : 0x45dDa9cb7c25131DF268515131f647d726f50608
    // Unichain : 0xBeAD5792bB6C299AB11Eaa425aC3fE11ebA47b3B
    // Arbi : 0xc6962004f452be9203591991d15f6b388e09e8d0
    // Base : 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59

    // Deploy contracts (Base)
    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        /*
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
        
        V4router.setup(address(QUID),
            address(AUX), address(V3pool));
        
        USDC.transfer(address(AUX), 1000000);
        AUX.setQuid{value: 1 wei}(address(QUID));
        */
        
        // TODO == TEMPORARY - dummy contracts for testing
        console.log("Deploying dummy contracts for testing...");
        
        // Deploy dummy WETH
        DummyWETH dummyWETH = new DummyWETH();
        console.log("Dummy WETH:", address(dummyWETH));
        
        // Deploy dummy Rover
        DummyRover V4router = new DummyRover();
        console.log("Dummy Rover:", address(V4router));
        
        // Deploy dummy Basket
        DummyBasket QUID = new DummyBasket(address(V4router));
        console.log("Dummy Basket:", address(QUID));
        
        // Deploy dummy Aux
        DummyAux AUX = new DummyAux(address(dummyWETH), address(QUID));
        console.log("Dummy Aux:", address(AUX));
        
        // Setup dummy connections
        V4router.setup(address(QUID), address(AUX), address(0));
        
        // Send some ETH to Aux for swaps
        payable(address(AUX)).transfer(10 ether);

        // Deploy Settlement
        Settlement settlement = new Settlement();
        settlement.initialize(address(QUID), address(0));
        
        // Deploy AuctionFactory
        AuctionFactory factory = new AuctionFactory(
            address(settlement),
            address(V4router),
            address(AUX),
            address(QUID)
        );
        
        // Deploy AuctionHelpers
        AuctionHelpers helpers = new AuctionHelpers(
            address(factory),
            address(settlement),
            address(QUID)
        );
        
        // Connect Settlement to Basket
        QUID.setSettlement(address(settlement));

        console.log("\n=== Deployment Summary ===");
        console.log("QUID (Dummy)", address(QUID));
        console.log("AUX (Dummy)", address(AUX));
        console.log("V4 (Dummy)", address(V4router));
        console.log("Settlement", address(settlement));
        console.log("Factory", address(factory));
        console.log("Helpers", address(helpers));
        
        console.log("\n=== Test Instructions ===");
        console.log("1. Users automatically receive 1000 QUID when they:");
        console.log("   - Place their first bet (via Auction)");
        console.log("   - Propose a settlement (via Settlement transferFrom)");
        console.log("2. No need to manually call faucet()");
        console.log("3. This enables jury participation automatically");
    
        vm.stopBroadcast();
    }
    
    function _saveDeployment(address factory, address registry, address helpers) internal {
        string memory json = string(abi.encodePacked(
            '{\n',
            '  "factory": "', addressToString(factory), '",\n',
            '  "registry": "', addressToString(registry), '",\n', 
            '  "helpers": "', addressToString(helpers), '",\n',
            '  "chainId": ', uint2str(block.chainid), ',\n',
            '  "blockNumber": ', uint2str(block.number), '\n',
            '}'
        ));
        
        string memory filename = string(abi.encodePacked(
            "deployments/",
            uint2str(block.chainid),
            "-deployment.json"
        ));
        
        vm.writeFile(filename, json);
        console.log("Deployment saved to:", filename);
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