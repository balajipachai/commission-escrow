# Problem Statement:

Kalpana paints Warli scenes on cloth in a village three hours from Nashik. A collector in Berlin wants to commission a large piece, good money, the kind that changes a month for her. But the last two times a foreign buyer sent an "advance," the agent who arranged it kept most of it and Kalpana never saw the rest. The collector has her own worry: wiring money to someone she's never met, for a painting that doesn't exist yet, with no way to get it back if it never arrives.

Neither of them wants to trust a middleman again. They want the money itself to hold the promise: locked the moment the deal is struck, released only when the work is actually delivered, and returned automatically if it never is.

# Tech Stack

- Solidity
- Foundry
- OpenZeppelin (ReentrancyGuard, AccessControl)
- Base Sepolia
- Next.js + wagmi/viem (scaffold-eth2 must be used)

# Learnings

1. Locking value in a contract instead of trusting a counterparty or an agent
2. Gating fund release on a state change (delivery confirmed) rather than on whoever calls first, the possible states here would be `ORDER_PLACED, ORDER_RECEIVED, ORDER_CANCELLED, ORDER_CANCELLED_DUE_TO_TIMELINE_EXCEEDED, ORDER_DISPUTED, ORDER_DISPUTE_RESOLVED, ORDER_FULFILLED` these are the states I think of, add the necessary states though
3. Writing state before making an external call, so a malicious receiver can't re-enter and drain the contract (use ReentrancyGuard and CEI pattern)
4. Building a timeout path so money doesn't get stuck forever if a deal falls through (add a deadline during deal creation)

# What to do:

1. Let a collector open a commission for a specific artisan, locking the agreed amount into the contract at that moment. (Use FactoryPattern (use proxies) for deploying new contracts so that we save on contract deployment costs during deal creation)
2. Give the artisan a way to mark the work delivered, and require that confirmation before any funds move to them. (Probably linked to getting some offchain data like status of AWB from the respective carrier)
3. Handle disagreement: if the collector and artisan dispute whether delivery happened, resolution can't rest on either party's word alone. (Need to add in a dispute resolution mechanism, like, disputed contracts will be available on the marketplace and whoever resolves it will get 1% of the deal amount, this encourages that created deals don't lie for an infinite amount of time, here also add a check the disputed contracts should not be allowed to make a refund in case the timeline of the deal gets expired)
4. Set a deadline. If it passes with no delivery confirmed, make sure the locked funds can still get back to the collector. (If disputed, then, no refund should happen)
5. Make sure nothing about the flow lets a commission be paid out twice, or lets funds move before the contract's own records are updated.

# Output

- Deliverable. A single GitHub repo with the escrow contract, its tests, and a short README describing the commission lifecycle.

# Acceptance Criteria:

A collector's payment sits provably locked on-chain the moment a commission is agreed, and reaches the artisan only once delivery is confirmed or reaches nobody's pocket but the collector's if the deadline passes first, iff the contract is not disputed else it should stay locked as long as the dispute is not resolved.

# Test Cases:

1. Escrow holds funds before work begins - 5 points
Passes if The agreed amount is transferred into the contract's custody (via msg.value or an explicit token transfer) at the moment the commission is created.
Fails if A commission can be created and marked active with no value having moved into the contract at all.

2. Release requires confirmed delivery - 20 points
Passes if Funds can only move to the artisan after a distinct delivery-confirmation state has been set, and the collector alone cannot skip or override that state to force release.
Fails if The collector (or any single party other than the entity meant to confirm delivery) can trigger payout with no delivery-confirmation state required at all.

3. State updated before external transfer
Passes if The commission's status/balance is updated before the external value transfer occurs, or a reentrancy guard wraps the function.
Fails if The external transfer happens before the contract's own state is updated, with no reentrancy guard present.

4. Timeout produces an explicit refund path
Passes if After a defined deadline passes with delivery unconfirmed and contract not disputed, a refund function is reachable that returns the locked funds to the collector.
Fails if No deadline mechanism exists, or one exists but there is no way to actually reclaim funds once it passes.

5. Disputes aren't resolved by either party alone
Passes if Resolving a disputed commission requires an address distinct from both the collector and the artisan (an arbiter, multisig, or DAO — the mechanism is the builder's choice). Use an Arbiter for this case.
Fails if A disputed commission can be resolved unilaterally by the collector or the artisan calling a function themselves, or no dispute path exists at all.

6. Commission amount comes from value actually sent
Passes if The stored commission amount is set from msg.value (or the actual token amount transferred in) at creation time.
Fails if The stored amount can be set via a caller-supplied argument independent of what was actually transferred in.

7. No double release of the same commission
Passes if Once a commission reaches a terminal state (paid or refunded), calling release or refund again reverts or has no further effect.
Fails if Calling the release or refund function a second time on the same commission moves funds again.

8. No credentials in tracked files
Passes if No credential, key, or authenticated URL appears anywhere in the tracked repository.
Fails if Any private key, API key, or authenticated URL is found in a tracked file.


# Important

- Agent skills for secure smart contract development with OpenZeppelin Contracts libraries are added and are available.
- Reference: [develop-secure-contracts](https://github.com/OpenZeppelin/openzeppelin-skills/blob/main/skills/develop-secure-contracts/SKILL.md)
- Added Slither MCP Server as well, after contract completion these are the [tools](https://github.com/trailofbits/slither-mcp#mcp-tools) provided by MCP server
- Use [scaffold-eth-2](https://github.com/scaffold-eth/scaffold-eth-2/tree/main)

