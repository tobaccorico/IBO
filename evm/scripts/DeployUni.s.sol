// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";
import "forge-std/Script.sol";

import {Vogue} from "../src/Vogue.sol";
import {VogueCore} from "../src/VogueCore.sol";
import {Basket} from "../src/Basket.sol";
import {Proof} from "../src/Proof.sol";
import {Jury} from "../src/Jury.sol";
import {Court} from "../src/Court.sol";
import {Rover} from "../src/Rover.sol";
import {AuxUni as Aux} from "../src/AuxUni.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {INonfungiblePositionManager} from "../src/imports/v3/INonfungiblePositionManager.sol";
import {IV3SwapRouter as ISwapRouter} from "../src/imports/v3/IV3SwapRouter.sol";
import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";

/**
 * @title DeployUnichain
 * @notice Deployment script for SAFTA protocol on Unichain
 * @dev Key differences from other chains:
 *      - Only 4 stables: USDC, USDT, USDS, sUSDS
 *      - 2 Morpho vaults (USDC, USDT) + 2 direct holdings (USDS, sUSDS)
 *      - sUSDS uses DSR oracle for pricing
 *      - NO AMP/Rover (leverage features disabled)
 *      - NO GHO, DAI, FRAX, USDE, CRVUSD, etc.
 */
