/**
 * Program IDL in camelCase format in order to be used in JS/TS.
 *
 * Note that this is only a type helper and is not the actual IDL. The original
 * IDL can be found at `target/idl/quid.json`.
 */
export type Quid = {
  "address": "QDgHUZjtccRjKZ63MBvW8uzKR7qcqjpRfGhNSEGfDu9",
  "metadata": {
    "name": "quid",
    "version": "0.1.0",
    "spec": "0.1.0"
  },
  "instructions": [
    {
      "name": "deposit",
      "discriminator": [
        242,
        35,
        198,
        137,
        82,
        225,
        242,
        182
      ],
      "accounts": [
        {
          "name": "signer",
          "writable": true,
          "signer": true
        },
        {
          "name": "mint"
        },
        {
          "name": "bank",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "account",
                "path": "mint"
              }
            ]
          }
        },
        {
          "name": "bankTokenAccount",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  118,
                  97,
                  117,
                  108,
                  116
                ]
              },
              {
                "kind": "account",
                "path": "mint"
              }
            ]
          }
        },
        {
          "name": "customerAccount",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "account",
                "path": "signer"
              }
            ]
          }
        },
        {
          "name": "customerTokenAccount",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "account",
                "path": "signer"
              },
              {
                "kind": "account",
                "path": "tokenProgram"
              },
              {
                "kind": "account",
                "path": "mint"
              }
            ],
            "program": {
              "kind": "const",
              "value": [
                140,
                151,
                37,
                143,
                78,
                36,
                137,
                241,
                187,
                61,
                16,
                41,
                20,
                142,
                13,
                131,
                11,
                90,
                19,
                153,
                218,
                255,
                16,
                132,
                4,
                142,
                123,
                216,
                219,
                233,
                248,
                89
              ]
            }
          }
        },
        {
          "name": "tokenProgram"
        },
        {
          "name": "associatedTokenProgram",
          "address": "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
        },
        {
          "name": "systemProgram",
          "address": "11111111111111111111111111111111"
        }
      ],
      "args": [
        {
          "name": "amount",
          "type": "u64"
        },
        {
          "name": "ticker",
          "type": "string"
        }
      ]
    },
    {
      "name": "liquidate",
      "discriminator": [
        223,
        179,
        226,
        125,
        48,
        46,
        39,
        74
      ],
      "accounts": [
        {
          "name": "liquidator",
          "writable": true,
          "signer": true
        },
        {
          "name": "liquidating",
          "docs": [
            "no reads/writes or assumptions beyond `.key()`"
          ]
        },
        {
          "name": "mint"
        },
        {
          "name": "bank",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "account",
                "path": "mint"
              }
            ]
          }
        },
        {
          "name": "bankTokenAccount",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  118,
                  97,
                  117,
                  108,
                  116
                ]
              },
              {
                "kind": "account",
                "path": "mint"
              }
            ]
          }
        },
        {
          "name": "customerAccount",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "account",
                "path": "liquidating"
              }
            ]
          }
        },
        {
          "name": "liquidatorTokenAccount",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "account",
                "path": "liquidator"
              },
              {
                "kind": "account",
                "path": "tokenProgram"
              },
              {
                "kind": "account",
                "path": "mint"
              }
            ],
            "program": {
              "kind": "const",
              "value": [
                140,
                151,
                37,
                143,
                78,
                36,
                137,
                241,
                187,
                61,
                16,
                41,
                20,
                142,
                13,
                131,
                11,
                90,
                19,
                153,
                218,
                255,
                16,
                132,
                4,
                142,
                123,
                216,
                219,
                233,
                248,
                89
              ]
            }
          }
        },
        {
          "name": "tokenProgram"
        },
        {
          "name": "associatedTokenProgram",
          "address": "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
        },
        {
          "name": "systemProgram",
          "address": "11111111111111111111111111111111"
        }
      ],
      "args": [
        {
          "name": "ticker",
          "type": "string"
        }
      ]
    },
    {
      "name": "withdraw",
      "discriminator": [
        183,
        18,
        70,
        156,
        148,
        109,
        161,
        34
      ],
      "accounts": [
        {
          "name": "signer",
          "writable": true,
          "signer": true
        },
        {
          "name": "mint"
        },
        {
          "name": "bank",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "account",
                "path": "mint"
              }
            ]
          }
        },
        {
          "name": "bankTokenAccount",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  118,
                  97,
                  117,
                  108,
                  116
                ]
              },
              {
                "kind": "account",
                "path": "mint"
              }
            ]
          }
        },
        {
          "name": "customerAccount",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "account",
                "path": "signer"
              }
            ]
          }
        },
        {
          "name": "customerTokenAccount",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "account",
                "path": "signer"
              },
              {
                "kind": "account",
                "path": "tokenProgram"
              },
              {
                "kind": "account",
                "path": "mint"
              }
            ],
            "program": {
              "kind": "const",
              "value": [
                140,
                151,
                37,
                143,
                78,
                36,
                137,
                241,
                187,
                61,
                16,
                41,
                20,
                142,
                13,
                131,
                11,
                90,
                19,
                153,
                218,
                255,
                16,
                132,
                4,
                142,
                123,
                216,
                219,
                233,
                248,
                89
              ]
            }
          }
        },
        {
          "name": "tokenProgram"
        },
        {
          "name": "associatedTokenProgram",
          "address": "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
        },
        {
          "name": "systemProgram",
          "address": "11111111111111111111111111111111"
        }
      ],
      "args": [
        {
          "name": "amount",
          "type": "i64"
        },
        {
          "name": "ticker",
          "type": "string"
        },
        {
          "name": "exposure",
          "type": "bool"
        }
      ]
    }
  ],
  "accounts": [
    {
      "name": "depositor",
      "discriminator": [
        219,
        74,
        92,
        245,
        101,
        149,
        45,
        97
      ]
    },
    {
      "name": "depository",
      "discriminator": [
        241,
        199,
        229,
        248,
        165,
        69,
        224,
        187
      ]
    }
  ],
  "errors": [
    {
      "code": 6000,
      "name": "insufficientFunds",
      "msg": "Insufficient funds to withdraw."
    },
    {
      "code": 6001,
      "name": "notUndercollateralised",
      "msg": "Depositor is not under-collateralised."
    },
    {
      "code": 6002,
      "name": "maxPositionsReached",
      "msg": "Evict one of your other positons before trying to add a new one."
    },
    {
      "code": 6003,
      "name": "noPrice",
      "msg": "Think twice, make sure you pass in a price."
    },
    {
      "code": 6004,
      "name": "tickers",
      "msg": "Must pass in ticker(s)."
    },
    {
      "code": 6005,
      "name": "tooSoon",
      "msg": "Don't call in too often...show stops then."
    },
    {
      "code": 6006,
      "name": "takeProfit",
      "msg": "You're ahead...take profit instead."
    },
    {
      "code": 6007,
      "name": "unknownSymbol",
      "msg": "Imported a ticker that's not yet supported."
    },
    {
      "code": 6008,
      "name": "undercollateralised",
      "msg": "Re-capitalise; your position is under-collateralised."
    },
    {
      "code": 6009,
      "name": "invalidAmount",
      "msg": "Slow it up...amount is either not enough or too much."
    },
    {
      "code": 6010,
      "name": "invalidUser",
      "msg": "Double-check who you're trying to touch."
    },
    {
      "code": 6011,
      "name": "invalidMint",
      "msg": "We only work with stars here."
    },
    {
      "code": 6012,
      "name": "overExposed",
      "msg": "Your position is over-exposed."
    },
    {
      "code": 6013,
      "name": "underExposed",
      "msg": "Your position is under-exposed."
    },
    {
      "code": 6014,
      "name": "depositFirst",
      "msg": "You must deposit before you can do this."
    }
  ],
  "types": [
    {
      "name": "depositor",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "depositedUsdStar",
            "type": "u64"
          },
          {
            "name": "depositedUsdStarShares",
            "type": "u64"
          },
          {
            "name": "balances",
            "type": {
              "vec": {
                "defined": {
                  "name": "position"
                }
              }
            }
          }
        ]
      }
    },
    {
      "name": "depository",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "totalDeposits",
            "type": "u64"
          },
          {
            "name": "totalDepositShares",
            "type": "u64"
          },
          {
            "name": "interestRate",
            "type": "u64"
          }
        ]
      }
    },
    {
      "name": "position",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "ticker",
            "type": {
              "array": [
                "u8",
                8
              ]
            }
          },
          {
            "name": "pledged",
            "type": "u64"
          },
          {
            "name": "exposure",
            "type": "i64"
          },
          {
            "name": "updated",
            "type": "i64"
          }
        ]
      }
    }
  ],
  "constants": [
    {
      "name": "usdStar",
      "type": "pubkey",
      "value": "6QxnHc15LVbRf8nj6XToxb8RYZQi5P9QvgJ4NDW3yxRc"
    }
  ]
};
