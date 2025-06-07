// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {Auxiliary} from "../src/Auxiliary.sol";
import {Router} from "../src/Router.sol";
import {Basket} from "../src/Basket.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {ISwapRouter} from "../src/imports/v3/ISwapRouter.sol"; // < L1 and Arbi
// import {IV3SwapRouter as ISwapRouter} from "../src/imports/V3/IV3SwapRouter.sol";

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

    // Deploy contracts to Polygon
    function run() public {
        // exclude the ones not available on Polygon
        STABLECOINS = [ address(USDC), // address(USDT),
            address(DAI), address(USDS), address(USDE), 
            address(CRVUSD), address(SUSDE), 
            address(SCRVUSD), /* address(GHO),
            address(FRAX), address(SFRAX) */
        ]; // vaults are only relevant for L1
         VAULTS = [
            address(USDCvault), address(sUSDSvault)
            // address(smokehouseUSDTvault),
            // address(SFRAX), address(SGHO),
            // address(SDAI), 
        ]; 
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        Router V4router = new Router(poolManager);
        
        Auxiliary AUX = new Auxiliary(address(V4router),
            address(V3pool), address(V3router),
            address(gauntletWETHvault), aavePool);
       
        Basket QUID = new Basket(address(V4router),
            address(AUX), STABLECOINS, VAULTS);

        V4router.setup(address(QUID),
        address(AUX), address(V3pool));
        
        USDC.transfer(address(AUX), 1000000);
        AUX.setQuid{value: 1 wei}(address(QUID));   

        console.log("QUID", address(QUID));
        console.log("AUX", address(AUX));
        console.log("V4", address(V4router));
    
        vm.stopBroadcast();
    }
}
