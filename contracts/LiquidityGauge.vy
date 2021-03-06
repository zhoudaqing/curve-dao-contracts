# This gauge can be used for measuring liquidity and insurance

from vyper.interfaces import ERC20

interface CRV20:
    def start_epoch_time_write() -> uint256: nonpayable
    def rate() -> uint256: view

interface Controller:
    def period() -> int128: view
    def period_write() -> int128: nonpayable
    def period_timestamp(p: int128) -> uint256: view
    def gauge_relative_weight(addr: address, time: uint256) -> uint256: view
    def voting_escrow() -> address: view
    def checkpoint(): nonpayable
    def checkpoint_gauge(addr: address): nonpayable

interface Minter:
    def token() -> address: view
    def controller() -> address: view

interface VotingEscrow:
    def user_point_epoch(addr: address) -> uint256: view
    def user_point_history__ts(addr: address, epoch: uint256) -> uint256: view


event Deposit:
    provider: indexed(address)
    value: uint256

event Withdraw:
    provider: indexed(address)
    value: uint256

event UpdateLiquidityLimit:
    user: address
    original_balance: uint256
    original_supply: uint256
    working_balance: uint256
    working_supply: uint256


TOKENLESS_PRODUCTION: constant(uint256) = 40
BOOST_WARMUP: constant(uint256) = 2 * 7 * 86400
WEEK: constant(uint256) = 604800

minter: public(address)
crv_token: public(address)
lp_token: public(address)
controller: public(address)
voting_escrow: public(address)
balanceOf: public(HashMap[address, uint256])
totalSupply: public(uint256)

working_balances: public(HashMap[address, uint256])
working_supply: public(uint256)

# The goal is to be able to calculate ∫(rate * balance / totalSupply dt) from 0 till checkpoint
# All values are kept in units of being multiplied by 1e18
period: public(int128)
period_timestamp: public(uint256[100000000000000000000000000000])

# 1e18 * ∫(rate(t) / totalSupply(t) dt) from 0 till checkpoint
integrate_inv_supply: public(uint256[100000000000000000000000000000])  # bump epoch when rate() changes

# 1e18 * ∫(rate(t) / totalSupply(t) dt) from (last_action) till checkpoint
integrate_inv_supply_of: public(HashMap[address, uint256])
integrate_checkpoint_of: public(HashMap[address, uint256])


# ∫(balance * rate(t) / totalSupply(t) dt) from 0 till checkpoint
# Units: rate * t = already number of coins per address to issue
integrate_fraction: public(HashMap[address, uint256])

inflation_rate: uint256


@external
def __init__(lp_addr: address, _minter: address):
    self.lp_token = lp_addr
    self.minter = _minter
    crv_addr: address = Minter(_minter).token()
    self.crv_token = crv_addr
    controller_addr: address = Minter(_minter).controller()
    self.controller = controller_addr
    self.voting_escrow = Controller(controller_addr).voting_escrow()
    self.period_timestamp[0] = block.timestamp
    self.inflation_rate = CRV20(crv_addr).rate()


@internal
def _update_liquidity_limit(addr: address, l: uint256, L: uint256):
    """
    @notice Calculate limits which depend on the amount of CRV token per-user.
            Effectively it calculates working balances to apply amplification
            of CRV production by CRV
    @param addr User address
    @param l User's amount of liquidity (LP tokens)
    @param L Total amount of liquidity (LP tokens)
    """
    # To be called after totalSupply is updated
    _voting_escrow: address = self.voting_escrow
    voting_balance: uint256 = ERC20(_voting_escrow).balanceOf(addr)
    voting_total: uint256 = ERC20(_voting_escrow).totalSupply()

    lim: uint256 = l * TOKENLESS_PRODUCTION / 100
    if (voting_total > 0) and (block.timestamp > self.period_timestamp[0] + BOOST_WARMUP):
        lim += L * voting_balance / voting_total * (100 - TOKENLESS_PRODUCTION) / 100

    lim = min(l, lim)
    old_bal: uint256 = self.working_balances[addr]
    self.working_balances[addr] = lim
    _working_supply: uint256 = self.working_supply + lim - old_bal
    self.working_supply = _working_supply

    log UpdateLiquidityLimit(addr, l, L, lim, _working_supply)


