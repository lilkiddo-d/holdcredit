// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Governed} from "../libraries/Governed.sol";
import {Constants} from "../libraries/Constants.sol";
import {CreditAccount} from "./CreditAccount.sol";
import {
    ICreditAccountFactory,
    ILenderPool,
    IRiskEngine,
    IDexAdapter,
    IMarketClock,
    IComplianceRegistry
} from "../interfaces/IHoldcredit.sol";

/// @title CreditAccountFactory
/// @notice Deploys one CreditAccount minimal proxy per user and acts as the protocol registry that every
///         account reads its modules from. Pausing the factory pauses draws, swaps and indebted
///         withdrawals on every account (repay / deposit stay open).
contract CreditAccountFactory is Governed, ICreditAccountFactory {
    address public immutable implementation;
    address public immutable stable;

    ILenderPool public pool;
    IRiskEngine public riskEngine;
    IDexAdapter public dexAdapter;
    IMarketClock public marketClock;
    IComplianceRegistry public compliance; // optional
    address public softLiquidator;
    address public hardLiquidator;
    address public autoRepay;

    mapping(address => address) public accountOf;
    mapping(address => bool) public isAccount;
    address[] internal _accounts;

    event AccountCreated(address indexed owner, address indexed account);
    event ModulesSet(
        address pool,
        address riskEngine,
        address dexAdapter,
        address marketClock,
        address softLiquidator,
        address hardLiquidator,
        address autoRepay
    );
    event DexAdapterSet(address dexAdapter);
    event RiskEngineSet(address riskEngine);
    event MarketClockSet(address marketClock);
    event LiquidatorsSet(address softLiquidator, address hardLiquidator);
    event AutoRepaySet(address autoRepay);
    event ComplianceSet(address compliance);

    error AccountExists(address account);
    error NotAllowed();

    constructor(address implementation_, address stable_, address admin, address guardian) Governed(admin, guardian) {
        _nonZero(implementation_);
        _nonZero(stable_);
        implementation = implementation_;
        stable = stable_;
    }

    // =============================================================== admin (Timelock)

    /// @notice One-shot wiring used by the deploy script. Individual setters below handle later swaps.
    function setModules(
        ILenderPool pool_,
        IRiskEngine riskEngine_,
        IDexAdapter dexAdapter_,
        IMarketClock marketClock_,
        address softLiquidator_,
        address hardLiquidator_,
        address autoRepay_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(address(pool_));
        _nonZero(address(riskEngine_));
        _nonZero(address(dexAdapter_));
        _nonZero(address(marketClock_));
        _nonZero(softLiquidator_);
        _nonZero(hardLiquidator_);
        _nonZero(autoRepay_);
        pool = pool_;
        riskEngine = riskEngine_;
        dexAdapter = dexAdapter_;
        marketClock = marketClock_;
        softLiquidator = softLiquidator_;
        hardLiquidator = hardLiquidator_;
        autoRepay = autoRepay_;
        emit ModulesSet(
            address(pool_),
            address(riskEngine_),
            address(dexAdapter_),
            address(marketClock_),
            softLiquidator_,
            hardLiquidator_,
            autoRepay_
        );
    }

    function setDexAdapter(IDexAdapter d) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(address(d));
        dexAdapter = d;
        emit DexAdapterSet(address(d));
    }

    function setRiskEngine(IRiskEngine r) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(address(r));
        riskEngine = r;
        emit RiskEngineSet(address(r));
    }

    function setMarketClock(IMarketClock c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(address(c));
        marketClock = c;
        emit MarketClockSet(address(c));
    }

    function setLiquidators(address soft, address hard) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(soft);
        _nonZero(hard);
        softLiquidator = soft;
        hardLiquidator = hard;
        emit LiquidatorsSet(soft, hard);
    }

    function setAutoRepay(address a) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(a);
        autoRepay = a;
        emit AutoRepaySet(a);
    }

    /// @notice address(0) disables compliance gating entirely (the default).
    function setCompliance(IComplianceRegistry c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = c;
        emit ComplianceSet(address(c));
    }

    // =============================================================== users

    function createAccount() external whenNotPaused returns (address account) {
        if (!isAllowed(msg.sender, Constants.ACTION_OPEN_ACCOUNT)) revert NotAllowed();
        if (accountOf[msg.sender] != address(0)) revert AccountExists(accountOf[msg.sender]);
        account = Clones.cloneDeterministic(implementation, _salt(msg.sender));
        accountOf[msg.sender] = account;
        isAccount[account] = true;
        _accounts.push(account);
        emit AccountCreated(msg.sender, account);
        CreditAccount(account).initialize(msg.sender);
    }

    // =============================================================== views

    function isAllowed(address user, bytes32 action) public view returns (bool) {
        IComplianceRegistry c = compliance;
        return address(c) == address(0) || c.isAllowed(user, action);
    }

    function predictAccount(address owner) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(owner));
    }

    function accountsLength() external view returns (uint256) {
        return _accounts.length;
    }

    /// @notice Paginated account list for keepers (bounded by `limit`).
    function getAccounts(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 n = _accounts.length;
        if (offset >= n) return page;
        uint256 end = offset + limit > n ? n : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = _accounts[i];
        }
    }

    function paused() public view override(Pausable, ICreditAccountFactory) returns (bool) {
        return super.paused();
    }

    function _salt(address owner) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(owner)));
    }
}
