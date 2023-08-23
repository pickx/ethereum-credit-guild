// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/** 
@title  An ERC20 with rebase capabilities. Anyone can sacrifice tokens to rebase up the balance
        of all addresses that are currently rebasing.
@author eswak
@notice This contract is meant to be used to distribute rewards proportionately to all holders of
        a token, for instance to distribute buybacks or income generated by a protocol.

        Anyone can subscribe to rebasing by calling `enterRebase()`, and unsubcribe with `exitRebase()`.
        Anyone can burn tokens they own to `distribute(uint256)` proportionately to rebasing addresses.

        The following conditions are always met :
        ```
        totalSupply() == nonRebasingSupply() + rebasingSupply()
        sum of balanceOf(x) == totalSupply() [+= rounding down errors of 1 wei for each balanceOf]
        ```
*/
abstract contract ERC20RebaseDistributor is ERC20 {
    /*///////////////////////////////////////////////////////////////
                            EVENTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an `account` enters rebasing.
    event RebaseEnter(address indexed account, uint256 indexed timestamp);
    /// @notice Emitted when an `account` exits rebasing.
    event RebaseExit(address indexed account, uint256 indexed timestamp);
    /// @notice Emitted when an `amount` of tokens is distributed by `source` to the rebasing accounts.
    event RebaseDistribution(
        address indexed source,
        uint256 indexed timestamp,
        uint256 amountDistributed,
        uint256 amountRebasing
    );

    /*///////////////////////////////////////////////////////////////
                            INTERNAL STATE
    ///////////////////////////////////////////////////////////////*/

    struct RebasingState {
        uint8 isRebasing;
        uint248 nShares;
    }

    /// @notice For internal accounting. Number of rebasing shares for each rebasing accounts. 0 if account is not rebasing.
    mapping(address => RebasingState) internal rebasingState;

    /// @notice For internal accounting. Total number of rebasing shares
    uint256 internal totalRebasingShares;

    /// @notice The starting share price for rebasing addresses.
    /// @dev rounding errors start to appear when balances of users are near `rebasingSharePrice`,
    /// due to rounding down in the number of shares attributed, and rounding down in the number of
    /// tokens per share. We use a high base to ensure no crazy rounding errors happen at runtime
    /// (balances of users would have to be > START_REBASING_SHARE_PRICE for rounding errors to start to materialize).
    uint256 internal constant START_REBASING_SHARE_PRICE = 1e30;

    /// @notice For internal accounting. Number of tokens per share for the rebasing supply.
    /// Starts at START_REBASING_SHARE_PRICE and goes up only.
    uint256 internal rebasingSharePrice = START_REBASING_SHARE_PRICE;

    /// @notice For internal accounting. Number of tokens distributed to rebasing addresses that have not
    /// yet been materialized by a movement in the rebasing addresses.
    uint256 internal pendingRebaseRewards;

    /*///////////////////////////////////////////////////////////////
                            EXTERNAL API
    ///////////////////////////////////////////////////////////////*/

    /// @notice Enter rebasing supply. All subsequent distributions will increase the balance
    /// of `msg.sender` proportionately.
    function enterRebase() external {
        require(
            rebasingState[msg.sender].isRebasing == 0,
            "ERC20RebaseDistributor: already rebasing"
        );
        _enterRebase(msg.sender);
    }

    function _enterRebase(address account) internal {
        uint256 balance = ERC20.balanceOf(account);
        uint256 shares = (balance * START_REBASING_SHARE_PRICE) /
            rebasingSharePrice;
        rebasingState[account].nShares = uint248(shares);
        rebasingState[account].isRebasing = 1;
        totalRebasingShares += shares;
        emit RebaseEnter(account, block.timestamp);
    }

    /// @notice Exit rebasing supply. All pending rebasing rewards are physically minted to the user,
    /// and they won't be affected by rebases anymore.
    function exitRebase() external {
        require(
            rebasingState[msg.sender].isRebasing == 1,
            "ERC20RebaseDistributor: not rebasing"
        );
        _exitRebase(msg.sender);
    }

    function _exitRebase(address account) internal {
        uint256 rawBalance = ERC20.balanceOf(account);
        uint256 shares = uint256(rebasingState[account].nShares);
        uint256 rebasedBalance = (shares * rebasingSharePrice) /
            START_REBASING_SHARE_PRICE;
        uint256 mintAmount = rebasedBalance - rawBalance;
        if (mintAmount != 0) {
            ERC20._mint(account, mintAmount);
            pendingRebaseRewards -= mintAmount;
        }

        rebasingState[account].nShares = 0;
        rebasingState[account].isRebasing = 0;
        totalRebasingShares -= shares;

        emit RebaseExit(account, block.timestamp);
    }

    /// @notice distribute tokens proportionately to all rebasing accounts.
    /// @dev if no addresses are rebasing, calling this function will burn tokens
    /// from `msg.sender` and emit an event, but won't rebase up any balances.
    function distribute(uint256 amount) external {
        require(amount != 0, "ERC20RebaseDistributor: cannot distribute zero");

        // burn the tokens received
        _burn(msg.sender, amount);

        // emit event
        uint256 _rebasingSharePrice = rebasingSharePrice;
        uint256 _rebasingSupply = (totalRebasingShares * _rebasingSharePrice) /
            START_REBASING_SHARE_PRICE;
        emit RebaseDistribution(
            msg.sender,
            block.timestamp,
            amount,
            _rebasingSupply
        );

        // adjust up the balance of all accounts that are rebasing by increasing
        // the share price of rebasing tokens
        if (_rebasingSupply != 0) {
            rebasingSharePrice =
                (_rebasingSharePrice * (_rebasingSupply + amount)) /
                _rebasingSupply;
            pendingRebaseRewards += amount;
        }
    }

    /// @notice True if an address subscribed to rebasing.
    function isRebasing(address account) public view returns (bool) {
        return rebasingState[account].isRebasing == 1;
    }

    /// @notice Total number of the tokens that are rebasing.
    function rebasingSupply() public view returns (uint256) {
        return
            (totalRebasingShares * rebasingSharePrice) /
            START_REBASING_SHARE_PRICE;
    }

    /// @notice Total number of the tokens that are not rebasing.
    function nonRebasingSupply() external view virtual returns (uint256) {
        uint256 _totalSupply = totalSupply();
        uint256 _rebasingSupply = rebasingSupply();

        // compare rebasing supply to total supply :
        // rounding errors due to share price & number of shares could otherwise
        // make this function revert due to an underflow
        if (_rebasingSupply > _totalSupply) {
            return 0;
        } else {
            return _totalSupply - _rebasingSupply;
        }
    }

    /*///////////////////////////////////////////////////////////////
                            ERC20 OVERRIDE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Override of balanceOf() that takes into account the pending undistributed rebase rewards.
    function balanceOf(
        address account
    ) public view virtual override returns (uint256) {
        uint256 _rebasingShares = rebasingState[account].nShares;
        if (_rebasingShares == 0) {
            return ERC20.balanceOf(account);
        } else {
            return
                (_rebasingShares * rebasingSharePrice) /
                START_REBASING_SHARE_PRICE;
        }
    }

    /// @notice Total number of the tokens in existence.
    function totalSupply() public view virtual override returns (uint256) {
        return ERC20.totalSupply() + pendingRebaseRewards;
    }

    /// @notice Override of default ERC20 behavior: exit rebase before movement (if rebasing),
    /// and re-enter rebasing after movement (if rebasing).
    /// @dev for _burn(), _mint(), transfer(), and transferFrom() overrides, a naive
    /// and concise implementation would be to just _exitRebase(), call the default ERC20 behavior,
    /// and then _enterRebase(), on the 2 addresses affected by the movement, but this is highly gas
    /// inefficient and the more complex implementations below are saving up to 40% gas costs.
    function _burn(address account, uint256 amount) internal virtual override {
        // if `account` is rebasing, materialize the tokens from rebase first, to ensure
        // proper behavior in `ERC20._burn()`.
        RebasingState memory _rebasingState = rebasingState[account];
        uint256 balanceBefore;
        uint256 _rebasingSharePrice;
        if (_rebasingState.isRebasing == 1) {
            balanceBefore = ERC20.balanceOf(account);
            _rebasingSharePrice = rebasingSharePrice;
            uint256 rebasedBalance = (_rebasingState.nShares *
                _rebasingSharePrice) / START_REBASING_SHARE_PRICE;
            uint256 mintAmount = rebasedBalance - balanceBefore;
            if (mintAmount != 0) {
                ERC20._mint(account, mintAmount);
                balanceBefore += mintAmount;
                pendingRebaseRewards -= mintAmount;
            }
        }

        // do ERC20._burn()
        ERC20._burn(account, amount);

        // if `account` is rebasing, update its number of shares
        if (_rebasingState.isRebasing == 1) {
            uint256 balanceAfter = balanceBefore - amount;
            uint256 sharesAfter = (balanceAfter * START_REBASING_SHARE_PRICE) /
                _rebasingSharePrice;
            uint256 sharesBurnt = _rebasingState.nShares - sharesAfter;
            rebasingState[account].nShares = uint248(sharesAfter);
            totalRebasingShares = totalRebasingShares - sharesBurnt;
        }
    }

    /// @notice Override of default ERC20 behavior: exit rebase before movement (if rebasing),
    /// and re-enter rebasing after movement (if rebasing).
    function _mint(address account, uint256 amount) internal virtual override {
        // do ERC20._mint()
        ERC20._mint(account, amount);

        // if `account` is rebasing, update its number of shares
        RebasingState memory _rebasingState = rebasingState[account];
        if (_rebasingState.isRebasing == 1) {
            uint256 _rebasingSharePrice = rebasingSharePrice;
            uint256 balanceAfter = (_rebasingState.nShares *
                _rebasingSharePrice) /
                START_REBASING_SHARE_PRICE +
                amount;
            uint256 sharesAfter = (balanceAfter * START_REBASING_SHARE_PRICE) /
                _rebasingSharePrice;
            uint256 sharesReceived = sharesAfter - _rebasingState.nShares;
            rebasingState[account].nShares = uint248(sharesAfter);
            totalRebasingShares = totalRebasingShares + sharesReceived;
        }
    }

    /// @notice Override of default ERC20 behavior: exit rebase before movement (if rebasing),
    /// and re-enter rebasing after movement (if rebasing).
    function transfer(
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        // if `from` is rebasing, materialize the tokens from rebase to ensure
        // proper behavior in `ERC20.transfer()`.
        RebasingState memory rebasingStateFrom = rebasingState[msg.sender];
        RebasingState memory rebasingStateTo = rebasingState[to];
        uint256 fromBalanceBefore = ERC20.balanceOf(msg.sender);
        uint256 _rebasingSharePrice = (rebasingStateFrom.isRebasing == 1 ||
            rebasingStateTo.isRebasing == 1)
            ? rebasingSharePrice
            : 0;
        if (rebasingStateFrom.isRebasing == 1) {
            uint256 shares = uint256(rebasingStateFrom.nShares);
            uint256 rebasedBalance = (shares * _rebasingSharePrice) /
                START_REBASING_SHARE_PRICE;
            uint256 mintAmount = rebasedBalance - fromBalanceBefore;
            if (mintAmount != 0) {
                ERC20._mint(msg.sender, mintAmount);
                fromBalanceBefore += mintAmount;
                pendingRebaseRewards -= mintAmount;
            }
        }

        // do ERC20.transfer()
        bool success = ERC20.transfer(to, amount);

        // if `from` is rebasing, update its number of shares
        uint256 _totalRebasingShares = (rebasingStateFrom.isRebasing == 1 ||
            rebasingStateTo.isRebasing == 1)
            ? totalRebasingShares
            : 0;
        if (rebasingStateFrom.isRebasing == 1) {
            uint256 fromBalanceAfter = fromBalanceBefore - amount;
            uint256 fromSharesAfter = (fromBalanceAfter *
                START_REBASING_SHARE_PRICE) / _rebasingSharePrice;
            uint256 sharesSpent = rebasingStateFrom.nShares - fromSharesAfter;
            _totalRebasingShares -= sharesSpent;
            rebasingState[msg.sender].nShares = uint248(fromSharesAfter);
        }

        // if `to` is rebasing, update its number of shares
        if (rebasingStateTo.isRebasing == 1) {
            uint256 toBalanceAfter = (rebasingStateTo.nShares *
                _rebasingSharePrice) /
                START_REBASING_SHARE_PRICE +
                amount;
            uint256 toSharesAfter = (toBalanceAfter *
                START_REBASING_SHARE_PRICE) / _rebasingSharePrice;
            uint256 sharesReceived = toSharesAfter - rebasingStateTo.nShares;
            _totalRebasingShares += sharesReceived;
            rebasingState[to].nShares = uint248(toSharesAfter);
        }

        // if `from` or `to` was rebasing, update the total number of shares
        if (
            rebasingStateFrom.isRebasing == 1 || rebasingStateTo.isRebasing == 1
        ) {
            totalRebasingShares = _totalRebasingShares;
        }

        return success;
    }

    /// @notice Override of default ERC20 behavior: exit rebase before movement (if rebasing),
    /// and re-enter rebasing after movement (if rebasing).
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        // if `from` is rebasing, materialize the tokens from rebase to ensure
        // proper behavior in `ERC20.transfer()`.
        RebasingState memory rebasingStateFrom = rebasingState[from];
        RebasingState memory rebasingStateTo = rebasingState[to];
        uint256 fromBalanceBefore = ERC20.balanceOf(from);
        uint256 _rebasingSharePrice = (rebasingStateFrom.isRebasing == 1 ||
            rebasingStateTo.isRebasing == 1)
            ? rebasingSharePrice
            : 0;
        if (rebasingStateFrom.isRebasing == 1) {
            uint256 shares = uint256(rebasingStateFrom.nShares);
            uint256 rebasedBalance = (shares * _rebasingSharePrice) /
                START_REBASING_SHARE_PRICE;
            uint256 mintAmount = rebasedBalance - fromBalanceBefore;
            if (mintAmount != 0) {
                ERC20._mint(from, mintAmount);
                fromBalanceBefore += mintAmount;
                pendingRebaseRewards -= mintAmount;
            }
        }

        // do ERC20.transferFrom()
        bool success = ERC20.transferFrom(from, to, amount);

        // if `from` is rebasing, update its number of shares
        uint256 _totalRebasingShares = (rebasingStateFrom.isRebasing == 1 ||
            rebasingStateTo.isRebasing == 1)
            ? totalRebasingShares
            : 0;
        if (rebasingStateFrom.isRebasing == 1) {
            uint256 fromBalanceAfter = fromBalanceBefore - amount;
            uint256 fromSharesAfter = (fromBalanceAfter *
                START_REBASING_SHARE_PRICE) / _rebasingSharePrice;
            uint256 sharesSpent = rebasingStateFrom.nShares - fromSharesAfter;
            _totalRebasingShares -= sharesSpent;
            rebasingState[from].nShares = uint248(fromSharesAfter);
        }

        // if `to` is rebasing, update its number of shares
        if (rebasingStateTo.isRebasing == 1) {
            uint256 toBalanceAfter = (rebasingStateTo.nShares *
                _rebasingSharePrice) /
                START_REBASING_SHARE_PRICE +
                amount;
            uint256 toSharesAfter = (toBalanceAfter *
                START_REBASING_SHARE_PRICE) / _rebasingSharePrice;
            uint256 sharesReceived = toSharesAfter - rebasingStateTo.nShares;
            _totalRebasingShares += sharesReceived;
            rebasingState[to].nShares = uint248(toSharesAfter);
        }

        // if `from` or `to` was rebasing, update the total number of shares
        if (
            rebasingStateFrom.isRebasing == 1 || rebasingStateTo.isRebasing == 1
        ) {
            totalRebasingShares = _totalRebasingShares;
        }

        return success;
    }
}