@internal
def _checkpoint(addr: address):
    """
    @notice Checkpoint for a user
    @param addr User address
    """
    _token: address = self.crv_token
    _controller: address = self.controller
    _period: int128 = self.period
    _period_time: uint256 = self.period_timestamp[_period]
    _integrate_inv_supply: uint256 = self.integrate_inv_supply[_period]
    rate: uint256 = self.inflation_rate
    new_rate: uint256 = rate
    new_epoch: uint256 = CRV20(_token).start_epoch_time_write()
    if new_epoch >= _period_time:
        new_rate = CRV20(_token).rate()
        self.inflation_rate = new_rate
    Controller(_controller).checkpoint_gauge(self)

    _working_balance: uint256 = self.working_balances[addr]
    _working_supply: uint256 = self.working_supply

    # Update integral of 1/supply
    if block.timestamp > _period_time:
        prev_week_time: uint256 = _period_time
        week_time: uint256 = min((_period_time + WEEK) / WEEK * WEEK, block.timestamp)

        for i in range(500):
            dt: uint256 = week_time - prev_week_time
            w: uint256 = Controller(_controller).gauge_relative_weight(self, prev_week_time / WEEK * WEEK)

            if _working_supply > 0:
                if new_epoch >= prev_week_time and new_epoch < week_time:
                    _integrate_inv_supply += rate * w * (new_epoch - prev_week_time) / _working_supply
                    rate = new_rate
                    _integrate_inv_supply += rate * w * (week_time - new_epoch) / _working_supply
                else:
                    _integrate_inv_supply += rate * w * dt / _working_supply
                # On precisions of the calculation
                # rate ~= 10e18
                # last_weight > 0.01 * 1e18 = 1e16 (if pool weight is 1%)
                # _working_supply ~= TVL * 1e18 ~= 1e26 ($100M for example)
                # The largest loss is at dt = 1
                # Loss is 1e-9 - acceptable

            if week_time == block.timestamp:
                break
            prev_week_time = week_time
            week_time = min(week_time + WEEK, block.timestamp)

    _period += 1
    self.period = _period
    self.period_timestamp[_period] = block.timestamp
    self.integrate_inv_supply[_period] = _integrate_inv_supply

    # Update user-specific integrals
    user_period: int128 = _period  # Iteration starts from this
    user_period_time: uint256 = block.timestamp
    _user_checkpoint: uint256 = self.integrate_checkpoint_of[addr]
    _period_inv_supply: uint256 = _integrate_inv_supply
    _integrate_inv_supply_of: uint256 = self.integrate_inv_supply_of[addr]
    _integrate_fraction: uint256 = self.integrate_fraction[addr]
    # Cycle is going backwards in time over periods
    for i in range(500):
        if user_period < 0 or _user_checkpoint >= user_period_time:
            # Last cycle => we are in the period of the user checkpoint
            dI: uint256 = _period_inv_supply - _integrate_inv_supply_of
            _integrate_fraction += _working_balance * dI / 10 ** 18
            break
        else:
            user_period -= 1
            prev_period_inv_supply: uint256 = 0
            if user_period >= 0:
                prev_period_inv_supply = self.integrate_inv_supply[user_period]
            dI: uint256 = _period_inv_supply - prev_period_inv_supply
            _period_inv_supply = prev_period_inv_supply
            if user_period >= 0:
                user_period_time = self.period_timestamp[user_period]
            _integrate_fraction += _working_balance * dI / 10 ** 18

    self.integrate_inv_supply_of[addr] = _integrate_inv_supply
    self.integrate_fraction[addr] = _integrate_fraction
    self.integrate_checkpoint_of[addr] = block.timestamp


@external
def user_checkpoint(addr: address) -> bool:
    """
    @notice Checkpoint for a user
    @param addr User address
    """
    assert (msg.sender == addr) or (msg.sender == self.minter)  # dev: unauthorized
    self._checkpoint(addr)
    self._update_liquidity_limit(addr, self.balanceOf[addr], self.totalSupply)
    return True  # XXX explain


@external
def kick(addr: address):
    # Kick someone who is abusing his boost
    # Only if either they had another VE event, or they had VE lock expired
    _voting_escrow: address = self.voting_escrow
    t_last: uint256 = self.integrate_checkpoint_of[addr]
    t_ve: uint256 = VotingEscrow(_voting_escrow).user_point_history__ts(
        addr, VotingEscrow(_voting_escrow).user_point_epoch(addr)
    )
    _balance: uint256 = self.balanceOf[addr]

    assert ERC20(self.voting_escrow).balanceOf(addr) == 0 or t_ve > t_last # dev: kick not allowed
    assert self.working_balances[addr] > _balance * TOKENLESS_PRODUCTION / 100  # dev: kick not needed

    self._checkpoint(addr)
    self._update_liquidity_limit(addr, self.balanceOf[addr], self.totalSupply)


@external
@nonreentrant('lock')
def deposit(_value: uint256):
    self._checkpoint(msg.sender)

    _balance: uint256 = self.balanceOf[msg.sender] + _value
    _supply: uint256 = self.totalSupply + _value
    self.balanceOf[msg.sender] = _balance
    self.totalSupply = _supply

    self._update_liquidity_limit(msg.sender, _balance, _supply)

    assert ERC20(self.lp_token).transferFrom(msg.sender, self, _value)

    log Deposit(msg.sender, _value)


@external
@nonreentrant('lock')
def withdraw(_value: uint256):
    self._checkpoint(msg.sender)

    _balance: uint256 = self.balanceOf[msg.sender] - _value
    _supply: uint256 = self.totalSupply - _value
    self.balanceOf[msg.sender] = _balance
    self.totalSupply = _supply

    self._update_liquidity_limit(msg.sender, _balance, _supply)

    assert ERC20(self.lp_token).transfer(msg.sender, _value)

    log Withdraw(msg.sender, _value)


@external
@view
def integrate_checkpoint() -> uint256:
    return self.period_timestamp[self.period]
