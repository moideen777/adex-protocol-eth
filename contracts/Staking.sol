// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "./libs/SafeMath.sol";
import "./libs/SafeERC20.sol";

// AIP: https://github.com/AdExNetwork/aips/issues/18
// Quick overview:
// - it's divided into pools, each pool may represent a validator; it may represent something else too (for example, we may launch staking for publishers to prove their legitimacy)
// - the slasherAddr will be a multisig that will be controlled by the AdEx team - and later full control of the multisig will be given to a bridge to Polkadot, where we'll run the full on-chain slashing mechanism
//   - we will clearly communicate this migration path to our community and stakers
// - reward distribution is off-chain: depending on the pool, it may be done either via OUTPACE, via the Polkadot parachain, or via an auxilary contract that implements round-based reward distribution (you check into each round, the SC confirms you have a bond on Staking.sol, and you can withdraw your pro-rata earnings for the round)
// - each bond will be slashed relative to the time it bonded/unbonded; e.g. if the pool is slashed 12%, you bonded, then the pool was slashed 2%, then you unbonded, you'd only suffer a 2% slash

library BondLibrary {
	struct Bond {
		uint amount;
		bytes32 poolId;
		uint nonce;
	}

	function hash(Bond memory bond, address sender)
		internal
		view
		returns (bytes32)
	{
		return keccak256(abi.encode(
			address(this),
			sender,
			bond.amount,
			bond.poolId,
			bond.nonce
		));
	}
}

contract Staking {
	using SafeMath for uint;
	using BondLibrary for BondLibrary.Bond;

	// This fits in a storage slot so we can only use one when saving bond state
	struct BondState {
		bool active;
		// Data type must be larger than MAX_SLASH (2**64 > 10**18)
		uint64 slashedAtStart;
		uint64 willUnlock;
	}

	// Events
	event LogSlash(bytes32 indexed poolId, uint newSlashPts, uint time);
	event LogBond(address indexed owner, uint amount, bytes32 poolId, uint nonce, uint64 slashedAtStart, uint time);
	event LogUnbondRequested(address indexed owner, bytes32 indexed bondId, uint64 willUnlock, uint time);
	event LogUnbonded(address indexed owner, bytes32 indexed bondId, uint time);

	// could be 2**64 too, since we use uint64
	uint constant MAX_SLASH = 10 ** 18;
	uint constant TIME_TO_UNBOND = 30 days;
	// A non-0x00 address since some ERC20 tokens do not allow sending to 0x00; although we intend to only use this contract with ADX
	address constant BURN_ADDR = address(0xaDbeEF0000000000000000000000000000000000);

	address public immutable tokenAddr;
	address public immutable slasherAddr;
	// Addressed by poolId
	mapping (bytes32 => uint) public slashPoints;
	// Addressed by bondId
	mapping (bytes32 => BondState) public bonds;

	constructor(address token, address slasher) public {
   		tokenAddr = token;
   		slasherAddr = slasher;
	}

	function slash(bytes32 poolId, uint pts) external {
		require(msg.sender == slasherAddr, 'ONLY_SLASHER');
		uint newSlashPts = slashPoints[poolId].add(pts);
		require(newSlashPts <= MAX_SLASH, 'PTS_TOO_HIGH');
		slashPoints[poolId] = newSlashPts;
		emit LogSlash(poolId, newSlashPts, now);
	}

	function addBond(BondLibrary.Bond memory bond) public {
		bytes32 id = bond.hash(msg.sender);
		require(!bonds[id].active, 'BOND_ALREADY_ACTIVE');
		require(slashPoints[bond.poolId] < MAX_SLASH, 'POOL_SLASHED');
		bonds[id] = BondState({
			active: true,
			slashedAtStart: uint64(slashPoints[bond.poolId]),
			willUnlock: 0
		});
		SafeERC20.transferFrom(tokenAddr, msg.sender, address(this), bond.amount);
		emit LogBond(msg.sender, bond.amount, bond.poolId, bond.nonce, bonds[id].slashedAtStart, now);
	}

	function requestUnbond(BondLibrary.Bond memory bond) public {
		bytes32 id = bond.hash(msg.sender);
		BondState storage bondState = bonds[id];
		require(bondState.active && bondState.willUnlock == 0, 'BOND_NOT_ACTIVE');
		bondState.willUnlock = uint64(now + TIME_TO_UNBOND);
		emit LogUnbondRequested(msg.sender, id, bondState.willUnlock, now);
	}

	function unbondInternal(BondLibrary.Bond memory bond, bytes32 id, BondState storage bondState) internal {
		uint amount = calcWithdrawAmount(bond, bondState.slashedAtStart);
		uint toBurn = bond.amount - amount;
		delete bonds[id];
		SafeERC20.transfer(tokenAddr, msg.sender, amount);
		if (toBurn > 0) SafeERC20.transfer(tokenAddr, BURN_ADDR, toBurn);
		emit LogUnbonded(msg.sender, id, now);
	}

	function unbond(BondLibrary.Bond memory bond) public {
		bytes32 id = bond.hash(msg.sender);
		BondState storage bondState = bonds[id];
		require(bondState.willUnlock > 0 && now > bondState.willUnlock, 'BOND_NOT_UNLOCKED');
		unbondInternal(bond, id, bondState);
	}

	function replaceBond(BondLibrary.Bond memory bond, BondLibrary.Bond memory newBond) public {
		bytes32 id = bond.hash(msg.sender);
		BondState storage bondState = bonds[id];
		// We allow replacing the bond even if it's requested to be unbonded, so that you can re-bond
		require(bondState.active, 'BOND_NOT_ACTIVE');
		require(newBond.poolId == bond.poolId, 'POOL_ID_DIFFERENT');
		require(newBond.amount >= calcWithdrawAmount(bond, bondState.slashedAtStart), 'NEW_BOND_SMALLER');
		unbondInternal(bond, id, bondState);
		addBond(newBond);
	}

	function getWithdrawAmount(address owner, BondLibrary.Bond memory bond) public view returns (uint) {
		BondState storage bondState = bonds[bond.hash(owner)];
		if (!bondState.active) return 0;
		return calcWithdrawAmount(bond, bondState.slashedAtStart);
	}

	function calcWithdrawAmount(BondLibrary.Bond memory bond, uint64 slashedAtStart) internal view returns (uint) {
		return bond.amount
			.mul(MAX_SLASH.sub(slashPoints[bond.poolId]))
			.div(MAX_SLASH.sub(uint(slashedAtStart)));
	}
}
