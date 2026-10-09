// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {HoldcreditTimelock} from "../src/governance/HoldcreditTimelock.sol";
import {MarketClock} from "../src/periphery/MarketClock.sol";
import {OracleAdapter} from "../src/periphery/OracleAdapter.sol";
import {InterestRateModel} from "../src/core/InterestRateModel.sol";
import {LenderPool} from "../src/core/LenderPool.sol";
import {RiskEngine} from "../src/core/RiskEngine.sol";
import {CreditAccount} from "../src/core/CreditAccount.sol";
import {CreditAccountFactory} from "../src/core/CreditAccountFactory.sol";
import {FeeCollector} from "../src/periphery/FeeCollector.sol";
import {SoftLiquidator} from "../src/liquidation/SoftLiquidator.sol";
import {HardLiquidator} from "../src/liquidation/HardLiquidator.sol";
import {AutoRepay} from "../src/periphery/AutoRepay.sol";
import {ProjectTokenHooks} from "../src/periphery/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../src/periphery/ComplianceRegistry.sol";
import {IDexAdapter, IMarketClock, IPriceOracle, ILenderPool, IRiskEngine, IProjectTokenHooks} from
    "../src/interfaces/IHoldcredit.sol";
import {Constants} from "../src/libraries/Constants.sol";

