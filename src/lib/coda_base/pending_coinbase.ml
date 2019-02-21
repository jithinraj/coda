open Core_kernel
open Import
open Snark_params
open Snarky
open Tick
open Let_syntax
open Currency
open Fold_lib
open Snark_bits

module Coinbase_data = struct
  type t = Public_key.Compressed.t * Currency.Amount.t [@@deriving sexp]

  let of_coinbase (cb : Coinbase.t) : t Or_error.t =
    Option.value_map cb.fee_transfer
      ~default:(Ok (cb.proposer, cb.amount))
      ~f:(fun (_, fee) ->
        match Currency.Amount.sub cb.amount (Currency.Amount.of_fee fee) with
        | None -> Or_error.error_string "Coinbase underflow"
        | Some amount -> Ok (cb.proposer, amount) )

  type var = Public_key.Compressed.var * Amount.var

  type value = Public_key.Compressed.t * Amount.t [@@deriving sexp]

  let typ : (var, value) Typ.t =
    let spec =
      let open Data_spec in
      [Public_key.Compressed.typ; Amount.typ]
    in
    let of_hlist : 'a 'b. (unit, 'a -> 'b -> unit) H_list.t -> 'a * 'b =
      let open H_list in
      fun [public_key; amount] -> (public_key, amount)
    in
    let to_hlist (public_key, amount) = H_list.[public_key; amount] in
    Typ.of_hlistable spec ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist
      ~value_to_hlist:to_hlist ~value_of_hlist:of_hlist

  let var_of_t ((public_key, amount) : value) =
    (Public_key.Compressed.var_of_t public_key, Amount.var_of_t amount)

  let var_to_triples (public_key, amount) =
    let%map public_key = Public_key.Compressed.var_to_triples public_key in
    let amount = Amount.var_to_triples amount in
    public_key @ amount

  let fold ((public_key, amount) : t) =
    let open Fold in
    Public_key.Compressed.fold public_key +> Amount.fold amount

  let crypto_hash_prefix = Hash_prefix.coinbase

  let crypto_hash t = Pedersen.hash_fold crypto_hash_prefix (fold t)

  let empty = (Public_key.Compressed.empty, Amount.zero)

  let digest t = Pedersen.State.digest (crypto_hash t)

  let create public_key amount = (public_key, amount)

  let gen =
    let open Quickcheck.Let_syntax in
    let%bind public_key = Public_key.Compressed.gen in
    let%bind amount = Currency.Amount.gen in
    return (create public_key amount)

  module Checked = struct
    let hash t =
      var_to_triples t
      >>= Pedersen.Checked.hash_triples ~init:crypto_hash_prefix

    let digest t =
      var_to_triples t
      >>= Pedersen.Checked.digest_triples ~init:crypto_hash_prefix
  end
end

let coinbase_stacks = 9

let coinbase_tree_depth = Int.ceil_log2 coinbase_stacks

module Index = struct
  include Int

  let gen = Int.gen_incl 0 ((1 lsl coinbase_tree_depth) - 1)

  module Vector = struct
    include Int

    let length = coinbase_tree_depth

    let empty = zero

    let get t i = (t lsr i) land 1 = 1

    let set v i b = if b then v lor (one lsl i) else v land lnot (one lsl i)
  end

  include (Bits.Vector.Make (Vector) : Bits_intf.S with type t := t)

  let fold_bits = fold

  let fold t = Fold.group3 ~default:false (fold_bits t)

  include Bits.Snarkable.Small_bit_vector (Tick) (Vector)
end

module Stack = struct
  include Data_hash.Make_full_size ()

  let push_exn (h : t) cb : t =
    match Coinbase_data.of_coinbase cb with
    | Ok cb ->
        Pedersen.digest_fold Hash_prefix.coinbase_stack
          Fold.(fold h +> Coinbase_data.fold cb)
        |> of_hash
    | Error e ->
        failwithf "Error adding a coinbase to the pending stack: %s"
          (Error.to_string_hum e) ()

  let empty =
    of_hash
      ( Pedersen.(State.salt params ~get_chunk_table "CoinbaseStack")
      |> Pedersen.State.digest )

  module Checked = struct
    let push_var t coinbase : t = failwith ""

    let if_ b ~then_ ~else_ s = failwith ""

    let equal (x : var) (y : var) =
      Field.Checked.equal (var_to_hash_packed x) (var_to_hash_packed y)

    let hash t =
      var_to_triples t
      >>= Pedersen.Checked.hash_triples ~init:Hash_prefix.coinbase_stack

    let digest t =
      var_to_triples t
      >>= Pedersen.Checked.digest_triples ~init:Hash_prefix.coinbase_stack
  end
end

