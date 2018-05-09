(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

exception No_case_matched
exception Unexpected_tag of int
exception Duplicated_tag of int
exception Invalid_tag of int * [ `Uint8 | `Uint16 ]
exception Unexpected_enum of string * string list
exception Invalid_size of int
exception Int_out_of_range of int * int * int
exception Float_out_of_range of float * float * float
exception Parse_error of string


module Kind = struct

  type t =
    [ `Fixed of int
    | `Dynamic
    | `Variable ]

  type length =
    [ `Fixed of int
    | `Variable ]

  type enum =
    [ `Dynamic
    | `Variable ]

  let combine name : t -> t -> t = fun k1 k2 ->
    match k1, k2 with
    | `Fixed n1, `Fixed n2 -> `Fixed (n1 + n2)
    | `Dynamic, `Dynamic | `Fixed _, `Dynamic
    | `Dynamic, `Fixed _ -> `Dynamic
    | `Variable, `Fixed _
    | (`Dynamic | `Fixed _), `Variable -> `Variable
    | `Variable, `Dynamic ->
        Printf.ksprintf invalid_arg
          "Cannot merge two %s when the left element is of variable length \
           and the right one of dynamic length. \
           You should use the reverse order, or wrap the second one \
           with Data_encoding.dynamic_size."
          name
    | `Variable, `Variable ->
        Printf.ksprintf invalid_arg
          "Cannot merge two %s with variable length. \
           You should wrap one of them with Data_encoding.dynamic_size."
          name

  let merge : t -> t -> t = fun k1 k2 ->
    match k1, k2 with
    | `Fixed n1, `Fixed n2 when n1 = n2 -> `Fixed n1
    | `Fixed _, `Fixed _ -> `Dynamic
    | `Dynamic, `Dynamic | `Fixed _, `Dynamic
    | `Dynamic, `Fixed _ -> `Dynamic
    | `Variable, (`Dynamic | `Fixed _)
    | (`Dynamic | `Fixed _), `Variable
    | `Variable, `Variable -> `Variable

  let merge_list sz : t list -> t = function
    | [] -> assert false (* should be rejected by Data_encoding.union *)
    | k :: ks ->
        match List.fold_left merge k ks with
        | `Fixed n -> `Fixed (n + Size.tag_size sz)
        | k -> k

end

type case_tag = Tag of int | Json_only

type 'a desc =
  | Null : unit desc
  | Empty : unit desc
  | Ignore : unit desc
  | Constant : string -> unit desc
  | Bool : bool desc
  | Int8 : int desc
  | Uint8 : int desc
  | Int16 : int desc
  | Uint16 : int desc
  | Int31 : int desc
  | Int32 : Int32.t desc
  | Int64 : Int64.t desc
  | Z : Z.t desc
  | RangedInt : { minimum : int ; maximum : int } -> int desc
  | RangedFloat : { minimum : float ; maximum : float } -> float desc
  | Float : float desc
  | Bytes : Kind.length -> MBytes.t desc
  | String : Kind.length -> string desc
  | String_enum : ('a, string * int) Hashtbl.t * 'a array -> 'a desc
  | Array : 'a t -> 'a array desc
  | List : 'a t -> 'a list desc
  | Obj : 'a field -> 'a desc
  | Objs : Kind.t * 'a t * 'b t -> ('a * 'b) desc
  | Tup : 'a t -> 'a desc
  | Tups : Kind.t * 'a t * 'b t -> ('a * 'b) desc
  | Union : Kind.t * Size.tag_size * 'a case list -> 'a desc
  | Mu : Kind.enum * string * ('a t -> 'a t) -> 'a desc
  | Conv :
      { proj : ('a -> 'b) ;
        inj : ('b -> 'a) ;
        encoding : 'b t ;
        schema : Json_schema.schema option } -> 'a desc
  | Describe :
      { title : string option ;
        description : string option ;
        encoding : 'a t } -> 'a desc
  | Def : { name : string ;
            encoding : 'a t } -> 'a desc
  | Splitted :
      { encoding : 'a t ;
        json_encoding : 'a Json_encoding.encoding ;
        is_obj : bool ; is_tup : bool } -> 'a desc
  | Dynamic_size : 'a t -> 'a desc
  | Delayed : (unit -> 'a t) -> 'a desc

and _ field =
  | Req : string * 'a t -> 'a field
  | Opt : Kind.enum * string * 'a t -> 'a option field
  | Dft : string * 'a t * 'a -> 'a field

and 'a case =
  | Case : { name : string option ;
             encoding : 'a t ;
             proj : ('t -> 'a option) ;
             inj : ('a -> 't) ;
             tag : case_tag } -> 't case

and 'a t = {
  encoding: 'a desc ;
  mutable json_encoding: 'a Json_encoding.encoding option ;
}

type 'a encoding = 'a t

let rec classify : type a. a t -> Kind.t = fun e ->
  match e.encoding with
  (* Fixed *)
  | Null -> `Fixed 0
  | Empty -> `Fixed 0
  | Constant _ -> `Fixed 0
  | Bool -> `Fixed Size.bool
  | Int8 -> `Fixed Size.int8
  | Uint8 -> `Fixed Size.uint8
  | Int16 -> `Fixed Size.int16
  | Uint16 -> `Fixed Size.uint16
  | Int31 -> `Fixed Size.int31
  | Int32 -> `Fixed Size.int32
  | Int64 -> `Fixed Size.int64
  | Z -> `Dynamic
  | RangedInt { minimum ; maximum } ->
      `Fixed Size.(integer_to_size @@ range_to_size ~minimum ~maximum)
  | Float -> `Fixed Size.float
  | RangedFloat _ -> `Fixed Size.float
  (* Tagged *)
  | Bytes kind -> (kind :> Kind.t)
  | String kind -> (kind :> Kind.t)
  | String_enum (_, cases) ->
      `Fixed Size.(integer_to_size @@ enum_size cases)
  | Obj (Opt (kind, _, _)) -> (kind :> Kind.t)
  | Objs (kind, _, _) -> kind
  | Tups (kind, _, _) -> kind
  | Union (kind, _, _) -> (kind :> Kind.t)
  | Mu (kind, _, _) -> (kind :> Kind.t)
  (* Variable *)
  | Ignore -> `Variable
  | Array _ -> `Variable
  | List _ -> `Variable
  (* Recursive *)
  | Obj (Req (_, encoding)) -> classify encoding
  | Obj (Dft (_, encoding, _)) -> classify encoding
  | Tup encoding -> classify encoding
  | Conv { encoding } -> classify encoding
  | Describe { encoding } -> classify encoding
  | Def { encoding } -> classify encoding
  | Splitted { encoding } -> classify encoding
  | Dynamic_size _ -> `Dynamic
  | Delayed f -> classify (f ())

let make ?json_encoding encoding = { encoding ; json_encoding }

module Fixed = struct
  let string n = make @@ String (`Fixed n)
  let bytes n = make @@ Bytes (`Fixed n)
end

module Variable = struct
  let string = make @@ String `Variable
  let bytes = make @@ Bytes `Variable
  let check_not_variable name e =
    match classify e with
    | `Variable ->
        Printf.ksprintf invalid_arg
          "Cannot insert variable length element in %s. \
           You should wrap the contents using Data_encoding.dynamic_size." name
    | `Dynamic | `Fixed _ -> ()
  let array e =
    check_not_variable "an array" e ;
    make @@ Array e
  let list e =
    check_not_variable "a list" e ;
    make @@ List e
end

let dynamic_size e =
  make @@ Dynamic_size e

let delayed f =
  make @@ Delayed f

let null = make @@ Null
let empty = make @@ Empty
let unit = make @@ Ignore
let constant s = make @@ Constant s
let bool = make @@ Bool
let int8 = make @@ Int8
let uint8 = make @@ Uint8
let int16 = make @@ Int16
let uint16 = make @@ Uint16
let int31 = make @@ Int31
let int32 = make @@ Int32
let ranged_int minimum maximum =
  let minimum = min minimum maximum
  and maximum = max minimum maximum in
  if minimum < -(1 lsl 30) || (1 lsl 30) - 1 < maximum then
    invalid_arg "Data_encoding.ranged_int" ;
  make @@ RangedInt { minimum ; maximum  }
let ranged_float minimum maximum =
  let minimum = min minimum maximum
  and maximum = max minimum maximum in
  make @@ RangedFloat { minimum ; maximum }
let int64 = make @@ Int64
let z = make @@ Z
let float = make @@ Float

let string = dynamic_size Variable.string
let bytes = dynamic_size Variable.bytes
let array e = dynamic_size (Variable.array e)
let list e = dynamic_size (Variable.list e)

let string_enum = function
  | [] -> invalid_arg "data_encoding.string_enum: cannot have zero cases"
  | [ _case ] -> invalid_arg "data_encoding.string_enum: cannot have a single case, use constant instead"
  | _ :: _ as cases ->
      let arr = Array.of_list (List.map snd cases) in
      let tbl = Hashtbl.create (Array.length arr) in
      List.iteri (fun ind (str, a) -> Hashtbl.add tbl a (str, ind)) cases ;
      make @@ String_enum (tbl, arr)

let conv proj inj ?schema encoding =
  make @@ Conv { proj ; inj ; encoding ; schema }

let describe ?title ?description encoding =
  match title, description with
  | None, None -> encoding
  | _, _ -> make @@ Describe { title ; description ; encoding }

let def name encoding = make @@ Def { name ; encoding }

let req ?title ?description n t =
  Req (n, describe ?title ?description t)
let opt ?title ?description n encoding =
  let kind =
    match classify encoding with
    | `Variable -> `Variable
    | `Fixed _ | `Dynamic -> `Dynamic in
  Opt (kind, n, make @@ Describe { title ; description ; encoding })
let varopt ?title ?description n encoding =
  Opt (`Variable, n, make @@ Describe { title ; description ; encoding })
let dft ?title ?description n t d =
  Dft (n, describe ?title ?description t, d)

let raw_splitted ~json ~binary =
  make @@ Splitted { encoding = binary ;
                     json_encoding = json ;
                     is_obj = false ;
                     is_tup = false }

let rec is_obj : type a. a t -> bool = fun e ->
  match e.encoding with
  | Obj _ -> true
  | Objs _ (* by construction *) -> true
  | Conv { encoding = e } -> is_obj e
  | Dynamic_size e  -> is_obj e
  | Union (_,_,cases) ->
      List.for_all (fun (Case { encoding = e }) -> is_obj e) cases
  | Empty -> true
  | Ignore -> true
  | Mu (_,_,self) -> is_obj (self e)
  | Splitted { is_obj } -> is_obj
  | Delayed f -> is_obj (f ())
  | Describe { encoding } -> is_obj encoding
  | Def { encoding } -> is_obj encoding
  | _ -> false

let rec is_tup : type a. a t -> bool = fun e ->
  match e.encoding with
  | Tup _ -> true
  | Tups _ (* by construction *) -> true
  | Conv { encoding = e } -> is_tup e
  | Dynamic_size e  -> is_tup e
  | Union (_,_,cases) ->
      List.for_all (function Case { encoding = e} -> is_tup e) cases
  | Mu (_,_,self) -> is_tup (self e)
  | Splitted { is_tup } -> is_tup
  | Delayed f -> is_tup (f ())
  | Describe { encoding } -> is_tup encoding
  | Def { encoding } -> is_tup encoding
  | _ -> false

let raw_merge_objs e1 e2 =
  let kind = Kind.combine "objects" (classify e1) (classify e2) in
  make @@ Objs (kind, e1, e2)

let obj1 f1 = make @@ Obj f1
let obj2 f2 f1 =
  raw_merge_objs (obj1 f2) (obj1 f1)
let obj3 f3 f2 f1 =
  raw_merge_objs (obj1 f3) (obj2 f2 f1)
let obj4 f4 f3 f2 f1 =
  raw_merge_objs (obj2 f4 f3) (obj2 f2 f1)
let obj5 f5 f4 f3 f2 f1 =
  raw_merge_objs (obj1 f5) (obj4 f4 f3 f2 f1)
let obj6 f6 f5 f4 f3 f2 f1 =
  raw_merge_objs (obj2 f6 f5) (obj4 f4 f3 f2 f1)
let obj7 f7 f6 f5 f4 f3 f2 f1 =
  raw_merge_objs (obj3 f7 f6 f5) (obj4 f4 f3 f2 f1)
let obj8 f8 f7 f6 f5 f4 f3 f2 f1 =
  raw_merge_objs (obj4 f8 f7 f6 f5) (obj4 f4 f3 f2 f1)
let obj9 f9 f8 f7 f6 f5 f4 f3 f2 f1 =
  raw_merge_objs (obj1 f9) (obj8 f8 f7 f6 f5 f4 f3 f2 f1)
let obj10 f10 f9 f8 f7 f6 f5 f4 f3 f2 f1 =
  raw_merge_objs (obj2 f10 f9) (obj8 f8 f7 f6 f5 f4 f3 f2 f1)

let merge_objs o1 o2 =
  if is_obj o1 && is_obj o2 then
    raw_merge_objs o1 o2
  else
    invalid_arg "Json_encoding.merge_objs"

let raw_merge_tups e1 e2 =
  let kind = Kind.combine "tuples" (classify e1) (classify e2) in
  make @@ Tups (kind, e1, e2)

let tup1 e1 = make @@ Tup e1
let tup2 e2 e1 =
  raw_merge_tups (tup1 e2) (tup1 e1)
let tup3 e3 e2 e1 =
  raw_merge_tups (tup1 e3) (tup2 e2 e1)
let tup4 e4 e3 e2 e1 =
  raw_merge_tups (tup2 e4 e3) (tup2 e2 e1)
let tup5 e5 e4 e3 e2 e1 =
  raw_merge_tups (tup1 e5) (tup4 e4 e3 e2 e1)
let tup6 e6 e5 e4 e3 e2 e1 =
  raw_merge_tups (tup2 e6 e5) (tup4 e4 e3 e2 e1)
let tup7 e7 e6 e5 e4 e3 e2 e1 =
  raw_merge_tups (tup3 e7 e6 e5) (tup4 e4 e3 e2 e1)
let tup8 e8 e7 e6 e5 e4 e3 e2 e1 =
  raw_merge_tups (tup4 e8 e7 e6 e5) (tup4 e4 e3 e2 e1)
let tup9 e9 e8 e7 e6 e5 e4 e3 e2 e1 =
  raw_merge_tups (tup1 e9) (tup8 e8 e7 e6 e5 e4 e3 e2 e1)
let tup10 e10 e9 e8 e7 e6 e5 e4 e3 e2 e1 =
  raw_merge_tups (tup2 e10 e9) (tup8 e8 e7 e6 e5 e4 e3 e2 e1)

let merge_tups t1 t2 =
  if is_tup t1 && is_tup t2 then
    raw_merge_tups t1 t2
  else
    invalid_arg "Tezos_serial.Encoding.merge_tups"

let conv3 ty =
  conv
    (fun (c, b, a) -> (c, (b, a)))
    (fun (c, (b, a)) -> (c, b, a))
    ty
let obj3 f3 f2 f1 = conv3 (obj3 f3 f2 f1)
let tup3 f3 f2 f1 = conv3 (tup3 f3 f2 f1)
let conv4 ty =
  conv
    (fun (d, c, b, a) -> ((d, c), (b, a)))
    (fun ((d, c), (b, a)) -> (d, c, b, a))
    ty
let obj4 f4 f3 f2 f1 = conv4 (obj4 f4 f3 f2 f1)
let tup4 f4 f3 f2 f1 = conv4 (tup4 f4 f3 f2 f1)
let conv5 ty =
  conv
    (fun (e, d, c, b, a) -> (e, ((d, c), (b, a))))
    (fun (e, ((d, c), (b, a))) -> (e, d, c, b, a))
    ty
let obj5 f5 f4 f3 f2 f1 = conv5 (obj5 f5 f4 f3 f2 f1)
let tup5 f5 f4 f3 f2 f1 = conv5 (tup5 f5 f4 f3 f2 f1)
let conv6 ty =
  conv
    (fun (f, e, d, c, b, a) -> ((f, e), ((d, c), (b, a))))
    (fun ((f, e), ((d, c), (b, a))) -> (f, e, d, c, b, a))
    ty
let obj6 f6 f5 f4 f3 f2 f1 = conv6 (obj6 f6 f5 f4 f3 f2 f1)
let tup6 f6 f5 f4 f3 f2 f1 = conv6 (tup6 f6 f5 f4 f3 f2 f1)
let conv7 ty =
  conv
    (fun (g, f, e, d, c, b, a) -> ((g, (f, e)), ((d, c), (b, a))))
    (fun ((g, (f, e)), ((d, c), (b, a))) -> (g, f, e, d, c, b, a))
    ty
let obj7 f7 f6 f5 f4 f3 f2 f1 = conv7 (obj7 f7 f6 f5 f4 f3 f2 f1)
let tup7 f7 f6 f5 f4 f3 f2 f1 = conv7 (tup7 f7 f6 f5 f4 f3 f2 f1)
let conv8 ty =
  conv (fun (h, g, f, e, d, c, b, a) ->
      (((h, g), (f, e)), ((d, c), (b, a))))
    (fun (((h, g), (f, e)), ((d, c), (b, a))) ->
       (h, g, f, e, d, c, b, a))
    ty
let obj8 f8 f7 f6 f5 f4 f3 f2 f1 = conv8 (obj8 f8 f7 f6 f5 f4 f3 f2 f1)
let tup8 f8 f7 f6 f5 f4 f3 f2 f1 = conv8 (tup8 f8 f7 f6 f5 f4 f3 f2 f1)
let conv9 ty =
  conv
    (fun (i, h, g, f, e, d, c, b, a) ->
       (i, (((h, g), (f, e)), ((d, c), (b, a)))))
    (fun (i, (((h, g), (f, e)), ((d, c), (b, a)))) ->
       (i, h, g, f, e, d, c, b, a))
    ty
let obj9 f9 f8 f7 f6 f5 f4 f3 f2 f1 =
  conv9 (obj9 f9 f8 f7 f6 f5 f4 f3 f2 f1)
let tup9 f9 f8 f7 f6 f5 f4 f3 f2 f1 =
  conv9 (tup9 f9 f8 f7 f6 f5 f4 f3 f2 f1)
let conv10 ty =
  conv
    (fun (j, i, h, g, f, e, d, c, b, a) ->
       ((j, i), (((h, g), (f, e)), ((d, c), (b, a)))))
    (fun ((j, i), (((h, g), (f, e)), ((d, c), (b, a)))) ->
       (j, i, h, g, f, e, d, c, b, a))
    ty
let obj10 f10 f9 f8 f7 f6 f5 f4 f3 f2 f1 =
  conv10 (obj10 f10 f9 f8 f7 f6 f5 f4 f3 f2 f1)
let tup10 f10 f9 f8 f7 f6 f5 f4 f3 f2 f1 =
  conv10 (tup10 f10 f9 f8 f7 f6 f5 f4 f3 f2 f1)

let check_cases tag_size cases =
  if cases = [] then
    invalid_arg "Data_encoding.union: empty list of cases." ;
  let max_tag =
    match tag_size with
    | `Uint8 -> 256
    | `Uint16 -> 256 * 256 in
  ignore @@
  List.fold_left
    (fun others (Case { tag }) ->
       match tag with
       | Json_only -> others
       | Tag tag ->
           if List.mem tag others then raise (Duplicated_tag tag) ;
           if tag < 0 || max_tag <= tag then
             raise (Invalid_tag (tag, tag_size)) ;
           tag :: others
    )
    [] cases

let union ?(tag_size = `Uint8) cases =
  check_cases tag_size cases ;
  let kinds =
    List.map (fun (Case { encoding }) -> classify encoding) cases in
  let kind = Kind.merge_list tag_size kinds in
  make @@ Union (kind, tag_size, cases)
let case ?name tag encoding proj inj = Case { name ; encoding ; proj ; inj ; tag }
let option ty =
  union
    ~tag_size:`Uint8
    [ case (Tag 1) ty
        ~name:"Some"
        (fun x -> x)
        (fun x -> Some x) ;
      case (Tag 0) empty
        ~name:"None"
        (function None -> Some () | Some _ -> None)
        (fun () -> None) ;
    ]
let mu name self =
  let kind =
    try
      match classify (self (make @@ Mu (`Dynamic, name, self))) with
      | `Fixed _ | `Dynamic -> `Dynamic
      | `Variable -> raise Exit
    with Exit | _ (* TODO variability error *) ->
      ignore @@ classify (self (make @@ Mu (`Variable, name, self))) ;
      `Variable in
  make @@ Mu (kind, name, self)

let result ok_enc error_enc =
  union
    ~tag_size:`Uint8
    [ case (Tag 1) ok_enc
        (function Ok x -> Some x | Error _ -> None)
        (fun x -> Ok x) ;
      case (Tag 0) error_enc
        (function Ok _ -> None | Error x -> Some x)
        (fun x -> Error x) ;
    ]

