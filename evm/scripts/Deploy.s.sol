// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {AuxV3 as Aux} from "../src/AuxV3.sol";
import {Router} from "../src/Router.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IV3SwapRouter as ISwapRouter} from "../src/imports/v3/IV3SwapRouter.sol";
import {INonfungiblePositionManager} from "../src/imports/v3/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";

// ============ Enhanced Dummy Contracts for Testing ============

// Comprehensive Dummy Basket that works with Settlement
contract DummyBasket {
    mapping(address => uint) public totalBalances;
    mapping(address => mapping(uint => uint)) public balances;
    mapping(uint => address) public holders;
    mapping(address => uint) public holder_to_id;
    mapping(address => bool) public hasClaimed;
    mapping(address => mapping(address => uint)) public allowance;
    
    address public V4;
    address public SET;
    uint public latest_holder = 0;
    uint public totalSupply;
    
    string public name = "QUID";
    string public symbol = "QD";
    uint8 public decimals = 18;
    
    constructor(address _v4) {
        V4 = _v4;
    }
    
    function _autoFaucet(address user) internal {
        if (!hasClaimed[user] && totalBalances[user] < 100e18) {
            totalBalances[user] = 1000e18;
            totalSupply += 1000e18;
            hasClaimed[user] = true;
            
            if (holder_to_id[user] == 0) {
                latest_holder++;
                holders[latest_holder] = user;
                holder_to_id[user] = latest_holder;
            }
        }
    }
    
    function transferFrom(address from, address to, uint amount) external returns (bool) {
        // Auto-faucet for testing
        if (from != address(0) && totalBalances[from] < amount) {
            _autoFaucet(from);
        }
        
        // Check allowance if not from sender
        if (from != msg.sender) {
            require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        
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
    
    function approve(address spender, uint amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function mint(address to, uint amount, address, uint) external {
        totalBalances[to] += amount;
        totalSupply += amount;
        
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
            totalSupply += amount;
            return amount;
        }
        // Mock conversion rate for other tokens
        return amount * 1e12;
    }
    
    function take(address who, uint amount, address token, bool) external returns (uint) {
        if (token == address(this)) {
            require(totalBalances[who] >= amount, "Insufficient balance");
            totalBalances[who] -= amount;
            totalSupply -= amount;
            return amount;
        }
        return amount;
    }
    
    function turn(address from, uint value) external returns (uint) {
        require(totalBalances[from] >= value, "Insufficient balance");
        totalBalances[from] -= value;
        totalSupply -= value;
        return value;
    }
    
    function setSettlement(address _settlement) external {
        SET = _settlement;
    }
    
    function faucet() external {
        require(!hasClaimed[msg.sender], "Already claimed");
        totalBalances[msg.sender] += 1000e18;
        totalSupply += 1000e18;
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
    
    // Add methods needed by Settlement
    function isStable(address) external pure returns (bool) {
        return true;
    }
    
    function isVault(address) external pure returns (bool) {
        return false;
    }
}

// Enhanced Aux implementation with proper integration
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
        uint usdAmount = (ethAmount * 3000e18) / 1e18;
        
        // Mint QUID to the contract first, then to user
        // This simulates the actual swap process
        DummyBasket(basket).mint(to, usdAmount, address(0), 0);
        
        return usdAmount;
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
        require(address(this).balance >= amount, "Insufficient ETH");
        payable(to).transfer(amount);
    }
    
    function putETH(uint) external pure returns (uint) {
        return 0;
    }
    
    function token1isWETH() external pure returns (bool) {
        return true;
    }
    
    receive() external payable {}
}

// Minimal Rover implementation
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
    
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract Deploy is Script {
    address[] public STABLECOINS;

    address public wS = 0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38;
    
    // IPoolAddressesProvider
    address public aaveAddr = 0x5C2e738F6E27bCE0F7558051Bf90605dD6176900;
    // Ethereum : 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e
    // Polygon : 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb
    // Unichain : 
    // Arbi : 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb
    // Base : 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D
    // Sonic : 0x5C2e738F6E27bCE0F7558051Bf90605dD6176900

    // IUiPoolDataProvider
    address public aaveData = 0x9005A69fE088680827f292e8aE885Be4BE1beb2f;
    // Ethereum : 0x3F78BBD206e4D3c504Eb854232EdA7e47E9Fd8FC
    // Polygon : 0x68100bD5345eA474D93577127C11F39FF8463e93
    // Unichain :
    // Arbi : 0x5c5228aC8BC1528482514aF3e27E692495148717
    // Base : 0x68100bD5345eA474D93577127C11F39FF8463e93
    // Sonic : 0x9005A69fE088680827f292e8aE885Be4BE1beb2f

    // IPool
    address public aavePool = 0x5362dBb1e601abF3a4c14c22ffEdA64042E5eAA3;
    // Ethereum : 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
    // Polygon : 0x794a61358D6845594F94dc1DB02A252b5b4814aD
    // Unichain : 
    // Arbi : 0x794a61358D6845594F94dc1DB02A252b5b4814aD
    // Base : 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5
    // Sonic : 0x5362dBb1e601abF3a4c14c22ffEdA64042E5eAA3

    // IERC20 public GHO = IERC20();
    // Ethereum : 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f
    // Arbi : 0x7dfF72693f6A4149b17e7C6314655f6A9F7c8B33

    IERC20 public USDT = IERC20(0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2);
    // Ethereum : 0xdAC17F958D2ee523a2206206994597C13D831ec7
    // Polygon : 0xc2132D05D31c914a87C6611C10748AEb04B58e8F
    // Unichain : 0x9151434b16b9763660705744891fA906F660EcC5
    // Arbi : 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9
    // Base : 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2

    IERC20 public USDC = IERC20(0x29219dd400f2Bf60E5a23d13Be72B486D4038894);
    // Ethereum : 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    // Polygon : 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359
    // Unichain : 0x078D782b760474a361dDA0AF3839290b0EF57AD6
    // Arbi : 0xaf88d065e77c8cC2239327C5EDb3A432268e5831
    // Base : 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
    // Sonic ; 0x29219dd400f2Bf60E5a23d13Be72B486D4038894

    IERC20 public DAI = IERC20(0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb);
    // Ethereum : 0x6B175474E89094C44Da98b954EedeAC495271d0F
    // Base : 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb
    // Arbi : 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1

    IERC20 public USDS = IERC20(0x820C137fa70C8691f0e44Dc420a5e53c168921Dc);
    // Ethereum : 0xdC035D45d973E3EC169d2276DDab16f1e407384F
    // Unichain : 0x7E10036Acc4B56d4dFCa3b77810356CE52313F9C
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
    // Base : 0x27D8c7273fd3fcC6956a0B370cE5Fd4A7fc65c18
    // Unichain : 0x830898200F0E8Be8Dc1C9A836f4AB29ECEdf76eb
    // Polygon : 0xF5C81d25ee174d83f1FD202cA94AE6070d073cCF
    // Arbitrum : 0x0623a67D69bB2F59D266897A15dC1509d291D631
  
    IERC4626 public USDCvault = IERC4626(0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183);
    // ^ L1 Ethereum : 0xBEeFFF209270748ddd194831b3fa287a5386f5bC
    // Base : 0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61
    // Unichain : 0x38f4f3B6533de0023b9DCd04b02F93d36ad1F9f9
    // Polygon : 0x781FB7F6d845E3bE129289833b04d43Aa8558c42
    // Arbitrum : 0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed
    
    IERC4626 public sUSDSvault = IERC4626(0xB17B070A56043e1a5a1AB7443AfAFDEbcc1168D7);
    // ^ only on Base
    // Uni

    IERC4626 public smokehouseUSDTvault = IERC4626(0xA0804346780b4c2e3bE118ac957D1DB82F9d7484);
    // ^ L1 Ethereum : 
    // Unichain : 0x89849B6e57e1c61e447257242bDa97c70FA99b6b
    // Polygon : 0xfD06859A671C21497a2EB8C5E3fEA48De924D6c8
    // Base : 
    // Arbitrum : 0x4739E2c293bDCD835829aA7c5d7fBdee93565D1a

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
    // Ethereum: 0xa3931d71877c0e7a3148cb7eb4463524fec27fbd 
    // Base: 0x5875eEE11Cf8398102FdAd704C9E96607675467a
    // Arbi : 0xdDb46999F8891663a8F2828d25298f70416d7610
    // Unichain : 0xA06b10Db9F390990364A3984C04FaDf1c13691b5

    IERC4626 public SUSDE = IERC4626(0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2);
    // Arbi : 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2

    IERC4626 public SCRVUSD = IERC4626(0x646A737B9B6024e49f5908762B3fF73e65B5160c);
    // Arbi : 0xEfB6601Df148677A338720156E2eFd3c5Ba8809d

    // https://gov.uniswap.org/t/rfc-deploy-uniswap-v3-on-sonic-formerly-fantom/25024
    INonfungiblePositionManager public nfpm = INonfungiblePositionManager(0x743E03cceB4af2efA3CC76838f6E8B50B63F184c);
    IPoolManager public poolManager = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    // Ethereum : 0x000000000004444c5dc75cB358380D2e3dE08A90
    // Polygon : 0x67366782805870060151383f4bbff9dab53e5cd6
    // Unichain : 0x1f98400000000000000000000000000000000004
    // Arbi : 0x360e68faccca8ca495c1b759fd9eee466db9fb32
    // Base : 0x498581ff718922c3f8e6a244956af099b2652b2b
  
    ISwapRouter public V3router = ISwapRouter(0xaa52bB8110fE38D0d2d2AF0B85C3A3eE622CA455);
    // Ethereum : 0xE592427A0AEce92De3Edee1F18E0157C05861564
    // Polygon : 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
    // Unichain : 0xd1AAE39293221B77B0C71fBD6dCb7Ea29Bb5B166
    // Arbi : 0xE592427A0AEce92De3Edee1F18E0157C05861564
    // Base : 0x2626664c2603336E57B271c5C0b26F421741e481
    // Sonic : 0xaa52bB8110fE38D0d2d2AF0B85C3A3eE622CA455

    IUniswapV3Pool public V3pool = IUniswapV3Pool(0xEcb04e075503Bd678241f00155AbCB532c0a15Eb);
    // Ethereum : 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640
    // Polygon : 0x45dDa9cb7c25131DF268515131f647d726f50608
    // Unichain : 0xBeAD5792bB6C299AB11Eaa425aC3fE11ebA47b3B
    // Arbi : 0xc6962004f452be9203591991d15f6b388e09e8d0
    // Base : 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59
    // Sonic : 0xecb04e075503bd678241f00155abcb532c0a15eb
    
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

       /* COMMENTED OUT - Real production deployments - DO NOT DELETE
        Rover V4router = new Rover(poolManager);
        Router V3 = new Router(address(weth), 
            address(USDC), address(nfpm), address(V3pool), 
            address(V3router) // newer interface on L1 and Arbitrum
        );
        
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

        // TODO send WETH and USDC to AUXv3 for linking AAVE

        // token1 is USDC 0x29219dd400f2Bf60E5a23d13Be72B486D4038894
        // token0 is wS (wrapped msg.value) 0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38
        // ^ uses the WETH contract with deposit and withdrawTo / withdraw

        V4router.setup(address(QUID),
            address(AUX), address(V3pool));
        
        USDC.transfer(address(AUX), 1000000);
        AUX.setQuid{value: 1 wei}(address(QUID));
        */

        Aux AUX = new Aux(aavePool, aaveData, aaveAddr);
        Router V3 = new Router(address(AUX), address(wS), 
            address(USDC), address(nfpm), address(V3pool), 
            address(V3router) // newer interface on L1 and Arbitrum
        );  AUX.setup(payable(address(V3)));

        console.log("AUX...", address(AUX));
        console.log("V3...", address(V3));
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