contract Deploy is Script {
    address[] public STABLES;
    address[] public VAULTS;

    // ═══════════════════════════════════════════════════════════════
    //                      UNICHAIN ADDRESSES
    // ═══════════════════════════════════════════════════════════════

    INonfungiblePositionManager public nfpm = INonfungiblePositionManager(0x943e6e07a7E8E791dAFC44083e54041D743C46E9);

    // Uniswap V4 PoolManager
    IPoolManager public poolManager = IPoolManager(0x1F98400000000000000000000000000000000004);

    // Uniswap V3 Router (SwapRouter02 style)
    ISwapRouter public v3Router = ISwapRouter(0x73855d06DE49d0fe4A9c42636Ba96c62da12FF9C);

    // Uniswap V3 WETH/USDC Pool (for TWAP)
    IUniswapV3Pool public wethV3Pool = IUniswapV3Pool(0x8927058918e3CFf6F55EfE45A58db1be1F069E49);

    // ═══════════════════════════════════════════════════════════════
    //                        STABLECOINS
    // ═══════════════════════════════════════════════════════════════

    // TODO: Update with actual Unichain addresses.
    IERC20 public WETH = IERC20(0x4200000000000000000000000000000000000006);
    IERC20 public USDC = IERC20(0x078D782b760474a361dDA0AF3839290b0EF57AD6);   // 6 decimals
    IERC20 public USDT = IERC20(0x9151434b16b9763660705744891fA906F660EcC5);   // 6 decimals
    IERC20 public USDS = IERC20(0x7E10036Acc4B56d4dFCa3b77810356CE52313F9C);   // 18 decimals
    IERC20 public sUSDS = IERC20(0xA06b10Db9F390990364A3984C04FaDf1c13691b5);  // 18 decimals
    IERC20 public FRAX = IERC20(0x80Eede496655FB9047dd39d9f418d5483ED600df);  // 18 decimals

    // ═══════════════════════════════════════════════════════════════
    //                          VAULTS
    // ═══════════════════════════════════════════════════════════════

    // Gauntlet WETH Vault (for Vogue ETH deposits)
    // TODO: Update with actual Unichain vault address
    IERC4626 public wethVault = IERC4626(0x830898200F0E8Be8Dc1C9A836f4AB29ECEdf76eb);

    // Morpho USDC Vault
    // TODO: Update with actual Unichain vault address
    IERC4626 public usdcVault = IERC4626(0x38f4f3B6533de0023b9DCd04b02F93d36ad1F9f9);

    // Morpho USDT Vault
    // TODO: Update with actual Unichain vault address
    IERC4626 public usdtVault = IERC4626(0x89849B6e57e1c61e447257242bDa97c70FA99b6b);

    // ═══════════════════════════════════════════════════════════════
    //                    NOT AVAILABLE ON UNICHAIN
    // ═══════════════════════════════════════════════════════════════
    // - GHO, DAI, FRAX, USDE, CRVUSD
    // - Staked tokens other than sUSDS (no SFRAX, SUSDE, SCRVUSD)
    // - AMP/Rover (no leverage)

    Proof public proof;
    Jury public jury;
    Court public court;
    Basket public QUID;
    Rover public V3;

    VogueCore public CORE;
    Vogue public V4;
    Aux public AUX;

    function run() public {
        // Handle private key (supports both hex and raw formats)
        string memory privateKeyStr = vm.envString("PRIVATE_KEY");
        uint256 deployerPrivateKey;
        if (bytes(privateKeyStr).length > 2 &&
            bytes(privateKeyStr)[0] == 0x30 &&
            bytes(privateKeyStr)[1] == 0x78) {
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        } else {
            deployerPrivateKey = vm.parseUint(
                string(abi.encodePacked("0x", privateKeyStr)));
        }

        /**
         * STABLES ARRAY STRUCTURE FOR UNICHAIN:
         * ======================================
         * Index 0: USDC  -> Morpho vault (6 decimals)
         * Index 1: USDT  -> Morpho vault (6 decimals)
         * Index 2: USDS  -> Direct holding (18 decimals)
         * Index 3: sUSDS -> Direct holding with DSR oracle (18 decimals)
         * Index 4: FRAX ->
         *
         * toIndex mapping will be:
         * USDC  -> 1
         * USDT  -> 2
         * USDS  -> 3
         * sUSDS -> 4
         * FRAX -> 5
         */
        STABLES = [
            address(USDC),   // Index 0: Morpho vault (6 dec)
            address(USDT),   // Index 1: Morpho vault (6 dec)
            address(USDS),   // Index 2: Direct holding (18 dec)
            address(sUSDS),  // Index 3: Direct holding + DSR oracle (18 dec)
            address(FRAX)
        ];

        VAULTS = [
            address(usdcVault),  // For USDC (index 0)
            address(usdtVault)   // For USDT (index 1)
        ];

        vm.startBroadcast(deployerPrivateKey);

        address deployer = vm.addr(deployerPrivateKey);
        console.log("===================================================");
        console.log("         SAFTA UNICHAIN DEPLOYMENT");
        console.log("===================================================");
        console.log("Deployer:", deployer);
        console.log("");

        // ═══════════════════════════════════════════════════════════
        //                    DEPLOY CONTRACTS
        // ═══════════════════════════════════════════════════════════

        // 1. Deploy Vogue (LP management with ERC4626 wethVault)
        console.log("[1/6] Deploying Vogue...");
        V4 = new Vogue(address(wethVault));
        console.log("      Vogue:", address(V4));

        // 2. Deploy VogueCore (V4 pool hook logic)
        console.log("[2/6] Deploying VogueCore...");
        CORE = new VogueCore(poolManager);
        console.log("      VogueCore:", address(CORE));

        V3 = new Rover(address(0), address(WETH),
            address(USDC), address(nfpm),
            address(wethV3Pool),
            address(v3Router));

        // 3. Deploy AuxUnichain (no AMP, no Rover)
        console.log("[3/6] Deploying AuxUnichain...");
        AUX = new Aux(
            address(V4),
            address(CORE),
            address(wethVault),
            address(0),              // _amp: No AMP
            address(0), // no aave
            address(wethV3Pool),     // _v3poolWETH: For TWAP
            address(v3Router),       // _v3router: For swaps
            address(V3),
            STABLES,
            VAULTS
        );
        console.log("      AuxUnichain:", address(AUX));

        // 4. Deploy Basket (QD stablecoin token)
        console.log("[4/6] Deploying Basket...");
        QUID = new Basket(address(V4), address(AUX));
        console.log("      Basket:", address(QUID));

        // 5. Deploy Jury, Proof, Court
        console.log("[5/6] Deploying Jury/Proof/Court...");
        jury = new Jury(address(QUID));
        proof = new Proof(address(QUID));
        court = new Court(
            address(QUID),
            address(jury),
            address(proof)
        );
        console.log("      Jury:", address(jury));
        console.log("      Proof:", address(proof));
        console.log("      Court:", address(court));

        // ═══════════════════════════════════════════════════════════
        //                   SETUP CONNECTIONS
        // ═══════════════════════════════════════════════════════════

        console.log("");
        console.log("[6/6] Setting up contract connections...");

        // Connect VogueCore
        CORE.setup(address(V4), address(AUX), address(wethV3Pool));
        console.log("      CORE.setup() complete");

        // Connect Vogue
        V4.setup(address(QUID), address(AUX), address(CORE));
        console.log("      V4.setup() complete");

        // Connect Jury/Proof/Court
        jury.setup(address(court), address(proof));
        proof.setCourt(address(court));
        proof.setJury(address(jury));
        console.log("      Jury/Proof/Court setup complete");

        // Connect Aux to Basket and Jury/Court
        AUX.setQuid(address(QUID), address(jury), address(court));
        V3.setAux(address(AUX));

        console.log("      AUX.setQuid() complete");

        // ═══════════════════════════════════════════════════════════
        //                   DEPLOYMENT SUMMARY
        // ═══════════════════════════════════════════════════════════

        console.log("");
        console.log("===================================================");
        console.log("         DEPLOYMENT COMPLETE");
        console.log("===================================================");
        console.log("");
        console.log("Contract Addresses:");
        console.log("  Vogue:      ", address(V4));
        console.log("  VogueCore:  ", address(CORE));
        console.log("  Aux:        ", address(AUX));
        console.log("  Basket (QD):", address(QUID));
        console.log("  Jury:       ", address(jury));
        console.log("  Proof:      ", address(proof));
        console.log("  Court:      ", address(court));
        console.log("");
        console.log("External Dependencies:");
        console.log("  PoolManager:", address(poolManager));
        console.log("  V3 Router:  ", address(v3Router));
        console.log("  V3 Pool:    ", address(wethV3Pool));
        console.log("  WETH Vault: ", address(wethVault));
        console.log("");
        console.log("Stables Configured:");
        console.log("  [0] USDC:  ", address(USDC), " -> Vault:", address(usdcVault));
        console.log("  [1] USDT:  ", address(USDT), " -> Vault:", address(usdtVault));
        console.log("  [2] USDS:  ", address(USDS), " -> Direct");
        console.log("  [3] sUSDS: ", address(sUSDS), " -> Direct + DSR Oracle");
        console.log("");
        console.log("Features DISABLED on Unichain:");
        console.log("  - GHO, DAI, FRAX, USDE, CRVUSD stables");
        console.log("  - Staked tokens (SFRAX, SUSDE, SCRVUSD)");
        console.log("  - Leverage (AMP/Rover not deployed)");
        console.log("===================================================");

        vm.stopBroadcast();
    }
}
