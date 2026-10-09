// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInterestRateModel} from "../interfaces/IHoldcredit.sol";
import {Constants} from "../libraries/Constants.sol";

/// @title InterestRateModel
/// @notice Immutable kinked (two-slope) utilization curve. To change parameters governance deploys a new
///         model and points the LenderPool at it through the Timelock.
///         rate(u) = base + slope1 * min(u, kink)/kink + slope2 * max(0, u - kink)/(1 - kink)   (annual, WAD)
contract InterestRateModel is IInterestRateModel {
    uint256 public immutable baseRatePerYear;
    uint256 public immutable slope1PerYear;
    uint256 public immutable slope2PerYear;
    uint256 public immutable kink;

    error InvalidParams();

    constructor(uint256 base_, uint256 slope1_, uint256 slope2_, uint256 kink_) {
        if (kink_ == 0 || kink_ >= Constants.WAD || base_ + slope1_ + slope2_ > 10 * Constants.WAD) {
            revert InvalidParams();
        }
        baseRatePerYear = base_;
        slope1PerYear = slope1_;
        slope2PerYear = slope2_;
        kink = kink_;
    }

    function borrowRatePerYear(uint256 utilizationWad) public view returns (uint256) {
        uint256 u = utilizationWad > Constants.WAD ? Constants.WAD : utilizationWad;
        if (u <= kink) return baseRatePerYear + slope1PerYear * u / kink;
        return baseRatePerYear + slope1PerYear + slope2PerYear * (u - kink) / (Constants.WAD - kink);
    }

    function borrowRatePerSecond(uint256 utilizationWad) external view returns (uint256) {
        return borrowRatePerYear(utilizationWad) / Constants.SECONDS_PER_YEAR;
    }
}
