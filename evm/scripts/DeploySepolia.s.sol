// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";

import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IV3SwapRouter as ISwapRouter} from "../src/imports/v3/IV3SwapRouter.sol";
import {INonfungiblePositionManager} from "../src/imports/v3/INonfungiblePositionManager.sol";

import {Aux} from "../src/Aux.sol";
import {Amp} from "../src/Amp.sol";
import {VogueArb as Vogue} from "../src/L2/VogueArb.sol";
import {Rover} from "../src/Rover.sol";
import {Basket} from "../src/Basket.sol";
import {BasketLib} from "../src/BasketLib.sol";
import {VogueCore} from "../src/VogueCore.sol";
import {Types} from "../src/imports/Types.sol";
import {MessageCodec} from "../src/imports/MessageCodec.sol";
import {Proof} from "../src/Proof.sol";
import {Jury} from "../src/Jury.sol";
import {Court} from "../src/Court.sol";

import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

// forge script scripts/DeployL1.s.sol:Deploy --rpc-url mainnet --broadcast --verify
// If verification fails during deployment (network issues, etc.), you can retry later:
// forge script scripts/DeployL1.s.sol:Deploy --rpc-url mainnet --resume --verify

contract Deploy is Script {

    IERC20 public WETH = IERC20(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14);
    address public aavePool = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address public aaveData = 0x69529987FA4A075D0C00B0128fa848dc9ebbE9CE;
    address public aaveAddr = 0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A;

    IPoolManager public poolManager = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    INonfungiblePositionManager public nfpm = INonfungiblePositionManager(0x1238536071E1c677A632429e3655c799b22cDA52);
    ISwapRouter public V3router = ISwapRouter(0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E);
    IUniswapV3Pool public WETHv3pool = IUniswapV3Pool(0x9799b5edc1aa7d3fad350309b08df3f64914e244);

    IERC20 public USDC = IERC20(0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8);

    address[] public STABLECOINS;
    address[] public VAULTS;

    Proof public proof;
    Jury public jury;
    Court public court;
    Basket public QUID;

    VogueCore public CORE;
    Vogue public V4;
    Rover public V3;
    Aux public AUX;
    Amp public AMP;

    function run() public { // handle private key...
        string memory privateKeyStr = vm.envString(
                                     "PRIVATE_KEY");
        uint256 deployerPrivateKey;
        if (bytes(privateKeyStr).length > 2 &&
            bytes(privateKeyStr)[0] == 0x30 &&
            bytes(privateKeyStr)[1] == 0x78) {
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        } else {
            deployerPrivateKey = vm.parseUint(
                string(abi.encodePacked("0x",
                          privateKeyStr)));
        }

        STABLECOINS = [
            address(USDC), address(USDT)
        ];
        VAULTS = [
            address(0),
            address(0)
        ];

        vm.startBroadcast(deployerPrivateKey);

        AMP = new Amp(aavePool, aaveData, aaveAddr);
        V3 = new Rover(address(AMP), address(WETH),
            address(USDC), address(nfpm),
            address(WETHv3pool),
            address(V3router));

        V4 = new Vogue(aavePool);
        CORE = new VogueCore(poolManager);
        AUX = new Aux(
            address(V4), address(CORE),
            address(steakhouseWETHvault),
            address(AMP), aavePool,
            address(WETHv3pool), address(V3router),
            address(V3), STABLECOINS, VAULTS);

        AMP.setup(payable(address(V3)), address(AUX));
        QUID = new Basket(address(V4), address(AUX));

        CORE.setup(address(V4), address(AUX), address(WETHv3pool));
        V4.setup(address(QUID), address(AUX), address(CORE));

        jury = new Jury(address(QUID));
        proof = new Proof(address(QUID));

        court = new Court(
            address(QUID),
            address(jury),
            address(proof));

        jury.setup(address(court), address(proof));
        proof.setCourt(address(court));
        proof.setJury(address(jury));

        AUX.setQuid(address(QUID),
                address(jury),
                address(court));
        V3.setAux(address(AUX));

        console.log("=== Deployed Addresses ===");
        console.log("AMP:", address(AMP));
        console.log("V3 (Rover):", address(V3));
        console.log("V4 (Vogue):", address(V4));
        console.log("CORE (VogueCore):", address(CORE));
        console.log("AUX:", address(AUX));
        console.log("QUID (Basket):", address(QUID));
        console.log("Jury:", address(jury));
        console.log("Proof:", address(proof));
        console.log("Court:", address(court));

        vm.stopBroadcast();
    }
}