(*Pending coinbase hash*)
module Hash = struct
  module Merkle_tree =
    Snarky.Merkle_tree.Checked
      (Tick)
      (struct
        type value = Pedersen.Checked.Digest.t

        type var = Pedersen.Checked.Digest.var

        let typ = Pedersen.Checked.Digest.typ

        let hash ~height h1 h2 =
          let to_triples (bs : Pedersen.Checked.Digest.Unpacked.var) =
            Bitstring_lib.Bitstring.pad_to_triple_list ~default:Boolean.false_
              (bs :> Boolean.var list)
          in
          let open Let_syntax in
          (* TODO: Think about if choose_preimage_var is ok *)
          let%bind h1 = Pedersen.Checked.Digest.choose_preimage h1
          and h2 = Pedersen.Checked.Digest.choose_preimage h2 in
          Pedersen.Checked.digest_triples
            ~init:Hash_prefix.merkle_tree.(height)
            (to_triples h1 @ to_triples h2)

        let assert_equal h1 h2 = Field.Checked.Assert.equal h1 h2

        let if_ = Field.Checked.if_
      end)
      (struct
        include Stack

        type value = t

        let hash = Checked.digest
      end)

  let depth = coinbase_tree_depth

  include Data_hash.Make_full_size ()

  let merge ~height (h1 : t) (h2 : t) =
    let open Tick.Pedersen in
    State.digest
      (hash_fold
         Hash_prefix.merkle_tree.(height)
         Fold.(Digest.fold (h1 :> field) +> Digest.fold (h2 :> field)))
    |> of_hash

  let empty_hash =
    let open Tick.Pedersen in
    digest_fold
      (State.create params ~get_chunk_table)
      (Fold.string_triples "nothing up my sleeve")
    |> of_hash

  let of_digest = Fn.compose Fn.id of_hash

  type path = Pedersen.Digest.t list

  type _ Request.t +=
    | Stack_path : Index.t -> path Request.t
    | Get_coinbase_stack : Index.t -> (Stack.t * path) Request.t
    | Set_coinbase_stack : Index.t * Stack.t -> unit Request.t
    | Find_index_of_newest_stack : Index.t Request.t
    | Find_index_of_oldest_stack : Index.t Request.t

  let reraise_merkle_requests (With {request; respond}) =
    match request with
    | Merkle_tree.Get_path addr -> respond (Delegate (Stack_path addr))
    | Merkle_tree.Set (addr, stack) ->
        respond (Delegate (Set_coinbase_stack (addr, stack)))
    | Merkle_tree.Get_element addr ->
        respond (Delegate (Get_coinbase_stack addr))
    | _ -> unhandled

  let get t addr =
    handle
      (Merkle_tree.get_req ~depth (var_to_hash_packed t) addr)
      reraise_merkle_requests

  (*
   [modify_stack t pk ~filter ~f] implements the following spec:

   - finds a coinbase stack [stack] in [t] at path [addr] where [filter stack] holds.
     note that the stack is not guaranteed to be in the tree in which case it must
     just have the one coinbase.
   - returns a root [t'] of a tree of depth [depth]
   which is [t] but with the stack [f stack] at path [addr].
*)
  let%snarkydef modify_stack t ~(filter : Stack.var -> ('a, _) Checked.t) ~f =
    let%bind addr =
      request_witness Index.Unpacked.typ
        As_prover.(map (return ()) ~f:(fun _ -> Find_index_of_newest_stack))
    in
    handle
      (Merkle_tree.modify_req ~depth (var_to_hash_packed t) addr
         ~f:(fun stack ->
           let%bind () = filter stack in
           f stack ))
      reraise_merkle_requests
    >>| var_of_hash_packed

  (*
   [edit_stack t pk ~f] implements the following spec:

   - finds a coinbase stack [stack] in [t] at path [addr] OR it doesn't and is a stack with one coinbase
   - returns a root [t'] of a tree of depth [depth]
   which is [t] but with the stack [f stack] at path [addr].
*)
  let update_stack t ~is_new_stack ~f =
    modify_stack t
      ~filter:(fun stack ->
        let%bind empty_stack =
          Stack.Checked.equal stack Stack.(var_of_t empty)
        in
        let%bind new_stack = Boolean.(empty_stack && is_new_stack) in
        let%bind yes = Boolean.(new_stack || not empty_stack) in
        Boolean.(Assert.is_true yes) )
      ~f:(fun x -> f x)

  let%snarkydef delete_stack t ~f =
    let filter stack =
      let%bind empty_stack =
        Stack.Checked.equal stack Stack.(var_of_t empty)
      in
      Boolean.(Assert.is_true (not empty_stack))
    in
    let%bind addr =
      request_witness Index.Unpacked.typ
        As_prover.(map (return ()) ~f:(fun _ -> Find_index_of_oldest_stack))
    in
    handle
      (Merkle_tree.modify_req ~depth (var_to_hash_packed t) addr
         ~f:(fun stack ->
           let%bind () = filter stack in
           f stack ))
      reraise_merkle_requests
    >>| var_of_hash_packed
end

module T = struct
  module Coinbase_stack = struct
    include Stack

    let hash (t : t) = Hash.of_digest (t :> field)
  end

  module Merkle_tree =
    Sparse_ledger_lib.Sparse_ledger.Make (Hash) (Index) (Coinbase_stack)

  type t = {tree: Merkle_tree.t; index_list: Index.t list; new_index: Index.t}
  [@@deriving sexp, bin_io]

  let create_exn () =
    let init_hash = Coinbase_stack.hash Coinbase_stack.empty in
    let hash_on_level, root_hash =
      List.fold
        (List.init coinbase_tree_depth ~f:(fun i -> i + 1))
        ~init:([(0, init_hash)], init_hash)
        ~f:(fun (hashes, cur_hash) height ->
          let merge = Hash.merge ~height:(height - 1) cur_hash cur_hash in
          ((height, merge) :: hashes, merge) )
    in
    (*Core.printf !"Depth:%d hashes: %{sexp: (int * Hash.t) list} \n" coinbase_tree_depth hash_on_level;*)
    let rec create_path height path key =
      if height < 0 then path
      else
        let hash =
          Option.value_exn
            (List.Assoc.find ~equal:Int.equal hash_on_level height)
        in
        create_path (height - 1)
          ((if key mod 2 = 0 then `Left hash else `Right hash) :: path)
          (key / 2)
    in
    let rec go t key =
      if key > Int.pow 2 coinbase_tree_depth then t
      else
        let path = create_path (coinbase_tree_depth - 1) [] key in
        (*List.iteri path 
          ~f:(fun i dir ->
            let dir, h = match dir with
            | `Left h -> ("left "^Int.to_string i, h)
            | `Right h -> ("right "^Int.to_string i, h) in
            Core.printf !"%s %{sexp: Hash.t}\n"  dir h);*)
        go (Merkle_tree.add_path t path key Coinbase_stack.empty) (key + 1)
    in
    { tree= go (Merkle_tree.of_hash ~depth:coinbase_tree_depth root_hash) 0
    ; index_list= []
    ; new_index= 0 }

  let next_new_index t ~on_new_tree =
    if on_new_tree then
      let new_index =
        if t.new_index = coinbase_stacks then 0 else t.new_index + 1
      in
      {t with index_list= t.new_index :: t.index_list; new_index}
    else t

  let get_latest_stack t ~on_new_tree =
    if on_new_tree then Some t.new_index
      (* IMPORTANT TODO: include hash of the path*)
    else match t.index_list with [] -> None | x :: _ -> Some x

  let get_oldest_stack t = List.last t.index_list

  let replace_latest_stack t stack ~on_new_tree =
    match t.index_list with
    | [] -> if on_new_tree then Some [stack] else None
    | x :: xs ->
        if on_new_tree then Some (stack :: x :: xs) else Some (stack :: xs)

  let remove_oldest_stack_exn t =
    match List.rev t with
    | [] -> failwith "No stacks"
    | x :: xs -> (x, List.rev xs)

  let add_coinbase_exn t ~coinbase ~on_new_tree =
    let key = Option.value_exn (get_latest_stack t ~on_new_tree) in
    let stack_index = Merkle_tree.find_index_exn t.tree key in
    let stack_before = Merkle_tree.get_exn t.tree stack_index in
    let stack_after = Coinbase_stack.push_exn stack_before coinbase in
    let t' = next_new_index t ~on_new_tree in
    let tree' = Merkle_tree.set_exn t.tree stack_index stack_after in
    {t' with tree= tree'}

  let remove_coinbase_stack_exn t =
    let oldest_stack, remaining = remove_oldest_stack_exn t.index_list in
    let stack_index = Merkle_tree.find_index_exn t.tree oldest_stack in
    let tree' = Merkle_tree.set_exn t.tree stack_index Coinbase_stack.empty in
    {t with tree= tree'; index_list= remaining}

  let merkle_root t = Merkle_tree.merkle_root t.tree

  let get_exn t index = Merkle_tree.get_exn t.tree index

  let path_exn t index = Merkle_tree.path_exn t.tree index

  let set_exn t index stack =
    {t with tree= Merkle_tree.set_exn t.tree index stack}

  let find_index_exn t = Merkle_tree.find_index_exn t.tree

  (*TODO should handler be here?*)
end

include T

let%test_unit "add stack and remove stack = initial tree " =
  let pending_coinbases = ref (create_exn ()) in
  let coinbases_gen = List.gen_with_length 100 Coinbase.gen in
  Quickcheck.test coinbases_gen ~trials:10 ~f:(fun cbs ->
      Async.Thread_safe.block_on_async_exn (fun () ->
          let is_new = ref true in
          let init = merkle_root !pending_coinbases in
          let after_adding =
            List.fold cbs ~init:!pending_coinbases ~f:(fun acc coinbase ->
                let t = add_coinbase_exn acc ~coinbase ~on_new_tree:!is_new in
                is_new := false ;
                t )
          in
          let after_del = remove_coinbase_stack_exn after_adding in
          pending_coinbases := after_del ;
          assert (Hash.equal (merkle_root after_del) init) ;
          Async.Deferred.return () ) )