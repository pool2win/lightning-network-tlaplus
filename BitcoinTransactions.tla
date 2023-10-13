------------------------ MODULE BitcoinTransactions ------------------------

(***************************************************************************)
(* This spec captures the actions and states of bitcoin transactions in    *)
(* the context of the bitcoin blockchain.  These actions will be used by   *)
(* the LN Contracts spec and other layer two contract specifications.      *)
(*                                                                         *)
(* The focus of this module is to provide:                                 *)
(*                                                                         *)
(* 1.  Way to generate transactions that accept input and generate outputs *)
(*                                                                         *)
(* 2.  Confirm transactions so that outputs can be spent.                  *)
(*                                                                         *)
(* 3.  Most importantly - provide a way to verify spend conditions without *)
(* building the entire cryptography machinery.  This enables spec authors  *)
(* to focus on what the conditions achieve instead of how those conditions *)
(* are achieved.                                                           *)
(*                                                                         *)
(* Goal A: Move environment / bitcoin transaction actions and variables    *)
(* from Contracts to here                                                  *)
(***************************************************************************)

EXTENDS Sequences,
        Integers,
        TLC,
        SequencesExt

(***************************************************************************)
(* Define constants so that we can define finite sets for inputs, outputs  *)
(* and txids etc.                                                          *)
(***************************************************************************)        
CONSTANTS CSV,          \* Set of CSV values
          VOUT,         \* Set of vout values
          TXID,         \* Set of transaction ids
          AMOUNT,       \* Set of amounts that can be used
          KEY,          \* Set of all keys used for signatures
          HASH          \* Set of all hash preimages

SighashFlag == {"all", "none", "single", "anyonecanpay"}

(***************************************************************************)
(* Set of output types supported for building contracts.                   *)
(*                                                                         *)
(* Each output type will have to provide a means to verify an input trying *)
(* to spend it.                                                            *)
(***************************************************************************)
OutputTypes == {"p2wkh", "multisig", "multisig_with_csv", "hash_lock"}

NoCSV == CHOOSE c: c \notin CSV
NoHash == CHOOSE h: h \notin HASH

Input == [
    txid: TXID,
    index: VOUT,
    sighash_flag: SighashFlag,      \* Parts of transactions covered by signature
    signed_by: Seq(KEY),            \* One or more keys that have signed this input
    hash_preimage: HASH \cup {NoHash}
]

Output == [
    index: VOUT,
    type: OutputTypes,
    keys: Seq(KEY),             \* Sig from these keys is required to spend
    csv: CSV \cup {NoCSV},      \* The CSV should have expired before spend
    hash: HASH \cup {NoHash},   \* Pre-image required to spend
    amount: AMOUNT
]

-----------------------------------------------------------------------------

VARIABLES
    chain_height,
    transactions,
    mempool,
    published

vars == <<chain_height, transactions, mempool, published>>

Init ==
    /\ transactions = [id \in TXID |-> [inputs |-> <<>>, outputs |-> <<>>]]
    /\ chain_height = 0
    /\ mempool = {}
    /\ published = {}
    
TypeOK ==
    /\ transactions \in [TXID -> [inputs: Seq(Input), outputs: Seq(Output)]]
    /\ mempool \in SUBSET TXID
    /\ published \in SUBSET TXID

-----------------------------------------------------------------------------

CreateP2WKHOutput(key, amount) == [
    index |-> 0,
    type |-> "p2wkh",
    keys |-> key,
    csv |-> NoCSV,
    hash |-> NoHash,
    amount |-> amount
]

-----------------------------------------------------------------------------

(***************************************************************************)
(* Add a new coinbase tx to mempool.  No verification is required here as  *)
(* no prevout is being spent.                                              *)
(***************************************************************************)
AddCoinbaseToMempool(id, key, amount) ==
    /\ id \notin mempool
    /\ id \notin published
    /\ transactions' = [transactions EXCEPT ![id] = [inputs |-> <<>>,
                            outputs |-> <<CreateP2WKHOutput(<<key>>, amount)>>]]
    /\ mempool' = mempool \cup {id}
    /\ UNCHANGED <<chain_height, published>>

(***************************************************************************)
(* Confirm coinbase transaction from mempool.                              *)
(***************************************************************************)
ConfirmCoinbaseMempoolTx ==
    \E id \in DOMAIN transactions:
        /\ id \in mempool
        /\ id \notin published
        /\ LET tx == transactions[id]
           IN
            /\ tx.inputs = << >>        \* A coinbase tx, has no inputs.
                                        \* We are not dealing with blocks, so we
                                        \* ignore the block index coinbase check
            /\ published' = published \cup {id}
            /\ mempool' = mempool \ {id}
            /\ chain_height' = chain_height + 1 \* Each tx is in it's own block
        /\ UNCHANGED <<transactions>>

CreateP2WKHTx(spending, output, ix, id, amount) == [
    inputs |-> <<[txid |-> spending,
                index |-> ix,
                sighash_flag |-> "all",
                signed_by |-> output.keys,
                hash_preimage |-> NoHash]>>,
    outputs |-> <<CreateP2WKHOutput(output.keys, amount)>>
]

AddP2WKHToMempool(id, amount) ==
    \E s \in published:
        \E o \in ToSet(transactions[s].outputs):
            /\ id \notin mempool
            /\ id \notin published
            /\ o.type = "p2wkh"
            /\ transactions' = [transactions EXCEPT ![id] =
                                CreateP2WKHTx(s, o, o.index, id, amount)]
            /\ mempool' = mempool \cup {id}
            /\ UNCHANGED <<chain_height, published>>

-----------------------------------------------------------------------------

Next == 
    \/ \E k \in KEY, id \in TXID, a \in AMOUNT: 
        \/ AddCoinbaseToMempool(id, k, a)
    \/ \E id \in TXID, a \in AMOUNT:
        AddP2WKHToMempool(id, a)
    \/ ConfirmCoinbaseMempoolTx

Spec == 
    /\ Init
    /\ [][Next]_<<vars>>
=============================================================================
