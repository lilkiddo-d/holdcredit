// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IMarketClock} from "../interfaces/IHoldcredit.sol";

/// @title MarketClock
/// @notice On-chain US equity session calendar. Open = Mon-Fri, [openMinute, closeMinute) America/New_York,
///         excluding holidays; early closes supported. US DST rules (2nd Sunday of March -> 1st Sunday of
///         November, switching at 02:00 local) are computed on-chain, so no keeper is needed for DST.
///         Holidays / early closes are maintained by CALENDAR_ROLE (ops multisig) - they can only make the
///         protocol *more* conservative or restore normal hours. Forcing "open" requires the Timelock admin.
contract MarketClock is IMarketClock, AccessControl {
    bytes32 public constant CALENDAR_ROLE = keccak256("CALENDAR_ROLE");

    enum Mode {
        Auto,
        ForceOpen,
        ForceClosed
    }

    Mode public mode;
    uint16 public openMinute = 570; // 09:30 ET
    uint16 public closeMinute = 960; // 16:00 ET
    /// @dev local day index => holiday
    mapping(uint256 => bool) public isHoliday;
    /// @dev local day index => early close minute (0 = none)
    mapping(uint256 => uint16) public earlyClose;

    event ModeSet(Mode mode);
    event SessionSet(uint16 openMinute, uint16 closeMinute);
    event HolidaySet(uint256 indexed day, bool isHoliday);
    event EarlyCloseSet(uint256 indexed day, uint16 closeMinute);

    error InvalidSession();
    error Unauthorized();

    constructor(address admin, address calendarOps) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CALENDAR_ROLE, admin);
        if (calendarOps != address(0)) _grantRole(CALENDAR_ROLE, calendarOps);
    }

    // ------------------------------------------------------------------ admin

    /// @notice Calendar ops may force-close or return to Auto; only the Timelock admin may force-open.
    function setMode(Mode m) external {
        if (m == Mode.ForceOpen) {
            if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert Unauthorized();
        } else if (!hasRole(CALENDAR_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        mode = m;
        emit ModeSet(m);
    }

    function setSession(uint16 open_, uint16 close_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (open_ >= close_ || close_ > 1440) revert InvalidSession();
        openMinute = open_;
        closeMinute = close_;
        emit SessionSet(open_, close_);
    }

    function setHolidays(uint256[] calldata days_, bool value) external onlyRole(CALENDAR_ROLE) {
        for (uint256 i; i < days_.length; ++i) {
            isHoliday[days_[i]] = value;
            emit HolidaySet(days_[i], value);
        }
    }

    function setEarlyClose(uint256 day, uint16 closeMinute_) external onlyRole(CALENDAR_ROLE) {
        if (closeMinute_ > 1440) revert InvalidSession();
        earlyClose[day] = closeMinute_;
        emit EarlyCloseSet(day, closeMinute_);
    }

    // ------------------------------------------------------------------ views

    function isOpen() external view returns (bool) {
        return isOpenAt(block.timestamp);
    }

    function currentDay() external view returns (uint256) {
        return localTime(block.timestamp) / 1 days;
    }

    // Calendar arithmetic: `%` and integer division are date maths (not randomness / precision loss).
    // slither-disable-start weak-prng,divide-before-multiply,incorrect-equality,timestamp
    function isOpenAt(uint256 ts) public view returns (bool) {
        if (mode == Mode.ForceOpen) return true;
        if (mode == Mode.ForceClosed) return false;
        uint256 local = localTime(ts);
        uint256 day = local / 1 days;
        uint256 weekday = (day + 4) % 7; // 0 = Sunday (1970-01-01 was a Thursday)
        if (weekday == 0 || weekday == 6 || isHoliday[day]) return false;
        uint256 minute = (local % 1 days) / 60;
        uint256 close = earlyClose[day] != 0 ? earlyClose[day] : closeMinute;
        return minute >= openMinute && minute < close;
    }

    /// @notice Unix timestamp shifted to America/New_York wall-clock seconds.
    function localTime(uint256 ts) public pure returns (uint256) {
        return isDst(ts) ? ts - 4 hours : ts - 5 hours;
    }

    /// @notice US daylight-saving time (since 2007): 2nd Sun of March 07:00 UTC -> 1st Sun of Nov 06:00 UTC.
    function isDst(uint256 ts) public pure returns (bool) {
        (uint256 year,,) = civilFromDays(ts / 1 days);
        uint256 start = _nthSunday(year, 3, 2) * 1 days + 7 hours;
        uint256 end = _nthSunday(year, 11, 1) * 1 days + 6 hours;
        return ts >= start && ts < end;
    }

    function _nthSunday(uint256 year, uint256 month, uint256 n) private pure returns (uint256) {
        uint256 first = daysFromCivil(year, month, 1);
        uint256 weekday = (first + 4) % 7;
        return first + ((7 - weekday) % 7) + (n - 1) * 7;
    }

    /// @dev Howard Hinnant's days_from_civil, valid for years >= 1970.
    function daysFromCivil(uint256 y, uint256 m, uint256 d) public pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    function civilFromDays(uint256 z) public pure returns (uint256 y, uint256 m, uint256 d) {
        z += 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
    }
    // slither-disable-end weak-prng,divide-before-multiply,incorrect-equality,timestamp
}