/// @notice Deployment + wiring shared by script/Deploy.s.sol and the test suites, so tests exercise the
///         exact production wiring. Deploys NO token: the project token is attached later via the Timelock.
abstract contract SystemDeployer {
    struct Params {
        address deployer; // temporary admin during wiring; renounced at hand-over
        address stable;
        uint8 stableDecimals;
        address guardian; // pause/unpause, calendar ops, compliance ops
        address proposer; // Timelock proposer/canceller (multisig in production)
        address treasury;
        address keeper;
        uint256 closedDrawCap; // stable units per local day while the market is closed
        uint256 dustDebt; // stable units
        uint256 timelockDelay;
        uint256 irmBase;
        uint256 irmSlope1;
        uint256 irmSlope2;
        uint256 irmKink;
    }

    struct System {
        HoldcreditTimelock timelock;
        MarketClock clock;
        OracleAdapter oracle;
        InterestRateModel irm;
        LenderPool pool;
        RiskEngine riskEngine;
        CreditAccount implementation;
        CreditAccountFactory factory;
        IDexAdapter dex;
        FeeCollector feeCollector;
        SoftLiquidator soft;
        HardLiquidator hard;
        AutoRepay autoRepay;
        ProjectTokenHooks hooks;
        ComplianceRegistry compliance;
    }

    /// @dev Step 1: everything that does not need the DEX adapter.
    function _deployBase(Params memory p) internal returns (System memory s) {
        address[] memory proposers = new address[](1);
        proposers[0] = p.proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone may execute a matured operation
        s.timelock = new HoldcreditTimelock(p.timelockDelay, proposers, executors);

        s.clock = new MarketClock(p.deployer, p.guardian);
        s.oracle = new OracleAdapter(p.deployer, IMarketClock(address(s.clock)));
        s.irm = new InterestRateModel(p.irmBase, p.irmSlope1, p.irmSlope2, p.irmKink);
        s.pool = new LenderPool(IERC20(p.stable), s.irm, p.deployer, p.guardian);
        s.riskEngine = new RiskEngine(
            p.deployer,
            IPriceOracle(address(s.oracle)),
            IMarketClock(address(s.clock)),
            ILenderPool(address(s.pool)),
            p.stable,
            p.stableDecimals,
            p.closedDrawCap
        );
        s.implementation = new CreditAccount();
        s.factory = new CreditAccountFactory(address(s.implementation), p.stable, p.deployer, p.guardian);
        s.feeCollector = new FeeCollector(IERC20(p.stable), p.treasury, p.deployer, p.guardian);
        s.soft = new SoftLiquidator(s.factory, p.deployer, p.guardian);
        s.hard = new HardLiquidator(s.factory, address(s.feeCollector), p.dustDebt, p.deployer, p.guardian);
        s.autoRepay = new AutoRepay(s.factory, p.deployer, p.guardian);
        s.hooks = new ProjectTokenHooks(IERC20(p.stable), p.deployer, p.guardian);
        s.compliance = new ComplianceRegistry(p.deployer, p.guardian);
    }

    /// @dev Step 2: connect modules (requires the DEX adapter).
    function _wire(System memory s, Params memory p, IDexAdapter dex) internal {
        s.dex = dex;
        s.factory.setModules(
            ILenderPool(address(s.pool)),
            IRiskEngine(address(s.riskEngine)),
            dex,
            IMarketClock(address(s.clock)),
            address(s.soft),
            address(s.hard),
            address(s.autoRepay)
        );
        s.factory.setCompliance(s.compliance); // registry is disabled by default => no gating
        s.pool.setFactory(s.factory);
        s.pool.setFeeCollector(address(s.feeCollector));
        s.pool.setHardLiquidator(address(s.hard));
        s.pool.setHooks(IProjectTokenHooks(address(s.hooks)));
        s.feeCollector.setHooks(IProjectTokenHooks(address(s.hooks)));
        s.hooks.setWiring(s.factory, ILenderPool(address(s.pool)));
        s.hooks.grantRole(s.hooks.REWARD_NOTIFIER_ROLE(), address(s.feeCollector));
        if (p.keeper != address(0)) s.soft.grantRole(s.soft.KEEPER_ROLE(), p.keeper);

        // Compliance flags pre-set (inactive until the Timelock enables the registry).
        s.compliance.setGated(Constants.ACTION_OPEN_ACCOUNT, true);
        s.compliance.setGated(Constants.ACTION_DRAW, true);
        s.compliance.setGated(Constants.ACTION_SWAP, true);
        s.compliance.setGated(Constants.ACTION_LEND, true);
        s.compliance.setGated(Constants.ACTION_STAKE, true);
    }

    /// @dev Step 3: hand every admin role to the Timelock and drop the deployer's privileges.
    function _handOver(System memory s, Params memory p) internal {
        address tl = address(s.timelock);
        bytes32 admin = 0x00;

        AccessControl[13] memory acs = [
            AccessControl(address(s.clock)),
            AccessControl(address(s.oracle)),
            AccessControl(address(s.pool)),
            AccessControl(address(s.riskEngine)),
            AccessControl(address(s.factory)),
            AccessControl(address(s.feeCollector)),
            AccessControl(address(s.soft)),
            AccessControl(address(s.hard)),
            AccessControl(address(s.autoRepay)),
            AccessControl(address(s.hooks)),
            AccessControl(address(s.compliance)),
            AccessControl(address(s.dex)),
            AccessControl(address(0))
        ];
        s.riskEngine.grantRole(s.riskEngine.RISK_ADMIN_ROLE(), tl);
        if (p.deployer != p.guardian) {
            s.riskEngine.renounceRole(s.riskEngine.RISK_ADMIN_ROLE(), p.deployer);
            s.clock.renounceRole(s.clock.CALENDAR_ROLE(), p.deployer);
            s.compliance.renounceRole(s.compliance.COMPLIANCE_ROLE(), p.deployer);
        } else {
            s.riskEngine.renounceRole(s.riskEngine.RISK_ADMIN_ROLE(), p.deployer);
        }
        for (uint256 i; i < acs.length; ++i) {
            AccessControl ac = acs[i];
            if (address(ac) == address(0)) continue;
            // DexAdapter may be a mock without AccessControl in tests.
            try ac.hasRole(admin, p.deployer) returns (bool has) {
                if (!has) continue;
            } catch {
                continue;
            }
            ac.grantRole(admin, tl);
            ac.renounceRole(admin, p.deployer);
        }
    }
}
