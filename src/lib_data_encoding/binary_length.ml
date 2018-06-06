(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Binary_error

let n_length value =
  let bits = Z.numbits value in
  if bits = 0 then 1 else (bits + 6) / 7
let z_length value = (Z.numbits value + 1 + 6) / 7

let rec length : type x. x Encoding.t -> x -> int =
  fun e value ->
    let open Encoding in
    match e.encoding with
    (* Fixed *)
    | Null -> 0
    | Empty -> 0
    | Constant _ -> 0
    | Bool -> Binary_size.bool
    | Int8 -> Binary_size.int8
    | Uint8 -> Binary_size.uint8
    | Int16 -> Binary_size.int16
    | Uint16 -> Binary_size.uint16
    | Int31 -> Binary_size.int31
    | Int32 -> Binary_size.int32
    | Int64 -> Binary_size.int64
    | N -> n_length value
    | Z -> z_length value
    | RangedInt { minimum ; maximum } ->
        Binary_size.integer_to_size @@
        Binary_size.range_to_size ~minimum ~maximum
    | Float -> Binary_size.float
    | RangedFloat _ -> Binary_size.float
    | Bytes `Fixed n -> n
    | String `Fixed n -> n
    | Padded (e, n) -> length e value + n
    | String_enum (_, arr) ->
        Binary_size.integer_to_size @@ Binary_size.enum_size arr
    | Objs { kind = `Fixed n } -> n
    | Tups { kind = `Fixed n } -> n
    | Union { kind = `Fixed n } -> n
    (* Dynamic *)
    | Objs { kind = `Dynamic ; left ; right } ->
        let (v1, v2) = value in
        length left v1 + length right v2
    | Tups { kind = `Dynamic ; left ; right } ->
        let (v1, v2) = value in
        length left v1 + length right v2
    | Union { kind = `Dynamic ; tag_size ; cases } ->
        let rec length_case = function
          | [] -> raise (Write_error No_case_matched)
          | Case { tag = Json_only } :: tl -> length_case tl
          | Case { encoding = e ; proj ; _ } :: tl ->
              match proj value with
              | None -> length_case tl
              | Some value -> Binary_size.tag_size tag_size + length e value in
        length_case cases
    | Mu { kind = `Dynamic ; fix } -> length (fix e) value
    | Obj (Opt { kind = `Dynamic ; encoding = e }) -> begin
        match value with
        | None -> 1
        | Some value -> 1 + length e value
      end
    (* Variable *)
    | Ignore -> 0
    | Bytes `Variable -> MBytes.length value
    | String `Variable -> String.length value
    | Array e ->
        Array.fold_left
          (fun acc v -> length e v + acc)
          0 value
    | List e ->
        List.fold_left
          (fun acc v -> length e v + acc)
          0 value
    | Objs { kind = `Variable ; left ; right } ->
        let (v1, v2) = value in
        length left v1 + length right v2
    | Tups { kind = `Variable ; left ; right } ->
        let (v1, v2) = value in
        length left v1 + length right v2
    | Obj (Opt { kind = `Variable ; encoding = e }) -> begin
        match value with
        | None -> 0
        | Some value -> length e value
      end
    | Union { kind = `Variable ; tag_size ; cases } ->
        let rec length_case = function
          | [] -> raise (Write_error No_case_matched)
          | Case { tag = Json_only } :: tl -> length_case tl
          | Case { encoding = e ; proj ; _ } :: tl ->
              match proj value with
              | None -> length_case tl
              | Some value -> Binary_size.tag_size tag_size + length e value in
        length_case cases
    | Mu { kind = `Variable ; fix } -> length (fix e) value
    (* Recursive*)
    | Obj (Req { encoding = e }) -> length e value
    | Obj (Dft { encoding = e }) -> length e value
    | Tup e -> length e value
    | Conv  { encoding = e ; proj } ->
        length e (proj value)
    | Describe { encoding = e } -> length e value
    | Splitted { encoding = e } -> length e value
    | Dynamic_size { kind ; encoding = e } ->
        let length = length e value in
        Binary_size.integer_to_size kind + length
    | Check_size { limit ; encoding = e } ->
        let length = length e value in
        if length > limit then raise (Write_error Size_limit_exceeded) ;
        length
    | Delayed f -> length (f ()) value

let fixed_length e =
  match Encoding.classify e with
  | `Fixed n -> Some n
  | `Dynamic | `Variable -> None
let fixed_length_exn e =
  match fixed_length e with
  | Some n -> n
  | None -> invalid_arg "Data_encoding.Binary.fixed_length_exn"

