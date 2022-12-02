pragma solidity >= 0.8.0 <= 0.9.0;
pragma experimental ABIEncoderV2;

import "github.com/provable-things/ethereum-api/provableAPI.sol";

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor () {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}

contract whalesbet is usingProvable,ReentrancyGuard {
    
    address contractCreator = ;
      
    fallback() external payable{}
    receive() external payable{}

    /* There are two different dates associated with each created bet:
    one for the deadline where a user can no longer place new bets,
    and another one that tells the smart oracle contract when to actually
    query the specified website to parse the bet's final result. */
    mapping(string => uint64) public betDeadlines;
    mapping(string => uint64) public betSchedules;
    
    // Time of creation of the bet
    mapping(string => uint256) public betCreationTime;
    
    uint256 betsNumber;

    // There's a 0.00001 BTC fixed commission transferred to the contract's creator for every placed bet
    uint256 public fixedCommission = 10000000000000;
    
    // Minimum entry for all bets, bet creators cannot set it lower than this 
    uint256 public minimumBet = fixedCommission * 2;
    
    // Custom minimum entry for each bet, set by their creator
    mapping(string => uint256) public betMinimums;
    
    // Keep track of all createdBets to prevent duplicates
    mapping(string => bool) public createdBets;
    
    // Once a query is executed by the oracle, associate its ID with the bet's ID to handle updating the bet's state in __callback
    mapping(bytes32 => string) public queryBets;
    
    // Keep track of all owners to handle commission fees
    mapping(string => address payable) public betOwners; 
    mapping(string => uint256) public betCommissions;
    
    // For each bet, how much each has each user put into that bet's pool?
    mapping(string => mapping(address => uint256)) public userPools;
    
    // For each bet, which is the timestamp of last bet of each user put into that bet's pool?
    mapping(string => mapping(string => mapping(address => uint256))) public lastBetTimePools;

    // What is the total pooled per bet?
    mapping(string => uint256) public betPools;
    
    /* To help people avoid overpaying for the oracle contract querying service,
    its last price is saved and then suggested in the frontend. */
    mapping(string => uint256) public lastQueryPrice;
    
    // Queries can't be scheduled more than 60 days in the future
    uint64 constant scheduleThreshold = 60 * 24 * 60 * 60;

    /* Provable's API requires some initial funds to cover the cost of the query. 
    If they are not enough to pay for it, the user should be informed and their funds returned. */
    event LackingFunds(address indexed sender, uint256 funds);    
    
    /* Contains all the information that does not need to be saved as a state variable, 
    but which can prove useful to people taking a look at the bet in the frontend. */
    event CreatedBet(string indexed _id, uint256 initialPool, string description, string query);
    
    event BetsList(uint256 indexed numberid, string id, string description);

    function changeFixedCommission(uint256 _newAmount) public {
        require(msg.sender == contractCreator,"only owner function");
        fixedCommission = _newAmount;
        minimumBet = fixedCommission * 2;
    }
    
      /**
   * @dev Converts the string to lowercase
   */
  function toLower(string memory str) public pure returns (string memory){
    bytes memory bStr = bytes(str);
    bytes memory bLower = new bytes(bStr.length);

    for (uint i = 0; i < bStr.length; i++) {
      // Uppercase character
      if ((uint8(bStr[i]) >= 65) && (uint8(bStr[i]) <= 90)) {
        bLower[i] = bytes1(uint8(bStr[i]) + 32);
      } else {
        bLower[i] = bStr[i];
      }
    }

    return string(bLower);
  }


    function createBet(string memory betType, string memory betId, string calldata query, uint64 deadline, uint64 schedule, uint256 commission, uint256 minimum, uint256 initialPool, string calldata description) public payable {
        
        require(
            bytes(betId).length > 0 
            && deadline > block.timestamp // Bet can't be set in the past
            && deadline <= schedule // Users should only be able to place bets before it is actually executed
            && schedule < block.timestamp + scheduleThreshold
            && msg.value >= initialPool
            && commission > 1 // Commission can't be higher than 50%
            && minimum >= minimumBet
            && !createdBets[betId], // Can't have duplicate bets
        "Unable to create bet, check arguments.");
        
        // The remaining balance should be enough to cover the cost of the smart oracle query
        uint256 balance = msg.value - initialPool;
        
        lastQueryPrice[betType] = provable_getPrice(betType);
        if (lastQueryPrice[betType] > balance) {
            emit LackingFunds(msg.sender, lastQueryPrice[betType]);
            (bool success,) = msg.sender.call{value: msg.value}("");
            require(success, "Error when returning funds to bet owner.");
            return;
        }
        
        // Bet creation should succeed from this point onward 
        createdBets[betId] = true;
        
        /* Even though the oracle query is scheduled to run in the future, 
        it immediately returns a query ID which we associate with the newly created bet. */
        bytes32 queryId = provable_query(schedule, betType, query);
        queryBets[queryId] = betId;
        
        // Nothing fancy going on here, just boring old state updates
        betCreationTime[betId] = block.timestamp;
        betOwners[betId] = payable(msg.sender);
        betCommissions[betId] = commission;
        betDeadlines[betId] = deadline;
        betSchedules[betId] = schedule;
        betMinimums[betId] = minimum;
        
        /* By adding the initial pool to the bet creator's, 
        but not associating it with any results, we allow the creator to incentivize 
        people to participate without needing to place a bet themselves. */
        userPools[betId][msg.sender] += initialPool;
        betPools[betId] = initialPool;

        emit CreatedBet(betId, initialPool, description, query);
   
        betsNumber++;
        emit BetsList(betsNumber,betId, description);
   
    }
    
    // For each bet, how much is the total pooled per result?
    mapping(string => mapping(string => uint256)) public resultPools;
      
    // For each bet, track how much each user has put into each result
    mapping(string => mapping(address => mapping(string => uint256))) public userBets;


    // The table representing each bet's pool is populated according to these events.
    event PlacedBets(address indexed user, string indexed _id, string id, string[] results);
    
    function placeBets(string calldata betId, string[] calldata results, uint256[] calldata amounts) public payable nonReentrant {
      
        require(
            results.length > 0 
            && results.length == amounts.length 
            && createdBets[betId] 
            && !finishedBets[betId] 
            && betDeadlines[betId] >= block.timestamp,
        "Unable to place bets, check arguments.");
        
        uint256 total = msg.value;
        for (uint i = 0; i < results.length; i++) {
        
            /* More than one bet can be placed at the same time, 
            need to be careful the transaction funds are never less than all combined bets.
            When the oracle fails an empty string is returned, 
            so by not allowing anyone to bet on an empty string bets can be refunded if an error happens. */
            uint256 bet = amounts[i];

            require(
                bytes(toLower(results[i])).length > 0 
                && total >= bet 
                && bet >= betMinimums[betId],
            "Attempted to place invalid bet, check amounts and results");
            
            total -= bet;
            
            bet -= fixedCommission;
            
            // Update all required state
            resultPools[betId][toLower(results[i])] += bet;
            userPools[betId][msg.sender] += bet;
            lastBetTimePools[betId][toLower(results[i])][msg.sender] = block.timestamp;
            betPools[betId] += bet;
            userBets[betId][msg.sender][toLower(results[i])] += bet;
        }
        
        // Fixed commission transfer
        (bool success,) = contractCreator.call{value: fixedCommission * results.length}("");
        require(success, "Failed to transfer fixed commission to contract creator.");
        
        emit PlacedBets(msg.sender, betId, betId, results);
    }

    // For each bet, track which users have already claimed their potential reward
    mapping(string => mapping(address => bool)) public claimedBets;
    
    /* If the oracle service's scheduled callback was not executed after 5 days, 
    a user can reclaim his funds after the bet's execution threshold has passed. 
    Note that even if the callback execution is delayed,
    Provable's oracle should've extracted the result at the originally scheduled time. */
    uint64 constant betThreshold = 5 * 24 * 60 * 60;
    
    
    // If the user wins the bet, let them know along with the reward amount.
    event WonBet(address indexed winner, uint256 won);
    
    // If the user lost no funds are claimable.
    event LostBet(address indexed loser);
    
    /* If no one wins the bet the funds can be refunded to the user, 
    after the bet creator's takes their cut. */
    event UnwonBet(address indexed refunded);

    function getTimeBonus(string calldata betId, uint256 timestamp) public view returns(uint256) {

        uint256 timeRelation = (1000 - ((timestamp - betCreationTime[betId])*1000) / (betDeadlines[betId] - betCreationTime[betId]));

        return timeRelation;

    }
    
    function getEarnEstimation(string calldata betId, uint256 amount,string memory result,uint256 timestamp) public view returns(uint256) {

            uint256 timeRelation = 1000 - ((timestamp - betCreationTime[betId])*1000) / (betDeadlines[betId] - betCreationTime[betId]);

            // How much did everyone pool into this result?
            uint256 winnerPool = resultPools[betId][result] + amount;
            
            uint256 loserPool = betPools[betId] - winnerPool;

            uint256 reward;

            if( timeRelation < 250 ){

                reward = (loserPool / (winnerPool / amount) + amount)*90/100;
            
            } else if (timeRelation >= 250 && timeRelation <= 850){

                reward = (loserPool / (winnerPool / amount) + amount)*95/100;

            } else if (timeRelation > 850){

                reward = loserPool / (winnerPool / amount) + amount;

            }

        return reward;

    }

    function claimBet(string calldata betId) public nonReentrant {
        
        bool betExpired = betSchedules[betId] + betThreshold < block.timestamp;
        
        // If the bet has not finished but its threshold has been reached, let the user get back their funds
        require(
            (finishedBets[betId] || betExpired) 
            && !claimedBets[betId][msg.sender] 
            && userPools[betId][msg.sender] != 0,
        "Invalid bet state while claiming reward.");
        
        claimedBets[betId][msg.sender] = true;
        
        // What's the final result?
        string memory result = betResults[betId];
        
        // Did the user bet on the correct result?
        uint256 userBet = userBets[betId][msg.sender][result];
        
        // What time the user has bet last?
        uint256 betTimestamp = lastBetTimePools[betId][result][msg.sender];
        
        // How much did everyone pool into the correct result?
        uint256 winnerPool = resultPools[betId][result];
        
        uint256 reward;
        
        // If no one won then all bets are refunded
        if (winnerPool == 0) {
            emit UnwonBet(msg.sender);
            reward = userPools[betId][msg.sender];
        } else if (userBet != 0) {
            // User won the bet and receives their corresponding share of the loser's pool
            uint256 loserPool = betPools[betId] - winnerPool;
            
            
            uint256 timeRelation = 1000 - ((betTimestamp - betCreationTime[betId])*1000) / (betDeadlines[betId] - betCreationTime[betId]);
            
            if( timeRelation < 250 ){
                
                // Late Bet

                // User gets their corresponding fraction of the loser's pool, along with their original bet
                reward = (loserPool / (winnerPool / userBet) + userBet)*90/100;
                
                uint256 fee = (loserPool / (winnerPool / userBet) + userBet)*10/100;

                (bool successFee,) = contractCreator.call{value: fee}("");
                require(successFee, "Failed to transfer commission to whales bet.");

            
            } else if (timeRelation >= 250 && timeRelation <= 850){

                // Middle Bet

                // User gets their corresponding fraction of the loser's pool, along with their original bet
                reward = (loserPool / (winnerPool / userBet) + userBet)*95/100;

                uint256 fee = (loserPool / (winnerPool / userBet) + userBet)*5/100;

                (bool successFee,) = contractCreator.call{value: fee}("");
                require(successFee, "Failed to transfer commission to whales bet.");

            } else if (timeRelation > 850){

                // Early Birds Bet

                // User gets their corresponding fraction of the loser's pool, along with their original bet
                reward = loserPool / (winnerPool / userBet) + userBet;

            }

            emit WonBet(msg.sender, reward);

        } else {
            emit LostBet(msg.sender);
            return;
        }
        
        // Bet owner gets their commission
        uint256 ownerFee = reward / betCommissions[betId];
        reward -= ownerFee;
        (bool success,) = msg.sender.call{value: reward}("");
        require(success, "Failed to transfer reward to user.");
        (success,) = betOwners[betId].call{value: ownerFee}("");
        require(success, "Failed to transfer commission to bet owner.");
    }
      
    // Keep track of when a bet ends and what its result was
    mapping(string => bool) public finishedBets;
    mapping(string => string) public betResults;
  
    // Function executed by Provable's oracle when the bet is scheduled to run
    function __callback(bytes32 queryId, string memory result) public {
        string memory betId = queryBets[queryId];
        
        /* Callback is sometimes executed twice,  so we add an additional check
        to make sure state is only modified the first time. */
        require(msg.sender == provable_cbAddress() && !finishedBets[betId]);
        
        betResults[betId] = toLower(result);
        finishedBets[betId] = true;
    }
}