open Core
open Snark_params.Tick

type t [@@deriving bin_io, sexp]

val merkle_root : t -> Ledger_hash.t

val path_exn :
  t -> int -> [`Left of Merkle_hash.t | `Right of Merkle_hash.t] list

val apply_payment_exn : t -> Payment.t -> t

val apply_transaction_exn : t -> Transaction.t -> t

val of_ledger_subset_exn : Ledger.t -> Signature_lib.Public_key.Compressed.t list -> t

val handler : t -> Handler.t Staged.t
