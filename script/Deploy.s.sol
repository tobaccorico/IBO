
pragma solidity 0.8.25;
import {Quid} from "../src/QD.sol";
import {MO} from "../src/MOulinette.sol";
import "lib/forge-std/src/console.sol";
import {Script} from "lib/forge-std/src/Script.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {ERC4626} from "lib/solmate/src/tokens/ERC4626.sol";
import {IUniswapV3Pool} from "../src/imports/IUniswapV3Pool.sol";
import {IMorpho, MarketParams} from "../src/imports/morpho/IMorpho.sol";
import {IUniswapV3Factory} from "../src/imports/IUniswapV3Factory.sol";
import {IERC4626} from "../src/imports/morpho/libraries/VaultLib.sol";
import {ISwapRouter} from "../src/imports/ISwapRouter.sol"; // TODO used for mainnet forking
import {AggregatorV3Interface} from "../src/imports/AggregatorV3Interface.sol";
// import {IV3SwapRouter as ISwapRouter} from "../src/imports/IV3SwapRouter.sol"; // used on Base and Taiko...
import {MorphoBalancesLib} from "../src/imports/morpho/libraries/MorphoBalancesLib.sol";
import {MorphoChainlinkOracleV2} from "../src/imports/morpho/MorphoChainlinkOracleV2.sol";
import {INonfungiblePositionManager} from "../src/imports/INonfungiblePositionManager.sol";
import {IMorphoChainlinkOracleV2Factory} from "../src/imports/morpho/IMorphoChainlinkOracleV2Factory.sol";
contract Deploy is Script {
    Quid public quid; 
    MO public moulinette;
    // ERC20 public M = ERC20();
    ERC20 public USDC = ERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831); 
    // = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) TODO Ethereum L1
    // Base : 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // Arbitrum : 0xaf88d065e77c8cc2239327c5edb3a432268e5831;
    // BNB (tether) : 0x55d398326f99059ff775485246999027b3197955
    
     // TODO no USDS on Arbitrum (nor SUSDS or SFRAX)
    ERC20 public USDS = ERC20(0x820C137fa70C8691f0e44Dc420a5e53c168921Dc);
    // = ERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F);
    ERC20 public SUSDS = ERC20(0x5875eEE11Cf8398102FdAd704C9E96607675467a);
    // = ERC4626(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
    
    ERC20 public DAI = ERC20(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);
    // = ERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    // Arbitrum : 0xda10009cbd5d07dd0cecc66161fc93d7c9000da1
    // Base : 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb
    
    // Same addresses on Base as on Arbitrum
    ERC20 public USDE = ERC20(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34); 
    // = ERC20(0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);
    ERC20 public SUSDE = ERC20(0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2); 
    // = ERC4626(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
    
    ERC20 public CRVUSD = ERC20(0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5);
    // ERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    // Arbitrum : 0x498bf2b1e120fed3ad3d42ea2165e9b73f99c1e5
    // Base : 0x417Ac0e078398C154EdFadD9Ef675d30Be60Af93
    ERC20 public SCRVUSD = ERC20(0xEfB6601Df148677A338720156E2eFd3c5Ba8809d);
    // ERC4626(0x0655977FEb2f289A4aB78af67BAB0d17aAb84367);
    // Arbitrum : 0xEfB6601Df148677A338720156E2eFd3c5Ba8809d
    // Base : 0x646A737B9B6024e49f5908762B3fF73e65B5160c

    // app.morpho.org/vault?vault=0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca&network=base
    ERC4626 public VAULT = ERC4626(0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca);
    // ERC4626(0xd63070114470f685b75B74D60EEc7c1113d33a3D); // TODO deploy L1
   
    ERC20 public FRAX = ERC20(0x17FC002b466eEc40DaE837Fc4bE5c67993ddBd6F); // Arbitrum
    // = ERC20(0x853d955aCEf822Db058eb8505911ED77F175b99e);
    // ERC4626 public SFRAX; // = ERC4626(0xA663B02CF0a4b149d2aD41910CB81e23e1c41c32);
    // ERC4626 public SDAI; // = ERC4626(0x83F20F44975D03b1b09e64809B757c47f942BEeA);

    // LZ
    // Unichain : 0xb8815f3f882614048CbE201a67eF9c6F10fe5035
    // Sepolia : 0x6EDCE65403992e310A62460808c4b910D972f10f
    // Arbitrum : 
    // Base : 
    
    address public IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    // 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC // TODO deploy L1
    // TODO re-deploy on Aribtrum after Morpho is deployed there
    IMorpho public morpho = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb); // same address on L1 as well as Base
    // IMorphoChainlinkOracleV2Factory public morphoFactory = IMorphoChainlinkOracleV2Factory(0x2DC205F24BCb6B311E5cdf0745B0741648Aebd3d);
    bytes32 public ID = 0xb1c74e62cbe3721a37040c248e481d175cffb45c686b5b423cd446a063261431; // TODO deploy market on Arbitrum

    IUniswapV3Factory public factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    // Base : 0x33128a8fC17869897dcE68Ed026d694621f6FDfD // TODO deploy QD<>WETH and QD<>USDC
    // Unichain : 0x1F98431c8aD98523631AE4a59f267346ea31F984
    // Arbitrum : 0x1F98431c8aD98523631AE4a59f267346ea31F984
    // BNB : 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7
    ISwapRouter public router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    // Base : 0x2626664c2603336E57B271c5C0b26F421741e481
    // Arbitrum : 0xE592427A0AEce92De3Edee1F18E0157C05861564
    // Unichain : 0xd1AAE39293221B77B0C71fBD6dCb7Ea29Bb5B166
    // Sepolia : 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E
    // Taiko : 0xdD489C75be1039ec7d843A6aC2Fd658350B067Cf
    // BNB : 0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2
    INonfungiblePositionManager public nfpm = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    // Base : 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1
    // Arbitrum : 0xC36442b4a4522E871399CD717aBDD847Ab11FE88
    // Unichain : 0xB7F724d6dDDFd008eFf5cc2834edDE5F9eF0d075
    // Sepolia : 0x1238536071E1c677A632429e3655c799b22cDA52
    // Taiko : 0x8B3c541c30f9b29560f56B9E44b59718916B69EF
    // BNB : 0x7b8A01B39D58278b5DE7e48c8449c9f4F5170613
    IUniswapV3Pool public pool = IUniswapV3Pool(0xC6962004f452bE9203591991D15f6b388e09E8D0);
    // Base : 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59
    // Arbitrum : 0xc6962004f452be9203591991d15f6b388e09e8d0
    // Unichain : 0xBeAD5792bB6C299AB11Eaa425aC3fE11ebA47b3B
    // Sepolia : 0x3289680dD4d6C10bb19b899729cda5eEF58AEfF1
    // Taiko : 0xE47a76e15a6F3976c8Dc070B3a54C7F7083D668B
    // BNB : 0x36696169c63e42cd08ce11f5deebbcebae652050
    WETH public weth = WETH(payable(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1));
    // Arbitrum : 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
    // Unichain (and Base) : 0x4200000000000000000000000000000000000006
    // Sepolia : 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
    // Taiko : 0xA51894664A773981C6C112C43ce576f315d5b1B6
    // BNB : 0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c

    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
       
        // USDC = new mockToken(6);
        // USDC.mint();
        // weth.deposit{value: 2 ether}();

        // DAI = new mockToken(18);
        // SDAI = new mockVault(DAI);
        // FRAX = new mockToken(18);
        // SFRAX = new mockVault(FRAX);
        // USDE = new mockToken(18);
        // SUSDE = new mockVault(USDE);

        // factory.getPool(0x31d0220469e10c4E71834a79b1f276d740d3768F, address(weth), 500);
        // https://etherscan.io/address/0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640#readContract#F11
        // pool.initialize(1321184935443179556068722157521329);
        // USDC.approve(address(nfpm), type(uint256).max);
        // weth.approve(address(nfpm), type(uint256).max);

        // TODO Arbitrum
        /* ==== Deploy a Morpho Oracle for SUSDE and market where that's collateral ==== 
        uses the oracle factory contract, as well as a create market on the singleton */
        /*
        IERC4626 baseVault = IERC4626(address(0)); // IERC4626(address(SUSDE));
        IERC4626 quoteVault = IERC4626(address(0)); // IERC4626(address(USDC));
        AggregatorV3Interface baseFeed1 = AggregatorV3Interface(
                     0xdEd37FC1400B8022968441356f771639ad1B23aA);
        
        AggregatorV3Interface baseFeed2 = AggregatorV3Interface(address(0));
        AggregatorV3Interface quoteFeed1 = AggregatorV3Interface(address(0));
        AggregatorV3Interface quoteFeed2 = AggregatorV3Interface(address(0));
        uint baseVaultConversionSample = 1;
        uint quoteVaultConversionSample = 1;
        uint quoteTokenDecimals = 18;
        uint baseTokenDecimals = 18;
        bytes32 salt = bytes32(0);

        MorphoChainlinkOracleV2 deployedOracle = morphoFactory.createMorphoChainlinkOracleV2(
            baseVault, baseVaultConversionSample, baseFeed1, baseFeed2, baseTokenDecimals,
            quoteVault, quoteVaultConversionSample, quoteFeed1, quoteFeed2, quoteTokenDecimals,
            salt
        );
        MarketParams memory params = MarketParams({
            loanToken: address(USDC), 
            collateralToken: address(SUSDE),
            oracle: address(deployedOracle),
            irm: IRM, lltv: 915000000000000000 
        });
        morpho.createMarket(params);
        */

        moulinette = new MO(// Moulinette 
            address(weth), address(USDC),
            address(nfpm), address(pool), 
            address(router) // newer interface on L1 and Arbitrum
        );
        // nfpm.mint(INonfungiblePositionManager.MintParams({ 
        //     token0: address(USDC), token1: address(weth),
        //     fee: 500, tickLower: -887_200, tickUpper: 887_200,
        //     amount0Desired: 9000000000, amount1Desired: 2 ether,
        //     amount0Min: 0, amount1Min: 0, 
        //     recipient: 0xBE80666aA26710c2b2c3FD40c6663A013600D9b6,
        //     deadline: block.timestamp + 3600
        // }));
       
        quid = new Quid(address(moulinette), // TODO deploy Morpho
            address(USDC), /* address(VAULT), ID, */ // vault on ARB
            address(USDE), address(SUSDE),
            address(FRAX), /* address (SFRAX),
            address (SDAI), */ address(DAI), 
            // address(USDS), address(SUSDS),
            address(CRVUSD), address(SCRVUSD)); 
        
        // pool = IUniswapV3Pool(factory.createPool(
        //     address(quid), address(M), 500));
        // create pool QD<>M // TODO M^0
        // "Bond," M says, "this may be 
        // too much for a blunt instrument
        // to understand, but 
        moulinette.setQuid( 
            address(quid)); 
            // go hand in hand"
            
        // moulinette.set_price_eth(false, true); 
        // TODO remove this, only for testing!
        
        console.log("Quid address...", address(quid));
        // console.log("USDe address...", address(DAI));
        // console.log("sUSDe address...", address(SDAI));
        console.log("Moulinette address...", address(moulinette));
    
        vm.stopBroadcast();
    }
}
