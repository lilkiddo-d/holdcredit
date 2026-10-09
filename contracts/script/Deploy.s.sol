// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SystemDeployer} from "./SystemDeployer.sol";
import {DexAdapter} from "../src/periphery/DexAdapter.sol";
import {OracleAdapter} from "../src/periphery/OracleAdapter.sol";
import {IRiskEngine, IDexAdapter} from "../src/interfaces/IHoldcredit.sol";
import {ISwapRouter02} from "../src/interfaces/IExternal.sol";

/// @title Deploy
/// @notice One-shot deploy + wire + hand-over for Holdcredit.
///   forge script script/Deploy.s.sol --rpc-url <rpc> --account holdcredit-deployer --broadcast --verify ...
/// Optional env: GUARDIAN, TIMELOCK_PROPOSER, TREASURY, KEEPER (all default to the deployer),
///               DEPLOY_CONFIG (defaults to config/deploy.<chainId>.json; anvil 31337 uses the 4663 config).
/// Output: deployments/<chainId>.json (+ ../app/src/config/deployments/<chainId>.json) on broadcast,
///         deployments/<chainId>.dryrun.json on simulation. Nothing is written during tests.
contract Deploy is Script, SystemDeployer {
    /// @dev Field order MUST be alphabetical (forge JSON decoding).
    struct AssetJson {
        uint256 fee;
        address feed;
        uint256 hardBps;
        uint256 liquidityScore;
        uint256 ltvBps;
        uint256 softBps;
        string symbol;
        address token;
    }

    struct Cfg {
        address stable;
        uint8 stableDecimals;
        address stableFeed;
        address swapRouter02;
        address quoterV2;
        address sequencerUptimeFeed;
        uint32 stalenessOpen;
        uint32 stalenessClosed;
        uint32 stableStaleness;
        uint256[] holidays;
        uint256[] earlyCloseDays;
        uint256[] earlyCloseMinutes;
        AssetJson[] assets;
    }

    function run() external returns (System memory s) {
        address deployer = msg.sender;
        string memory json = vm.readFile(_configPath());
        Cfg memory c = _parse(json);
        Params memory p = Params({
            deployer: deployer,
            stable: c.stable,
            stableDecimals: c.stableDecimals,
            guardian: vm.envOr("GUARDIAN", deployer),
            proposer: vm.envOr("TIMELOCK_PROPOSER", deployer),
            treasury: vm.envOr("TREASURY", deployer),
            keeper: vm.envOr("KEEPER", deployer),
            closedDrawCap: vm.parseJsonUint(json, ".closedDrawCap"),
            dustDebt: vm.parseJsonUint(json, ".dustDebt"),
            timelockDelay: vm.parseJsonUint(json, ".timelockDelay"),
            irmBase: vm.parseJsonUint(json, ".irmBase"),
            irmSlope1: vm.parseJsonUint(json, ".irmSlope1"),
            irmSlope2: vm.parseJsonUint(json, ".irmSlope2"),
            irmKink: vm.parseJsonUint(json, ".irmKink")
        });

        vm.startBroadcast(deployer);
        s = _deployBase(p);
        DexAdapter dex = new DexAdapter(ISwapRouter02(c.swapRouter02), c.stable, deployer);
        _wire(s, p, IDexAdapter(address(dex)));
        _configure(s, c, dex);
        _handOver(s, p);
        vm.stopBroadcast();

        _log(s);
        _write(s, c, p);
    }

    function _configure(System memory s, Cfg memory c, DexAdapter dex) internal {
        s.oracle.setFeed(
            c.stable,
            OracleAdapter.FeedConfig({
                primary: c.stableFeed,
                secondary: address(0),
                maxStalenessOpen: c.stableStaleness,
                maxStalenessClosed: c.stableStaleness,
                maxDeviationBps: 0,
                tokenDecimals: c.stableDecimals,
                checkTokenPause: false
            })
        );
        if (c.sequencerUptimeFeed != address(0)) s.oracle.setSequencerUptimeFeed(c.sequencerUptimeFeed, 1 hours);

        for (uint256 i; i < c.assets.length; ++i) {
            AssetJson memory a = c.assets[i];
            s.oracle.setFeed(
                a.token,
                OracleAdapter.FeedConfig({
                    primary: a.feed,
                    secondary: address(0),
                    maxStalenessOpen: c.stalenessOpen,
                    maxStalenessClosed: c.stalenessClosed,
                    maxDeviationBps: 0,
                    tokenDecimals: 18,
                    checkTokenPause: true
                })
            );
            s.riskEngine.setAssetConfig(
                a.token,
                IRiskEngine.AssetConfig({
                    enabled: true,
                    frozen: false,
                    ltvBps: uint16(a.ltvBps),
                    softBps: uint16(a.softBps),
                    hardBps: uint16(a.hardBps),
                    liquidityScore: uint16(a.liquidityScore)
                })
            );
            dex.setHubFee(a.token, uint24(a.fee));
        }

        if (c.holidays.length != 0) s.clock.setHolidays(c.holidays, true);
        for (uint256 i; i < c.earlyCloseDays.length; ++i) {
            s.clock.setEarlyClose(c.earlyCloseDays[i], uint16(c.earlyCloseMinutes[i]));
        }
    }

    // ------------------------------------------------------------------ config + output

    function _configPath() internal view returns (string memory) {
        uint256 cfgChain = block.chainid == 31337 ? 4663 : block.chainid;
        string memory dflt = string.concat(vm.projectRoot(), "/config/deploy.", vm.toString(cfgChain), ".json");
        return vm.envOr("DEPLOY_CONFIG", dflt);
    }

    function _parse(string memory json) internal pure returns (Cfg memory c) {
        c.stable = vm.parseJsonAddress(json, ".stable");
        c.stableDecimals = uint8(vm.parseJsonUint(json, ".stableDecimals"));
        c.stableFeed = vm.parseJsonAddress(json, ".stableFeed");
        c.swapRouter02 = vm.parseJsonAddress(json, ".swapRouter02");
        c.quoterV2 = vm.parseJsonAddress(json, ".quoterV2");
        c.sequencerUptimeFeed = vm.parseJsonAddress(json, ".sequencerUptimeFeed");
        c.stalenessOpen = uint32(vm.parseJsonUint(json, ".stalenessOpen"));
        c.stalenessClosed = uint32(vm.parseJsonUint(json, ".stalenessClosed"));
        c.stableStaleness = uint32(vm.parseJsonUint(json, ".stableStaleness"));
        c.holidays = vm.parseJsonUintArray(json, ".holidays");
        c.earlyCloseDays = vm.parseJsonUintArray(json, ".earlyCloseDays");
        c.earlyCloseMinutes = vm.parseJsonUintArray(json, ".earlyCloseMinutes");
        c.assets = abi.decode(vm.parseJson(json, ".assets"), (AssetJson[]));
    }

    function _log(System memory s) internal pure {
        console2.log("Timelock            ", address(s.timelock));
        console2.log("CreditAccountFactory", address(s.factory));
        console2.log("LenderPool          ", address(s.pool));
        console2.log("RiskEngine          ", address(s.riskEngine));
        console2.log("OracleAdapter       ", address(s.oracle));
        console2.log("MarketClock         ", address(s.clock));
        console2.log("DexAdapter          ", address(s.dex));
        console2.log("SoftLiquidator      ", address(s.soft));
        console2.log("HardLiquidator      ", address(s.hard));
        console2.log("AutoRepay           ", address(s.autoRepay));
        console2.log("FeeCollector        ", address(s.feeCollector));
        console2.log("ProjectTokenHooks   ", address(s.hooks));
        console2.log("ComplianceRegistry  ", address(s.compliance));
    }

    function _write(System memory s, Cfg memory c, Params memory p) internal {
        bool broadcast = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        bool dryRun = vm.isContext(VmSafe.ForgeContext.ScriptDryRun);
        if (!broadcast && !dryRun) return; // tests

        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "deployedAtBlock", block.number);
        vm.serializeBool(o, "dryRun", dryRun);
        vm.serializeAddress(o, "deployer", p.deployer);
        vm.serializeAddress(o, "guardian", p.guardian);
        vm.serializeAddress(o, "timelockProposer", p.proposer);
        vm.serializeAddress(o, "treasury", p.treasury);
        vm.serializeAddress(o, "keeper", p.keeper);
        vm.serializeAddress(o, "stable", c.stable);
        vm.serializeAddress(o, "quoterV2", c.quoterV2);
        vm.serializeAddress(o, "timelock", address(s.timelock));
        vm.serializeAddress(o, "marketClock", address(s.clock));
        vm.serializeAddress(o, "oracleAdapter", address(s.oracle));
        vm.serializeAddress(o, "interestRateModel", address(s.irm));
        vm.serializeAddress(o, "lenderPool", address(s.pool));
        vm.serializeAddress(o, "riskEngine", address(s.riskEngine));
        vm.serializeAddress(o, "creditAccountImplementation", address(s.implementation));
        vm.serializeAddress(o, "creditAccountFactory", address(s.factory));
        vm.serializeAddress(o, "dexAdapter", address(s.dex));
        vm.serializeAddress(o, "feeCollector", address(s.feeCollector));
        vm.serializeAddress(o, "softLiquidator", address(s.soft));
        vm.serializeAddress(o, "hardLiquidator", address(s.hard));
        vm.serializeAddress(o, "autoRepay", address(s.autoRepay));
        vm.serializeAddress(o, "projectTokenHooks", address(s.hooks));
        vm.serializeAddress(o, "complianceRegistry", address(s.compliance));

        string memory assetsJson = "[";
        for (uint256 i; i < c.assets.length; ++i) {
            AssetJson memory a = c.assets[i];
            assetsJson = string.concat(
                assetsJson,
                i == 0 ? "" : ",",
                '{"symbol":"',
                a.symbol,
                '","token":"',
                vm.toString(a.token),
                '","feed":"',
                vm.toString(a.feed),
                '","fee":',
                vm.toString(a.fee),
                ',"ltvBps":',
                vm.toString(a.ltvBps),
                ',"softBps":',
                vm.toString(a.softBps),
                ',"hardBps":',
                vm.toString(a.hardBps),
                "}"
            );
        }
        assetsJson = string.concat(assetsJson, "]");
        string memory out = vm.serializeString(o, "assetsRaw", assetsJson);

        string memory id = vm.toString(block.chainid);
        if (dryRun) {
            vm.writeJson(out, string.concat(vm.projectRoot(), "/deployments/", id, ".dryrun.json"));
            return;
        }
        vm.writeJson(out, string.concat(vm.projectRoot(), "/deployments/", id, ".json"));
        vm.writeJson(out, string.concat(vm.projectRoot(), "/../app/src/config/deployments/", id, ".json"));
    }
}
