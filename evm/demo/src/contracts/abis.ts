
export const FACTORY_ABI = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "_settlementSystem",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_rover",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_aux",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_basket",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "auctionImplementation",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "auctions",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "aux",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract Aux"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "basket",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract Basket"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "configs",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "name",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "symbol",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "initialPricePerToken",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "auctionDuration",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "creatorAuctions",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "defaultDuration",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "defaultInitialPrice",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "deployPredictionMarket",
    "inputs": [
      {
        "name": "question",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "resolutionTime",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "config",
        "type": "tuple",
        "internalType": "struct AuctionFactory.LaunchConfig",
        "components": [
          {
            "name": "name",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "symbol",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "initialPricePerToken",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "auctionDuration",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "deployRapBattleMarket",
    "inputs": [
      {
        "name": "challenger",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "challenged",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "responseDeadline",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "config",
        "type": "tuple",
        "internalType": "struct AuctionFactory.LaunchConfig",
        "components": [
          {
            "name": "name",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "symbol",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "initialPricePerToken",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "auctionDuration",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "deploySimplePrediction",
    "inputs": [
      {
        "name": "question",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "daysUntilResolution",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getAuctionInfo",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "config",
        "type": "tuple",
        "internalType": "struct AuctionFactory.LaunchConfig",
        "components": [
          {
            "name": "name",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "symbol",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "initialPricePerToken",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "auctionDuration",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      },
      {
        "name": "isPrediction",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "question",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "currentPrice",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalPoolUSD",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "isActive",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "isResolved",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getAuctions",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address[]",
        "internalType": "address[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getAuctionsByCreator",
    "inputs": [
      {
        "name": "creator",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address[]",
        "internalType": "address[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getInfrastructure",
    "inputs": [],
    "outputs": [
      {
        "name": "_settlement",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_rover",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_aux",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_basket",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "isValidAuction",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "owner",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "protocolFeeRate",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "protocolFeeRecipient",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "renounceOwnership",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "rover",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract Rover"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "setDefaults",
    "inputs": [
      {
        "name": "_initialPrice",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "_duration",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setProtocolFee",
    "inputs": [
      {
        "name": "_rate",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "_recipient",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "settlementSystem",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract Settlement"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "transferOwnership",
    "inputs": [
      {
        "name": "newOwner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "AuctionDeployed",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "creator",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "name",
        "type": "string",
        "indexed": false,
        "internalType": "string"
      },
      {
        "name": "isPrediction",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      },
      {
        "name": "question",
        "type": "string",
        "indexed": false,
        "internalType": "string"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "DefaultsUpdated",
    "inputs": [
      {
        "name": "initialPrice",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "duration",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "OwnershipTransferred",
    "inputs": [
      {
        "name": "previousOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "newOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ProtocolFeeUpdated",
    "inputs": [
      {
        "name": "rate",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "recipient",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "ERC1167FailedCreateClone",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OwnableInvalidOwner",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "OwnableUnauthorizedAccount",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ]
  }
];

export const HELPERS_ABI = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "_factory",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_settlement",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_basket",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "basket",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract Basket"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "betNo",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "betNoWithSlippage",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      },
      {
        "name": "maxPricePerShare",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "betWithContent",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      },
      {
        "name": "pricePerShare",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "isYes",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "contentURI",
        "type": "string",
        "internalType": "string"
      }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "betWithUSDTarget",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      },
      {
        "name": "pricePerShare",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "isYes",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "desiredUSDAmount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "betYes",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "betYesWithSlippage",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      },
      {
        "name": "maxPricePerShare",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "claimAll",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "claimAndConvert",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      },
      {
        "name": "convertToToken",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "convertAmount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "createRapBattle",
    "inputs": [
      {
        "name": "challenger",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "challenged",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "hoursToRespond",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "createSimplePrediction",
    "inputs": [
      {
        "name": "question",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "daysUntilResolution",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "factory",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract AuctionFactory"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getBettingAdvice",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      },
      {
        "name": "desiredPositionUSD",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct AuctionHelpers.BettingAdvice",
        "components": [
          {
            "name": "isGoodTiming",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "reason",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "suggestedAmount",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "expectedTokens",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "minimumPrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "currentVelocityPenalty",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getMEVProtectionInfo",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      },
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "desiredSharesUSD",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct AuctionHelpers.MEVProtectionInfo",
        "components": [
          {
            "name": "userVelocity",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "dynamicFeeBps",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "minimumPriceRequired",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "batchWindowRemaining",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "wouldTriggerPenalty",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getMarketHealth",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      }
    ],
    "outputs": [
      {
        "name": "isHealthy",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "status",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "activityScore",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "warnings",
        "type": "string[]",
        "internalType": "string[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getMarketOverview",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct AuctionHelpers.SimpleMarketView",
        "components": [
          {
            "name": "question",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "currentPrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "timeRemaining",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "totalYesShares",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "totalNoShares",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "totalPoolUSD",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "impliedProbability",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "isActive",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "isResolved",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "outcome",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "epochSharesRemaining",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "minimumPriceFor10Percent",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getOptimalStrategy",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      },
      {
        "name": "budget",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "targetSide",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "outputs": [
      {
        "name": "recommendedPrice",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "recommendedEpoch",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "strategy",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getUserPosition",
    "inputs": [
      {
        "name": "auction",
        "type": "address",
        "internalType": "contract Auction"
      },
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct AuctionHelpers.UserPosition",
        "components": [
          {
            "name": "yesShares",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "noShares",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "total404Tokens",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "estimatedPayout",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "canClaimPayout",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "canClaimRefund",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "avgStrikePrice",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "settlement",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract Settlement"
      }
    ],
    "stateMutability": "view"
  }
];

export const SETTLEMENT_ABI = [
  {
    "type": "constructor",
    "inputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "activeDisputes",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "activeProposalId",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "appeal",
    "inputs": [
      {
        "name": "_disputeID",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "appealCost",
    "inputs": [
      {
        "name": "_disputeID",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "appealPeriod",
    "inputs": [
      {
        "name": "_disputeID",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "start",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "end",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "arbitrationCost",
    "inputs": [
      {
        "name": "",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "auctionFactory",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "basketContract",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "canSettle",
    "inputs": [
      {
        "name": "market",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "canSettleResult",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "reason",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "claimStakes",
    "inputs": [
      {
        "name": "market",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "proposalId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "createDispute",
    "inputs": [
      {
        "name": "_choices",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "_extraData",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [
      {
        "name": "disputeID",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "createMetaEvidence",
    "inputs": [
      {
        "name": "_title",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "_description",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "_question",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "_rulingOptions",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "_fileURI",
        "type": "string",
        "internalType": "string"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "createPredictionMarketMetaEvidence",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "currentRuling",
    "inputs": [
      {
        "name": "_disputeID",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "disputeCount",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "disputeProposal",
    "inputs": [
      {
        "name": "market",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "proposalId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "evidence",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "evidenceHash",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "disputeStake",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "disputeId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "disputeRandomBlocks",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "disputeStatus",
    "inputs": [
      {
        "name": "_disputeID",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "enum IArbitrator.DisputeStatus"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "disputes",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "market",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "proposalId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "currentRound",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "createdAt",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "status",
        "type": "uint8",
        "internalType": "enum IArbitrator.DisputeStatus"
      },
      {
        "name": "isFinalized",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "executeProposal",
    "inputs": [
      {
        "name": "market",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "proposalId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "finalizeDispute",
    "inputs": [
      {
        "name": "disputeId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "forceTimeoutResolution",
    "inputs": [
      {
        "name": "disputeId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "fulfillJurySelection",
    "inputs": [
      {
        "name": "disputeId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "headers",
        "type": "bytes[]",
        "internalType": "bytes[]"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getEligibleJurorCount",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getPotentialJurors",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address[]",
        "internalType": "address[]"
      },
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "initialize",
    "inputs": [
      {
        "name": "_basket",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_factory",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "initiateDisputeWithMetaEvidence",
    "inputs": [
      {
        "name": "market",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_metaEvidenceId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "evidence",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "evidenceHash",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "stakeAmount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "disputeId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "isEligibleJuror",
    "inputs": [
      {
        "name": "juror",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "lastActivity",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "marketDispute",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "metaEvidenceCount",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "metaEvidenceURIs",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "opposeProposal",
    "inputs": [
      {
        "name": "market",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "proposalId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "proposalCount",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "proposals",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "proposer",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "outcome",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "stake",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "supportStake",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "opposeStake",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "createdAt",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "status",
        "type": "uint8",
        "internalType": "enum Settlement.ProposalStatus"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "proposeSettlement",
    "inputs": [
      {
        "name": "market",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "outcome",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "stakeAmount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "proposalId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "randomnessRequested",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "requestJurySelection",
    "inputs": [
      {
        "name": "disputeId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "rounds",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "votingDeadline",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "verdict",
        "type": "uint8",
        "internalType": "enum Settlement.VoteChoice"
      },
      {
        "name": "finalized",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "appealed",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "submitEvidence",
    "inputs": [
      {
        "name": "_disputeID",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "_evidence",
        "type": "string",
        "internalType": "string"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "submitVote",
    "inputs": [
      {
        "name": "disputeId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "round",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "vote",
        "type": "uint8",
        "internalType": "enum Settlement.VoteChoice"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "supportProposal",
    "inputs": [
      {
        "name": "market",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "proposalId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "totalVotes",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "wrongVotes",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "event",
    "name": "AppealDecision",
    "inputs": [
      {
        "name": "_disputeID",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "_arbitrable",
        "type": "address",
        "indexed": true,
        "internalType": "contract IArbitrable"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "AppealPossible",
    "inputs": [
      {
        "name": "_disputeID",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "_arbitrable",
        "type": "address",
        "indexed": true,
        "internalType": "contract IArbitrable"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "DisputeAppealed",
    "inputs": [
      {
        "name": "disputeId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "round",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "DisputeCreated",
    "inputs": [
      {
        "name": "disputeId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "market",
        "type": "address",
        "indexed": false,
        "internalType": "contract IArbitrable"
      },
      {
        "name": "choices",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "DisputeCreation",
    "inputs": [
      {
        "name": "_disputeID",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "_arbitrable",
        "type": "address",
        "indexed": true,
        "internalType": "contract IArbitrable"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "DisputeEvent",
    "inputs": [
      {
        "name": "_arbitrator",
        "type": "address",
        "indexed": true,
        "internalType": "contract IArbitrator"
      },
      {
        "name": "_disputeID",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "_metaEvidenceID",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "_evidenceGroupID",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Evidence",
    "inputs": [
      {
        "name": "_arbitrator",
        "type": "address",
        "indexed": true,
        "internalType": "contract IArbitrator"
      },
      {
        "name": "_evidenceGroupID",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "_party",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "_evidence",
        "type": "string",
        "indexed": false,
        "internalType": "string"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "JurorSelected",
    "inputs": [
      {
        "name": "juror",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "disputeId",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "round",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "JurorSlashed",
    "inputs": [
      {
        "name": "juror",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "JuryRequested",
    "inputs": [
      {
        "name": "disputeId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "round",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "JurySelected",
    "inputs": [
      {
        "name": "disputeId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "round",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "jurors",
        "type": "address[]",
        "indexed": false,
        "internalType": "address[]"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "MetaEvidence",
    "inputs": [
      {
        "name": "_metaEvidenceID",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "_evidence",
        "type": "string",
        "indexed": false,
        "internalType": "string"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ProposalCreated",
    "inputs": [
      {
        "name": "market",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "proposalId",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "proposer",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "outcome",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      },
      {
        "name": "stake",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ProposalDisputed",
    "inputs": [
      {
        "name": "market",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "proposalId",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "disputeId",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ProposalExecuted",
    "inputs": [
      {
        "name": "market",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "proposalId",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ProposalOpposed",
    "inputs": [
      {
        "name": "market",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "proposalId",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "opposer",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ProposalSupported",
    "inputs": [
      {
        "name": "market",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "proposalId",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "supporter",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "VerdictReached",
    "inputs": [
      {
        "name": "disputeId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "round",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "verdict",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum Settlement.VoteChoice"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "VoteSubmitted",
    "inputs": [
      {
        "name": "disputeId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "round",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "juror",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  }
];

export const AUCTION_ABI = [
  {
    "type": "constructor",
    "inputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "receive",
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "DOMAIN_SEPARATOR",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "ID_ENCODING_PREFIX",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "allBids",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "bidder",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "usdAmount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "pricePerShare",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "sharesRequested",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "sharesAllocated",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "epochIndex",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "timestamp",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "isYes",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "processed",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "allowance",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "approve",
    "inputs": [
      {
        "name": "spender_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "valueOrId_",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "authorizedContentSubmitters",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "auxSystem",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract Aux"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "balanceOf",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "bettingWindowClosed",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "bidVelocity",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "calculateFairPrice",
    "inputs": [
      {
        "name": "epochIndex",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "calculatePredictionPayout",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "payoutUSD",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "claimForceMajeurRefund",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "claimPredictionPayout",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "clearEpoch",
    "inputs": [
      {
        "name": "epochIndex",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "commitBid",
    "inputs": [
      {
        "name": "commitment",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "commitBidWithToken",
    "inputs": [
      {
        "name": "commitment",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "commitments",
    "inputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "committedETH",
    "inputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "contentSubmissionCount",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "currentEpochIndex",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "decimals",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "disputeId",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "enableContentRefunds",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "epochExtensions",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "epochMaxPrice",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "epochMinPrice",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "erc20Approve",
    "inputs": [
      {
        "name": "spender_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "value_",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "erc20BalanceOf",
    "inputs": [
      {
        "name": "owner_",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "erc20TotalSupply",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "erc20TransferFrom",
    "inputs": [
      {
        "name": "from_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "to_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "value_",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "erc721Approve",
    "inputs": [
      {
        "name": "spender_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "id_",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "erc721BalanceOf",
    "inputs": [
      {
        "name": "owner_",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "erc721TotalSupply",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "erc721TransferExempt",
    "inputs": [
      {
        "name": "target_",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "erc721TransferFrom",
    "inputs": [
      {
        "name": "from_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "to_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "id_",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "forceMajeurRefunds",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getApproved",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getBidDetails",
    "inputs": [
      {
        "name": "bidId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "bidder",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "usdAmount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "pricePerShare",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "sharesAllocated",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "isYes",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "processed",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getContentSubmissions",
    "inputs": [],
    "outputs": [
      {
        "name": "submitters",
        "type": "address[]",
        "internalType": "address[]"
      },
      {
        "name": "",
        "type": "string[]",
        "internalType": "string[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getCurrentEpochInfo",
    "inputs": [],
    "outputs": [
      {
        "name": "index",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "currentPrice",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "timeRemaining",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "bidCount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "isActive",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getERC721QueueLength",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getERC721TokensInQueue",
    "inputs": [
      {
        "name": "start_",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "count_",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256[]",
        "internalType": "uint256[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getEpoch",
    "inputs": [
      {
        "name": "index",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "startTime",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "endTime",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "sharesAvailable",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "sharesAllocated",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalBids",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalGasCollected",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "cleared",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "gasCompensated",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "clearer",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getMinimumPriceForAllocation",
    "inputs": [
      {
        "name": "totalSharesWanted",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "epochShares",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "getParticipantCount",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getParticipants",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address[]",
        "internalType": "address[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getPredictionConfig",
    "inputs": [],
    "outputs": [
      {
        "name": "question",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "resolutionTime",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "resolved",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "outcome",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "requiresContent",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "contentDeadline",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "minParticipants",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalYesShares",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalNoShares",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalPoolUSD",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getPredictionSummary",
    "inputs": [],
    "outputs": [
      {
        "name": "question",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "totalYesShares",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalNoShares",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalPoolUSD",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "impliedProbability",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "resolved",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "outcome",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getUserBidIds",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256[]",
        "internalType": "uint256[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getUserPosition",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "yesShares",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "noShares",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "total404Tokens",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "estimatedPayout",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "hasParticipated",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "initialize",
    "inputs": [
      {
        "name": "_params",
        "type": "tuple",
        "internalType": "struct Auction.AuctionParams",
        "components": [
          {
            "name": "name",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "symbol",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "auctionDuration",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "totalEpochs",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "owner",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "settlementSystem",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "rover",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "aux",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "basket",
            "type": "address",
            "internalType": "address"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "initializePredictionMarket",
    "inputs": [
      {
        "name": "question_",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "resolutionTime_",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "metaEvidenceId_",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "requiresContent_",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "contentDeadline_",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "minParticipants_",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "isApprovedForAll",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "lastBidTime",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "metaEvidenceId",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "minted",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "name",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "nextBidId",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "nonces",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "owned",
    "inputs": [
      {
        "name": "owner_",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256[]",
        "internalType": "uint256[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "ownerOf",
    "inputs": [
      {
        "name": "id_",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "erc721Owner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "params",
    "inputs": [],
    "outputs": [
      {
        "name": "name",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "symbol",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "auctionDuration",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalEpochs",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "settlementSystem",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "rover",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "aux",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "basket",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "participantCount",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "participants",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "permit",
    "inputs": [
      {
        "name": "owner_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "spender_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "value_",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "deadline_",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "v_",
        "type": "uint8",
        "internalType": "uint8"
      },
      {
        "name": "r_",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "s_",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "placePredictionBid",
    "inputs": [
      {
        "name": "pricePerShare",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "isYes",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "placePredictionBidWithContent",
    "inputs": [
      {
        "name": "pricePerShare",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "isYes",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "contentURI",
        "type": "string",
        "internalType": "string"
      }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "placePredictionBidWithToken",
    "inputs": [
      {
        "name": "pricePerShare",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "isYes",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "predictionConfig",
    "inputs": [],
    "outputs": [
      {
        "name": "question",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "resolutionTime",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "resolved",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "outcome",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "totalYesShares",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalNoShares",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalPoolUSD",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "requiresContent",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "contentDeadline",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "minParticipants",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "protocolTreasury",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "revealBid",
    "inputs": [
      {
        "name": "pricePerShare",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "isYes",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "nonce",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "rule",
    "inputs": [
      {
        "name": "_disputeID",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "_ruling",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "safeTransferFrom",
    "inputs": [
      {
        "name": "from_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "to_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "id_",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "safeTransferFrom",
    "inputs": [
      {
        "name": "from_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "to_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "id_",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "data_",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setApprovalForAll",
    "inputs": [
      {
        "name": "operator_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "approved_",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setAuthorizedSubmitters",
    "inputs": [
      {
        "name": "submitter1",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "submitter2",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setSelfERC721TransferExempt",
    "inputs": [
      {
        "name": "state_",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "settlementSystem",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract Settlement"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "supportsInterface",
    "inputs": [
      {
        "name": "interfaceId",
        "type": "bytes4",
        "internalType": "bytes4"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "symbol",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "tokenURI",
    "inputs": [
      {
        "name": "id",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalGasFeesCollected",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalGasFeesDistributed",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalSupply",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "transfer",
    "inputs": [
      {
        "name": "to_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "value_",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "transferFrom",
    "inputs": [
      {
        "name": "from_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "to_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "valueOrId_",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "units",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "userBidIds",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "event",
    "name": "Approval",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "spender",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "value",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Approval",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "spender",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "id",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ApprovalForAll",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "operator",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "approved",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "BettingWindowClosed",
    "inputs": [
      {
        "name": "totalEpochs",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "BidCommitted",
    "inputs": [
      {
        "name": "bidder",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "commitment",
        "type": "bytes32",
        "indexed": false,
        "internalType": "bytes32"
      },
      {
        "name": "ethAmount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "BidPlaced",
    "inputs": [
      {
        "name": "bidder",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "usdAmount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "pricePerShare",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "isYes",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      },
      {
        "name": "epoch",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "bidId",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "BidRevealed",
    "inputs": [
      {
        "name": "bidder",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "usdAmount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "pricePerShare",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "isYes",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ContentSubmitted",
    "inputs": [
      {
        "name": "submitter",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "contentURI",
        "type": "string",
        "indexed": false,
        "internalType": "string"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "EpochCleared",
    "inputs": [
      {
        "name": "epoch",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "sharesAllocated",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "clearer",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "gasCompensation",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "EpochExtended",
    "inputs": [
      {
        "name": "epoch",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "newEndTime",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ForceMajeurDeclared",
    "inputs": [],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ParticipantAdded",
    "inputs": [
      {
        "name": "participant",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PayoutClaimed",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "wasForceMajeur",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PredictionResolved",
    "inputs": [
      {
        "name": "outcome",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Ruling",
    "inputs": [
      {
        "name": "_arbitrator",
        "type": "address",
        "indexed": true,
        "internalType": "contract IArbitrator"
      },
      {
        "name": "_disputeID",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "_ruling",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Transfer",
    "inputs": [
      {
        "name": "from",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Transfer",
    "inputs": [
      {
        "name": "from",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "id",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "AlreadyExists",
    "inputs": []
  },
  {
    "type": "error",
    "name": "DecimalsTooLow",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InsufficientAllowance",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidApproval",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidExemption",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidOperator",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidRecipient",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidSender",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidSigner",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidSpender",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidTokenId",
    "inputs": []
  },
  {
    "type": "error",
    "name": "MintLimitReached",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotFound",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OwnedIndexOverflow",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PermitDeadlineExpired",
    "inputs": []
  },
  {
    "type": "error",
    "name": "QueueEmpty",
    "inputs": []
  },
  {
    "type": "error",
    "name": "QueueFull",
    "inputs": []
  },
  {
    "type": "error",
    "name": "QueueOutOfBounds",
    "inputs": []
  },
  {
    "type": "error",
    "name": "RecipientIsERC721TransferExempt",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  },
  {
    "type": "error",
    "name": "Unauthorized",
    "inputs": []
  },
  {
    "type": "error",
    "name": "UnsafeRecipient",
    "inputs": []
  }
];
