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
\* OutputTypes == {"p2wkh", "multisig", "multisig_with_csv", "hash_lock"}
OutputTypes == {"p2wkh", "multisig", "multisig_with_csv"}

NoCSV == CHOOSE c: c \notin CSV
MaxCSV == CHOOSE c \in CSV: \A y \in CSV: c >= y
NoHash == CHOOSE h: h \notin HASH

ChooseKey(k) == CHOOSE e \in KEY: e # k

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
-----------------------------------------------------------------------------

CreateP2WKHOutput(key, amount) == [
    index |-> 0,
    type |-> "p2wkh",
    keys |-> key,
    csv |-> NoCSV,
    hash |-> NoHash,
    amount |-> amount
]

CreateMultisigOutput(keys, amount) == [
    index |-> 0,
    type |-> "multisig",
    keys |-> keys,
    csv |-> NoCSV,
    hash |-> NoHash,
    amount |-> amount
]

CreateMultisigWithCSVOutput(keys, amount) == [
    index |-> 0,
    type |-> "multisig_with_csv",
    keys |-> keys,
    csv |-> MaxCSV,
    hash |-> NoHash,
    amount |-> amount
]

-----------------------------------------------------------------------------

(***************************************************************************)
(* Add a coinbase tx spendable with a pk.  No verification is required     *)
(* here as no prevout is being spent.                                      *)
(***************************************************************************)
AddP2WKHCoinbaseToMempool(id, key, amount) ==
    /\ id \notin mempool
    /\ id \notin published
    /\ transactions' = [transactions EXCEPT ![id] = [inputs |-> <<>>,
                            outputs |-> <<CreateP2WKHOutput(<<key>>, amount)>>]]
    /\ mempool' = mempool \cup {id}
    /\ UNCHANGED <<chain_height, published>>

(***************************************************************************)
(* Add a coinbase tx with a multisig output spendable by signature from    *)
(* all keys.                                                               *)
(*                                                                         *)
(* We don't do threshold signatures for simplicity.                        *)
(***************************************************************************)
AddMultisigCoinbaseToMempool(id, keys, amount) ==
    /\ id \notin mempool
    /\ id \notin published
    /\ transactions' = [transactions EXCEPT ![id] = [inputs |-> <<>>,
                            outputs |-> <<CreateMultisigOutput(keys, amount)>>]]
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

(***************************************************************************)
(* Create a transaction spending the given output/id, and spendable by the *)
(* given key.                                                              *)
(***************************************************************************)
CreateP2WKHTx(spending, output, id, key, amount) == [
    inputs |-> <<[txid |-> spending,
                index |-> output.index,
                sighash_flag |-> "all",
                signed_by |-> output.keys,
                hash_preimage |-> NoHash]>>,
    outputs |-> <<CreateP2WKHOutput(<<key>>, amount)>>
]

(***************************************************************************)
(* Create a transaction spending the given output/id, and spendable by as  *)
(* a multisig of the given keys.                                           *)
(***************************************************************************)
CreateMultisigTx(spending, output, id, keys, amount) == [
    inputs |-> <<[txid |-> spending,
                index |-> output.index,
                sighash_flag |-> "all",
                signed_by |-> output.keys,
                hash_preimage |-> NoHash]>>,
    outputs |-> <<CreateMultisigOutput(keys, amount)>>
]

CreateMultisigWithCSVTx(spending, output, id, keys, amount) == [
    inputs |-> <<[txid |-> spending,
                index |-> output.index,
                sighash_flag |-> "all",
                signed_by |-> output.keys,
                hash_preimage |-> NoHash]>>,
    outputs |-> <<CreateMultisigWithCSVOutput(keys, amount)>>
]

(***************************************************************************)
(* Add a new transaction to mempool.                                       *)
(*                                                                         *)
(* The transaction is created and added to mempool.                        *)
(*                                                                         *)
(* The transaction is constructed such that it is a valid transaction.     *)
(*                                                                         *)
(* `input_type` specifies the type of published output to select to spend. *)
(*                                                                         *)
(* `output_type' specifies the type of new output to create.               *)
(***************************************************************************)
AddSpendTxToMempool(id, key, amount, input_type, output_type) ==
    \E s \in published:
        \E o \in ToSet(transactions[s].outputs):
            /\ id \notin mempool
            /\ id \notin published
            /\ o.type = input_type          \* Select published tx of input_type
            /\ transactions' = [transactions EXCEPT ![id] =
                    CASE (output_type = "p2wkh") ->
                                CreateP2WKHTx(s, o, id, key, amount)
                       [](output_type = "multisig") ->
                                CreateMultisigTx(s, o, id, <<key, ChooseKey(key)>>, amount)
                       [](output_type = "multisig_with_csv") ->
                                CreateMultisigWithCSVTx(s, o, id, <<key, ChooseKey(key)>>, amount)
               ]
            /\ mempool' = mempool \cup {id}
            /\ UNCHANGED <<chain_height, published>>

=============================================================================
