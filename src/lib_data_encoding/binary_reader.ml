(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Binary_error

let raise e = raise (Read_error e)

type state = {
  buffer : MBytes.t ;
  mutable offset : int ;
  mutable remaining_bytes : int ;
}

let check_remaining_bytes state size =
  if state.remaining_bytes < size then
    raise Not_enough_data ;
  state.remaining_bytes - size

let read_atom size conv state =
  let remaining_bytes = check_remaining_bytes state size in
  let res = conv state.buffer state.offset in
  state.offset <- state.offset + size ;
  state.remaining_bytes <- remaining_bytes ;
  res

(** Reader for all the atomic types. *)
module Atom = struct

  let uint8 = read_atom Binary_size.uint8 MBytes.get_uint8
  let uint16 = read_atom Binary_size.int16 MBytes.get_uint16

  let int8 = read_atom Binary_size.int8 MBytes.get_int8
  let int16 = read_atom Binary_size.int16 MBytes.get_int16
  let int32 = read_atom Binary_size.int32 MBytes.get_int32
  let int64 = read_atom Binary_size.int64 MBytes.get_int64

  let float = read_atom Binary_size.float MBytes.get_double

  let bool state = int8 state <> 0

  let uint30 =
    read_atom Binary_size.uint30 @@ fun buffer ofs ->
    let v = Int32.to_int (MBytes.get_int32 buffer ofs) in
    if v < 0 then
      raise (Invalid_int { min = 0 ; v ; max = (1 lsl 30) - 1 }) ;
    v

  let int31 =
    read_atom Binary_size.int31 @@ fun buffer ofs ->
    Int32.to_int (MBytes.get_int32 buffer ofs)

  let ranged_int ~minimum ~maximum state =
    let read_int =
      match Binary_size.range_to_size ~minimum ~maximum with
      | `Int8 -> int8
      | `Int16 -> int16
      | `Int31 -> int31
      | `Uint8 -> uint8
      | `Uint16 -> uint16
      | `Uint30 -> uint30 in
    let ranged = read_int state in
    let ranged = if minimum > 0 then ranged + minimum else ranged in
    if not (minimum <= ranged && ranged <= maximum) then
      raise (Invalid_int { min = minimum ; v =ranged ; max = maximum }) ;
    ranged

  let ranged_float ~minimum ~maximum state =
    let ranged = float state in
    if not (minimum <= ranged && ranged <= maximum) then
      raise (Invalid_float { min = minimum ; v = ranged ; max = maximum }) ;
    ranged

  let z state =
    let res = Buffer.create 100 in
    let first = uint8 state in
    if first = 0 then
      Z.zero
    else
      let first_value = first land 0x3F in
      let sign = (first land 0x40) <> 0 in
      let rec read prev value bit state =
        if prev land 0x80 = 0x00 then begin
          if bit > 0 then Buffer.add_char res (Char.unsafe_chr value) ;
          if prev = 0x00 then raise Trailing_zero ;
          let bits = Buffer.contents res in
          let res = Z.of_bits bits in
          if sign then Z.neg res else res
        end else
          let byte = uint8 state in
          let value = value lor ((byte land 0x7F) lsl bit) in
          let bit = bit + 7 in
          let bit, value =
            if bit >= 8 then begin
              Buffer.add_char res (Char.unsafe_chr (value land 0xFF)) ;
              bit - 8, value lsr 8
            end else
              bit, value in
          read byte value bit state in
      read first first_value 6 state

  let string_enum arr state =
    let read_index =
      match Binary_size.enum_size arr with
      | `Uint8 -> uint8
      | `Uint16 -> uint16
      | `Uint30 -> uint30 in
    let index = read_index state in
    if index >= Array.length arr then
      raise No_case_matched ;
    arr.(index)

  let fixed_length_bytes length =
    read_atom length @@ fun buf ofs ->
    MBytes.sub buf ofs length

  let fixed_length_string length =
    read_atom length @@ fun buf ofs ->
    MBytes.sub_string buf ofs length

  let tag = function
    | `Uint8 -> uint8
    | `Uint16 -> uint16

end

(** Main recursive reading function, in continuation passing style. *)
let rec read_rec : type ret. ret Encoding.t -> state -> ret
  = fun e state ->
    let open Encoding in
    match e.encoding with
    | Null -> ()
    | Empty -> ()
    | Constant _ -> ()
    | Ignore -> ()
    | Bool   -> Atom.bool state
    | Int8   -> Atom.int8 state
    | Uint8  -> Atom.uint8 state
    | Int16  -> Atom.int16 state
    | Uint16 -> Atom.uint16 state
    | Int31  -> Atom.int31 state
    | Int32  -> Atom.int32 state
    | Int64  -> Atom.int64 state
    | Z -> Atom.z state
    | Float -> Atom.float state
    | Bytes (`Fixed n) -> Atom.fixed_length_bytes n state
    | Bytes `Variable ->
        Atom.fixed_length_bytes state.remaining_bytes state
    | String (`Fixed n) -> Atom.fixed_length_string n state
    | String `Variable ->
        Atom.fixed_length_string state.remaining_bytes state
    | RangedInt { minimum ; maximum }  ->
        Atom.ranged_int ~minimum ~maximum state
    | RangedFloat { minimum ; maximum } ->
        Atom.ranged_float ~minimum ~maximum state
    | String_enum (_, arr) ->
        Atom.string_enum arr state
    | Array e ->
        let l = read_list e state in
        Array.of_list l
    | List e -> read_list e state
    | (Obj (Req (_, e))) -> read_rec e state
    | (Obj (Dft (_, e, _))) -> read_rec e state
    | (Obj (Opt (`Dynamic, _, e))) ->
        let present = Atom.bool state in
        if not present then
          None
        else
          Some (read_rec e state)
    | (Obj (Opt (`Variable, _, e))) ->
        if state.remaining_bytes = 0 then
          None
        else
          Some (read_rec e state)
    | Objs (`Fixed sz, e1, e2) ->
        ignore (check_remaining_bytes state sz : int) ;
        let left = read_rec e1 state in
        let right = read_rec e2 state in
        (left, right)
    | Objs (`Dynamic, e1, e2) ->
        let left = read_rec e1 state in
        let right = read_rec e2 state in
        (left, right)
    | (Objs (`Variable, e1, e2)) ->
        read_variable_pair e1 e2 state
    | Tup e -> read_rec e state
    | Tups (`Fixed sz, e1, e2) ->
        ignore (check_remaining_bytes state sz : int) ;
        let left = read_rec e1 state in
        let right = read_rec e2 state in
        (left, right)
    | Tups (`Dynamic, e1, e2) ->
        let left = read_rec e1 state in
        let right = read_rec e2 state in
        (left, right)
    | (Tups (`Variable, e1, e2)) ->
        read_variable_pair e1 e2 state
    | Conv { inj ; encoding } ->
        inj (read_rec encoding state)
    | Union (_, sz, cases) ->
        let ctag = Atom.tag sz state in
        let Case { encoding ; inj } =
          try
            List.find
              (function
                | Case { tag = Tag tag } -> tag = ctag
                | Case { tag = Json_only } -> false)
              cases
          with Not_found -> raise (Unexpected_tag ctag) in
        inj (read_rec encoding state)
    | Dynamic_size e ->
        let sz = Atom.int32 state in
        let sz = Int32.to_int sz in
        if sz < 0 then raise (Invalid_size sz) ;
        let remaining = check_remaining_bytes state sz in
        state.remaining_bytes <- sz ;
        let v = read_rec e state in
        if state.remaining_bytes <> 0 then raise Extra_bytes ;
        state.remaining_bytes <- remaining ;
        v
    | Describe { encoding = e } -> read_rec e state
    | Def { encoding = e } -> read_rec e state
    | Splitted { encoding = e } -> read_rec e state
    | Mu (_, _, self) -> read_rec (self e) state
    | Delayed f -> read_rec (f ()) state


and read_variable_pair
  : type left right.
    left Encoding.t -> right Encoding.t -> state -> (left * right)
  = fun e1 e2 state ->
    match Encoding.classify e1, Encoding.classify e2 with
    | (`Dynamic | `Fixed _), `Variable ->
        let left = read_rec e1 state in
        let right = read_rec e2 state in
        (left, right)
    | `Variable, `Fixed n ->
        if n > state.remaining_bytes then raise Not_enough_data ;
        state.remaining_bytes <- state.remaining_bytes - n ;
        let left = read_rec e1 state in
        assert (state.remaining_bytes = 0) ;
        state.remaining_bytes <- n ;
        let right = read_rec e2 state in
        assert (state.remaining_bytes = 0) ;
        (left, right)
    | _ -> assert false (* Should be rejected by [Encoding.Kind.combine] *)

and read_list : type a. a Encoding.t -> state -> a list
  = fun e state ->
    let rec loop acc =
      if state.remaining_bytes = 0 then
        List.rev acc
      else
        let v = read_rec e state in
        loop (v :: acc) in
    loop []



(** ******************** *)
(** Various entry points *)

let read encoding buffer ofs len =
  let state =
    { buffer ; offset = ofs ; remaining_bytes = len } in
  match read_rec encoding state with
  | exception Read_error _ -> None
  | v -> Some (state.offset, v)

let of_bytes_exn encoding buffer =
  let len = MBytes.length buffer in
  let state =
    { buffer ; offset = 0 ; remaining_bytes = len } in
  let v = read_rec encoding state in
  if state.offset <> len then raise Extra_bytes ;
  v

let of_bytes encoding buffer =
  try Some (of_bytes_exn encoding buffer)
  with Read_error _ -> None
