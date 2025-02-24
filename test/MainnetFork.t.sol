// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.4 <0.9.0;
import {Good} from "../src/GD.sol";
import {MO} from "../src/Mindwill.sol";
import {mockVault} from "../src/mockVault.sol";
import {mockToken} from "../src/mockToken.sol";
import "lib/forge-std/src/console.sol"; // TODO delete
import {Test} from "lib/forge-std/src/Test.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {ERC4626} from "lib/solmate/src/tokens/ERC4626.sol";
import {ISwapRouter} from "../src/imports/ISwapRouter.sol";
import {IUniswapV3Pool} from "../src/imports/IUniswapV3Pool.sol";
import {IMorpho, MarketParams} from "../src/imports/morpho/IMorpho.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MorphoBalancesLib} from "../src/imports/morpho/libraries/MorphoBalancesLib.sol";
import {INonfungiblePositionManager} from "../src/imports/INonfungiblePositionManager.sol";

interface ICollection is IERC721 {
    function latestTokenId()
    external view returns (uint);
} 
contract MainnetFork is Test { Good public quid; MO public Mindwill;
    WETH public weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    mockToken public USDT; // = ERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    ERC20 public USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    mockToken public DAI; // = ERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    mockVault public SDAI; // = ERC4626(0x83F20F44975D03b1b09e64809B757c47f942BEeA);
    mockToken public USDS; // = ERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F);
    mockVault public SUSDS; // = ERC4626(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
    mockToken public GHO; // = ERC20(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
    mockVault public SGHO; // = ERC20(0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d);
    mockToken public FRAX; // = ERC20(0x853d955aCEf822Db058eb8505911ED77F175b99e);
    mockVault public SFRAX; // = ERC4626(0xA663B02CF0a4b149d2aD41910CB81e23e1c41c32);
    mockToken public USDE; // = ERC20(0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);
    mockVault public SUSDE; // = ERC4626(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
    mockToken public CRVUSD; // ERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    mockVault public SCRVUSD; // ERC4626(0x0655977FEb2f289A4aB78af67BAB0d17aAb84367);
    ICollection public F8N = ICollection(0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405); 
    ISwapRouter public router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    INonfungiblePositionManager public nfpm = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    IUniswapV3Pool public pool = IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    address public smokehouseUSDCvault = 0xBEeFFF209270748ddd194831b3fa287a5386f5bC;
    address public smokehouseUSDTvault = 0xA0804346780b4c2e3bE118ac957D1DB82F9d7484;
    
    address public User01 = address(0x1);
    address public User02 = address(0x2);
    address public User03 = address(0x3);
    address public User04 = address(0x4);
    address public User05 = address(0x5);
    address public User06 = address(0x6);
    address public User07 = address(0x7);
    address public User08 = address(0x8);
    address public User09 = address(0x9);
    address public User10 = address(0x10);
    address public User11 = address(0x11);
    address public User12 = address(0x12);
    address public User13 = address(0x13);
    address public User14 = address(0x14);
    address public User15 = address(0x15);
    address public User16 = address(0x16);
    address public User17 = address(0x17);

    uint public half_a_rock = 500000000000000000000000; // $500k
    uint public rack = 1000000000000000000000; // $1000
    uint public bill = 100000000000000000000; // $100
    uint public half_a_rack = 500000000000000000000; // $500
    
    uint public dub_dub_in_eth = 10000000000000000; // ~$40
    uint public grant = 50000000000000000000; // $50
    function setUp() public {
        uint256 mainnetFork = vm.createFork(
        "https://rpc.ankr.com/eth", 21909650);
        vm.selectFork(mainnetFork); 

        vm.deal(User01, 1_000_000_000_000_000 ether);
        vm.deal(User02, 1_000_000_000_000_000 ether);
        vm.deal(User03, 1_000_000_000_000_000 ether);
        
        // USDC = new mockToken(18);
        USDT = new mockToken(18);
        DAI = new mockToken(18);
        SDAI = new mockVault(DAI);
        USDS = new mockToken(18);
        SUSDS = new mockVault(USDS);
        USDE = new mockToken(18);
        SUSDE = new mockVault(USDE);
        FRAX = new mockToken(18);
        SFRAX = new mockVault(FRAX);
        GHO = new mockToken(18);
        SGHO = new mockVault(GHO);
        CRVUSD = new mockToken(18);
        SCRVUSD = new mockVault(CRVUSD);
        Mindwill = new MO( // Mindwill 
            address(weth), address(USDC), 
            address(nfpm), address(pool), 
            address(router) 
        );
        quid = new Good(
            address(Mindwill), smokehouseUSDCvault,
            address(USDT), smokehouseUSDTvault,
            0x1247f1c237eceae0602eab1470a5061a6dd8f734ba88c7cdc5d6109fb0026b28, // Morpho Market
            address(USDE), address(SUSDE), address(FRAX), address (SFRAX),
            address (SDAI), address(DAI), address(USDS), address(SUSDS),
            address(CRVUSD), address(SCRVUSD), address(GHO), address(SGHO)
        );  Mindwill.setQuid(address(quid));
        Mindwill.set_price_eth(false, true);
        (,uint price, uint160 sqrtPrice) = Mindwill.fetch(User01);
        console.log("?!?!?!?!? sqrtPrice ?!?!?!?!?", sqrtPrice);
        console.log("?!?!?!?!? price ?!?!?!?!?", price);
        // TODO uncomment
    }
    
    // "I scream...I scream...I scream so much...
    // You know what I mean this electric stream
    // And my tears in league with the
    // Wires and energy and my machine
    // This is my beautiful dream
    // I'm hurting no one
    // Hurting no one
    // Hurting no one
    // Hurting no one
    // I want to give you everything
    // I want to give you energy
    // I want to give a good thing
    // I want to give you everything
    // Everything, everything, everything, 
    // everything, everything, everything, everything"
    function testEverything() public {
        uint weth_debit; uint weth_credit; 
        uint work_debit; uint work_credit;
        uint quid_debit; uint quid_credit;

        // TODO simulate a large transfer from 
        // large holder of USDe to the test account
        vm.startPrank(User01); USDE.mint();
        weth.deposit{value: 1_000_000 ether}();

        USDE.approve(address(quid), type(uint256).max);
        quid.mint(User01, half_a_rack, address(USDE), 0);
        quid.mint(User01, half_a_rack, address(USDE), 0);

        uint minted = quid.balanceOf(User01, 1);
        uint total = quid.totalBalances(User01);
        assertEq(minted, rack);
        assertEq(minted, total);

        (quid_credit, 
         quid_debit) = Mindwill.get_info(User01);
        console.log("User1...before transfer", quid_credit, quid_debit);

        uint a; uint b; uint c; uint d;
        (work_debit, work_credit, 
         weth_debit, weth_credit) = Mindwill.get_more_info(User01);
        quid.transfer(User02, grant);
        vm.stopPrank(); 
        // exit User1 context

        // transfer backward 
        vm.startPrank(User02); 
        quid.transfer(User01, grant);
        vm.stopPrank();
       
        (a,b,c,d) = Mindwill.get_more_info(User01);
        // and verify that carry.debit
        // before and after are the same
        assertEq(a, work_debit);
        assertEq(b, work_credit);
        assertEq(c, weth_debit);
        assertEq(d, weth_credit);
        uint beforeBatch = quid.currentBatch();
        
        // Simulate passage of time
        vm.warp(block.timestamp + 14 days);
        
        vm.startPrank(User02);
        USDE.mint();
        weth.deposit{value: 1_000_000 ether}();

        weth.approve(address(Mindwill), type(uint256).max);
        USDE.approve(address(quid), type(uint256).max);
        quid.mint(User02, bill, address(USDE), 0);

        minted = quid.balanceOf(User02, 1);

        (quid_credit, 
         quid_debit) = Mindwill.get_info(User02); 
        console.log("User2...", quid_credit, quid_debit); 

        vm.stopPrank(); // exit User2 context

        (quid_credit, quid_debit) = Mindwill.get_info(User01);
        console.log("User1...after transfer", quid_credit, quid_debit);

        console.log("<><><><><><><>  total        <><><><><><><><>", quid.get_total_deposits(true));
        
        vm.startPrank(User01);
        
        weth.approve(address(Mindwill), dub_dub_in_eth);
        Mindwill.deposit(User01, dub_dub_in_eth, false);
        
        (work_debit, work_credit, 
         weth_debit, weth_credit) = Mindwill.get_more_info(User01);

        console.log("User1...more_info beforeFOLD", 
            work_debit, work_credit, weth_debit
        );
        Mindwill.fold(User01, dub_dub_in_eth, false);

        (work_debit, work_credit, 
         weth_debit, weth_credit) = Mindwill.get_more_info(User01);

        console.log("User1...more_info AFTERfold", 
            work_debit, work_credit, weth_debit
        );
        
        uint256 balanceBefore = User01.balance;
        console.log("user1BalanceBefore withdraw ETH...", balanceBefore);
        Mindwill.withdraw(dub_dub_in_eth, false);

        uint256 balanceAfter = User01.balance;
        console.log("user1BalanceAFTER withdraw ETH...", balanceAfter);
        vm.stopPrank(); // TODO no deductible if fold without price drop

        vm.startPrank(User03);

        uint thirtyThree = 33000000000000000000;
        Mindwill.withdraw{value: dub_dub_in_eth}(thirtyThree, true);

        (work_debit, work_credit, 
         weth_debit, weth_credit) = Mindwill.get_more_info(User03);

        console.log("User3...more_info AFTER borrow", 
            work_debit, work_credit, weth_debit
        );
        console.log("QD that was minted for User3...", quid.balanceOf(User03, 1));

        vm.stopPrank();
        console.log("price before drop", Mindwill.getPrice(42));
        // Mindwill.set_price_eth(false, false); // TODO uncomment
        // Mindwill.set_price_eth(false, false);
        console.log("price AFTER drop", Mindwill.getPrice(42));
        Mindwill.fold(User03, 1, false); // for a liquidation amount variable is irrelevant

        (work_debit, work_credit, 
         weth_debit, weth_credit) = Mindwill.get_more_info(User03);

        console.log("User3...more_info AFTER liquidation (1st)", 
            work_debit, work_credit, weth_debit
        );

        vm.warp(block.timestamp + 61 minutes);

        Mindwill.fold(User03, 1, false); // for a liquidation amount variable is irrelevant
         (work_debit, work_credit, 
         weth_debit, weth_credit) = Mindwill.get_more_info(User03);

        console.log("User3...more_info AFTER liquidation (1 hour later)", 
            work_debit, work_credit, weth_debit
        );


        // TODO 
        // assertEq(minted, rack);

        /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
        /*                 Transaction reactions                      */
        /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/
        /*
        vm.startPrank(User01);
        quid.vote(25);
        vm.stopPrank();
        
        vm.startPrank(User02);
        quid.vote(25);
        vm.stopPrank();
        
        vm.startPrank(User03);
        quid.vote(25);
        vm.stopPrank();
        
        vm.startPrank(User04);
        quid.vote(25);
        vm.stopPrank();
        
        vm.startPrank(User05);
        quid.vote(25);
        vm.stopPrank();
        
        vm.startPrank(User06);
        quid.vote(25);
        vm.stopPrank();
        
        vm.startPrank(User07);
        quid.vote(25);
        vm.stopPrank();
        
        vm.startPrank(User08);
        quid.vote(25);
        vm.stopPrank();
        
        vm.startPrank(User09);
        quid.vote(25);
        vm.stopPrank();
        */
        vm.warp(block.timestamp + 34 days);

        uint avg_roi_before = quid.ROI();
        
        quid.reachUp();

        uint avg_roi_after = quid.ROI();
        uint afterBatch = quid.currentBatch();
        assertNotEq(beforeBatch, afterBatch);
        assertNotEq(avg_roi_before, avg_roi_after);

        vm.startPrank(User01);
        // Mindwill.redeem();
        vm.stopPrank();
    }
    /*
        assertGt(amountOut, 0);

        vm.expectRevert(FoldCaptiveStaking.AlreadyInitialized.selector);

        /// @dev Ensure the contract is protected against reentrancy attacks.
        function testReentrancy() public {
            testAddLiquidity();

            // Create a reentrancy attack contract and attempt to exploit the staking contract
            ReentrancyAttack attack = new ReentrancyAttack(payable(address(foldCaptiveStaking)));
            fold.transfer(address(attack), 1 ether);
            weth.transfer(address(attack), 1 ether);

            vm.expectRevert();
            attack.attack();
        }
    */
    // TODO prank some SUSDE into the ERC20
    // so that Morpho borrowing can be tested
}

// Reentrancy attack contract
/*
contract ReentrancyAttack {
    FoldCaptiveStaking public staking;

    constructor(address payable _staking) {
        staking = FoldCaptiveStaking(_staking);
    }

    function attack() public {
        staking.deposit(1 ether, 1 ether, 0);
        staking.withdraw(1);
    }

    receive() external payable {
        staking.withdraw(1);
    }
} */