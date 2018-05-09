(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

(** Type-safe serialization and deserialization of data structures. *)

(** {1 Data Encoding} *)

(** {2 Overview}

    This module provides type-safe serialization and deserialization of
    data structures. Backends are provided to both binary and JSON.

    This works by writing type descriptors by hand, using the provided
    combinators. These combinators can fine-tune the binary
    representation to be compact and efficient, but also provide
    proper field names and meta information, so the API of Tezos can
    be automatically introspected and documented.

    Here is an example encoding for type [(int * string)].

    [let enc = obj2 (req "code" uint16) (req "message" string)]

    In JSON, this encoding maps values of type [int * string] to JSON
    objects with a field [code] whose value is a number and a field
    [message] whose value is a string.

    In binary, this encoding maps to two raw bytes for the [int]
    followed by the size of the string in bytes, and finally the raw
    contents of the string. This binary format is mostly tagless,
    meaning that serialized data cannot be interpreted without the
    encoding that was used for serialization.

    Regarding binary serialization, encodings are classified as either:
    - fixed size (booleans, integers, numbers)
      data is always the same size for that type ;
    - dynamically sized (arbitrary strings and bytes)
      data is of unknown size and requires an explicit length field ;
    - variable size (special case of strings, bytes, and arrays)
      data makes up the remainder of an object of known size,
      thus its size is given by the context, and does not
      have to be serialized.

    JSON operations are delegated to [ocplib-json-typed]. *)

(** {2 Module structure}

    This [Data_encoding] module provides muliple submodules:
    - [Encoding] contains the necessary types and constructors for making the
    type descriptors.
    - [Json], [Bson], and [Binary] contain functions to serialize and
    deserialize values.

*)

module Encoding: sig

  (** The type descriptors for values of type ['a]. *)
  type 'a t
  type 'a encoding = 'a t

  (** Exceptions that can be raised by the functions of this library. *)
  exception No_case_matched
  exception Unexpected_tag of int
  exception Duplicated_tag of int
  exception Invalid_tag of int * [ `Uint8 | `Uint16 ]
  exception Unexpected_enum of string * string list

  (** {3 Ground descriptors} *)

  (** Special value [null] in JSON, nothing in binary. *)
  val null : unit encoding

  (** Empty object (not included in binary, encoded as empty object in JSON). *)
  val empty : unit encoding

  (** Unit value, ommitted in binary.
      Serialized as an empty object in JSON, accepts any object when deserializing. *)
  val unit : unit encoding

  (** Constant string (data is not included in the binary data). *)
  val constant : string -> unit encoding

  (** Signed 8 bit integer
      (data is encoded as a byte in binary and an integer in JSON). *)
  val int8 : int encoding

  (** Unsigned 8 bit integer
      (data is encoded as a byte in binary and an integer in JSON). *)
  val uint8 : int encoding

  (** Signed 16 bit integer
      (data is encoded as a short in binary and an integer in JSON). *)
  val int16 : int encoding

  (** Unsigned 16 bit integer
      (data is encoded as a short in binary and an integer in JSON). *)
  val uint16 : int encoding

  (** Signed 31 bit integer, which corresponds to type int on 32-bit OCaml systems
      (data is encoded as a 32 bit int in binary and an integer in JSON). *)
  val int31 : int encoding

  (** Signed 32 bit integer
      (data is encoded as a 32-bit int in binary and an integer in JSON). *)
  val int32 : int32 encoding

  (** Signed 64 bit integer
      (data is encodedas a 64-bit int in binary and a decimal string in JSON). *)
  val int64 : int64 encoding

  (** Integer with bounds in a given range. Both bounds are inclusive.

      Raises [Invalid_argument] if the bounds are beyond the interval
      [-2^30; 2^30-1]. These bounds are chosen to be compatible with all versions
      of OCaml.
  *)
  val ranged_int : int -> int -> int encoding

  (** Big number
      In JSON, data is encoded as a decimal string.
      In binary, data is encoded as a variable length sequence of
      bytes, with a running unary size bit: the most significant bit of
      each byte tells is this is the last byte in the sequence (0) or if
      there is more to read (1). The second most significant bit of the
      first byte is reserved for the sign (positive if zero). Size and
      sign bits ignored, data is then the binary representation of the
      absolute value of the number in little endian order. *)
  val z : Z.t encoding

  (** Encoding of floating point number
      (encoded as a floating point number in JSON and a double in binary). *)
  val float : float encoding

  (** Float with bounds in a given range. Both bounds are inclusive *)
  val ranged_float : float -> float -> float encoding

  (** Encoding of a boolean
      (data is encoded as a byte in binary and a boolean in JSON). *)
  val bool : bool encoding

  (** Encoding of a string
      - default variable in width
      - encoded as a byte sequence in binary
      - encoded as a string in JSON. *)
  val string : string encoding

  (** Encoding of arbitrary bytes
      (encoded via hex in JSON and directly as a sequence byte in binary). *)
  val bytes : MBytes.t encoding

  (** {3 Descriptor combinators} *)

  (** Combinator to make an optional value
      (represented as a 1-byte tag followed by the data (or nothing) in binary
       and either the raw value or an empty object in JSON). *)
  val option : 'a encoding -> 'a option encoding

  (** Combinator to make a {!result} value
      (represented as a 1-byte tag followed by the data of either type in binary,
       and either unwrapped value in JSON (the caller must ensure that both
       encodings do not collide)). *)
  val result : 'a encoding -> 'b encoding -> ('a, 'b) result encoding

  (** Array combinator. *)
  val array : 'a encoding -> 'a array encoding

  (** List combinator. *)
  val list : 'a encoding -> 'a list encoding

  (** Provide a transformer from one encoding to a different one.

      Used to simplify nested encodings or to change the generic tuples
      built by {obj1}, {tup1} and the like into proper records.

      A schema may optionally be provided as documentation of the new encoding. *)
  val conv :
    ('a -> 'b) -> ('b -> 'a) ->
    ?schema:Json_schema.schema ->
    'b encoding -> 'a encoding

  (** Association list.
      An object in JSON, a list of pairs in binary. *)
  val assoc : 'a encoding -> (string * 'a) list encoding

  (** {3 Product descriptors} *)

  (** An enriched encoding to represent a component in a structured
      type, augmenting the encoding with a name and whether it is a
      required or optional. Fields are used to encode OCaml tuples as
      objects in JSON, and as sequences in binary, using combinator
      {!obj1} and the like. *)
  type 'a field

  (** Required field. *)
  val req :
    ?title:string -> ?description:string ->
    string -> 't encoding -> 't field

  (** Optional field. Omitted entirely in JSON encoding if None.
      Omitted in binary if the only optional field in a [`Variable]
      encoding, otherwise a 1-byte prefix (`0` or `1`) tells if the
      field is present or not. *)
  val opt :
    ?title:string -> ?description:string ->
    string -> 't encoding -> 't option field

  (** Optional field of variable length.
      Only one can be present in a given object. *)
  val varopt :
    ?title:string -> ?description:string ->
    string -> 't encoding -> 't option field

  (** Required field with a default value.
      If the default value is passed, the field is omitted in JSON.
      The value is always serialized in binary. *)
  val dft :
    ?title:string -> ?description:string ->
    string -> 't encoding -> 't -> 't field

  (** {4 Constructors for objects with N fields} *)
  (** These are serialized to binary by converting each internal object to binary
      and placing them in the order of the original object.
      These are serialized to JSON as a JSON object with the field names. *)

  val obj1 :
    'f1 field -> 'f1 encoding
  val obj2 :
    'f1 field -> 'f2 field -> ('f1 * 'f2) encoding
  val obj3 :
    'f1 field -> 'f2 field -> 'f3 field -> ('f1 * 'f2 * 'f3) encoding
  val obj4 :
    'f1 field -> 'f2 field -> 'f3 field -> 'f4 field ->
    ('f1 * 'f2 * 'f3 * 'f4) encoding
  val obj5 :
    'f1 field -> 'f2 field -> 'f3 field -> 'f4 field -> 'f5 field ->
    ('f1 * 'f2 * 'f3 * 'f4 * 'f5) encoding
  val obj6 :
    'f1 field -> 'f2 field -> 'f3 field -> 'f4 field -> 'f5 field ->
    'f6 field ->
    ('f1 * 'f2 * 'f3 * 'f4 * 'f5 * 'f6) encoding
  val obj7 :
    'f1 field -> 'f2 field -> 'f3 field -> 'f4 field -> 'f5 field ->
    'f6 field -> 'f7 field ->
    ('f1 * 'f2 * 'f3 * 'f4 * 'f5 * 'f6 * 'f7) encoding
  val obj8 :
    'f1 field -> 'f2 field -> 'f3 field -> 'f4 field -> 'f5 field ->
    'f6 field -> 'f7 field -> 'f8 field ->
    ('f1 * 'f2 * 'f3 * 'f4 * 'f5 * 'f6 * 'f7 * 'f8) encoding
  val obj9 :
    'f1 field -> 'f2 field -> 'f3 field -> 'f4 field -> 'f5 field ->
    'f6 field -> 'f7 field -> 'f8 field -> 'f9 field ->
    ('f1 * 'f2 * 'f3 * 'f4 * 'f5 * 'f6 * 'f7 * 'f8 * 'f9) encoding
  val obj10 :
    'f1 field -> 'f2 field -> 'f3 field -> 'f4 field -> 'f5 field ->
    'f6 field -> 'f7 field -> 'f8 field -> 'f9 field -> 'f10 field ->
    ('f1 * 'f2 * 'f3 * 'f4 * 'f5 * 'f6 * 'f7 * 'f8 * 'f9 * 'f10) encoding

  (** Create a larger object from the encodings of two smaller ones.
      @raise invalid_arg if both arguments are not objects. *)
  val merge_objs : 'o1 encoding -> 'o2 encoding -> ('o1 * 'o2) encoding

  (** {4 Constructors for tuples with N fields} *)

  (** These are serialized to binary by converting each internal object to binary
      and placing them in the order of the original object.
      These are serialized to JSON as JSON arrays/lists. *)


  val tup1 :
    'f1 encoding ->
    'f1 encoding
  val tup2 :
    'f1 encoding -> 'f2 encoding ->
    ('f1 * 'f2) encoding
  val tup3 :
    'f1 encoding -> 'f2 encoding -> 'f3 encoding ->
    ('f1 * 'f2 * 'f3) encoding
  val tup4 :
    'f1 encoding -> 'f2 encoding -> 'f3 encoding -> 'f4 encoding ->
    ('f1 * 'f2 * 'f3 * 'f4) encoding
  val tup5 :
    'f1 encoding -> 'f2 encoding -> 'f3 encoding -> 'f4 encoding ->
    'f5 encoding ->
    ('f1 * 'f2 * 'f3 * 'f4 * 'f5) encoding
  val tup6 :
    'f1 encoding -> 'f2 encoding -> 'f3 encoding -> 'f4 encoding ->
    'f5 encoding -> 'f6 encoding ->
    ('f1 * 'f2 * 'f3 * 'f4 * 'f5 * 'f6) encoding
  val tup7 :
    'f1 encoding -> 'f2 encoding -> 'f3 encoding -> 'f4 encoding ->
    'f5 encoding -> 'f6 encoding -> 'f7 encoding ->
    ('f1 * 'f2 * 'f3 * 'f4 * 'f5 * 'f6 * 'f7) encoding
  val tup8 :
    'f1 encoding -> 'f2 encoding -> 'f3 encoding -> 'f4 encoding ->
    'f5 encoding -> 'f6 encoding -> 'f7 encoding -> 'f8 encoding ->
    ('f1 * 'f2 * 'f3 * 'f4 * 'f5 * 'f6 * 'f7 * 'f8) encoding
  val tup9 :
    'f1 encoding -> 'f2 encoding -> 'f3 encoding -> 'f4 encoding ->
    'f5 encoding -> 'f6 encoding -> 'f7 encoding -> 'f8 encoding ->
    'f9 encoding ->
    ('f1 * 'f2 * 'f3 * 'f4 * 'f5 * 'f6 * 'f7 * 'f8 * 'f9) encoding
  val tup10 :
    'f1 encoding -> 'f2 encoding -> 'f3 encoding -> 'f4 encoding ->
    'f5 encoding -> 'f6 encoding -> 'f7 encoding -> 'f8 encoding ->
    'f9 encoding -> 'f10 encoding ->
    ('f1 * 'f2 * 'f3 * 'f4 * 'f5 * 'f6 * 'f7 * 'f8 * 'f9 * 'f10) encoding


  (** Create a large tuple encoding from two smaller ones.
      @raise invalid_arg if both values are not tuples. *)
  val merge_tups : 'a1 encoding -> 'a2 encoding -> ('a1 * 'a2) encoding

  (** {3 Sum descriptors} *)

  (** A partial encoding to represent a case in a variant type.  Hides
      the (existentially bound) type of the parameter to the specific
      case, providing its encoder, and converter functions to and from
      the union type. *)
  type 't case
  type case_tag = Tag of int | Json_only

  (** Encodes a variant constructor. Takes the encoding for the specific
      parameters, a recognizer function that will extract the parameters
      in case the expected case of the variant is being serialized, and
      a constructor function for deserialization.

      The tag must be less than the tag size of the union in which you use the case.
      An optional tag gives a name to a case and should be used to maintain
      compatibility.

      An optional name for the case can be provided,
      which is used in the binary documentation. *)
  val case :
    ?name:string ->
    case_tag ->
    'a encoding -> ('t -> 'a option) -> ('a -> 't) -> 't case

  (** Create a single encoding from a series of cases.

      In JSON, all cases are tried one after the other. The caller must
      check for collisions.

      In binary, a prefix tag is added to discriminate quickly between
      cases. The default is `Uint8 and you must use a `Uint16 if you are
      going to have more than 256 cases.

      This function will raise an exception if it is given the empty list
      or if there are more cases than can fit in the tag size. *)
  val union :
    ?tag_size:[ `Uint8 | `Uint16 ] -> 't case list -> 't encoding

  (** {3 Predicates over descriptors} *)


  (** Is the given encoding serialized as a JSON object? *)
  val is_obj : 'a encoding -> bool

  (** Does the given encoding encode a tuple? *)
  val is_tup : 'a encoding -> bool

  (** Classify an encoding wrt. its binary serialization as explained in the preamble. *)
  val classify : 'a encoding -> [ `Fixed of int | `Dynamic | `Variable ]

  (** {3 Specialized descriptors} *)

  (** Encode enumeration via association list
      (represented as a string in JSON and binary). *)
  val string_enum : (string * 'a) list -> 'a encoding

  (** Create encodings that produce data of a fixed length when binary encoded.
      See the preamble for an explanation. *)
  module Fixed : sig
    val string : int -> string encoding
    val bytes : int -> MBytes.t encoding
  end

  (** Create encodings that produce data of a variable length when binary encoded.
      See the preamble for an explanation. *)
  module Variable : sig
    val string : string encoding
    val bytes : MBytes.t encoding
    val array : 'a encoding -> 'a array encoding
    val list : 'a encoding -> 'a list encoding
  end

  (** Mark an encoding as being of dynamic size.
      Forces the size to be stored alongside content when needed.
      Usually used to fix errors from combining two encodings. *)
  val dynamic_size : 'a encoding -> 'a encoding

  (** Recompute the encoding definition each time it is used.
      Useful for dynamically updating the encoding of values of an extensible
      type via a global reference (e.g. exceptions). *)
  val delayed : (unit -> 'a encoding) -> 'a encoding

  (** Define different encodings for JSON and binary serialization. *)
  val splitted : json:'a encoding -> binary:'a encoding -> 'a encoding

  (** Combinator for recursive encodings. *)
  val mu : string -> ('a encoding -> 'a encoding) -> 'a encoding

  (** {3 Documenting descriptors} *)

  (** Add documentation to an encoding. *)
  val describe :
    ?title:string -> ?description:string ->
    't encoding ->'t encoding

  (** Give a name to an encoding. *)
  val def : string -> 'a encoding -> 'a encoding

end

include module type of Encoding with type 'a t = 'a Encoding.t

module Json: sig

  (** In memory JSON data, compatible with [Ezjsonm]. *)
  type json =
    [ `O of (string * json) list
    | `Bool of bool
    | `Float of float
    | `A of json list
    | `Null
    | `String of string ]
  type t = json
  type schema = Json_schema.schema


  (** Encodes raw JSON data (BSON is used for binary). *)
  val encoding : json Encoding.t

  (** Encodes a JSON schema (BSON encoded for binary). *)
  val schema_encoding : schema Encoding.t

  (** Create a {!Json_encoding.encoding} from an {encoding}. *)
  val convert : 'a Encoding.t -> 'a Json_encoding.encoding

  (** Generate a schema from an {!encoding}. *)
  val schema : 'a Encoding.t -> schema

  (** Construct a JSON object from an encoding. *)
  val construct : 't Encoding.t -> 't -> json

  (** Destruct a JSON object into a value.
      Fail with an exception if the JSON object and encoding do not match.. *)
  val destruct : 't Encoding.t -> json -> 't

  (** JSON Error. *)

  type path = path_item list

  (** A set of accessors that point to a location in a JSON object. *)
  and path_item =
    [ `Field of string
    (** A field in an object. *)
    | `Index of int
    (** An index in an array. *)
    | `Star
    (** Any / every field or index. *)
    | `Next
      (** The next element after an array. *)
    ]

  (** Exception raised by destructors, with the location in the original
      JSON structure and the specific error. *)
  exception Cannot_destruct of (path * exn)

  (** Unexpected kind of data encountered (w/ the expectation). *)
  exception Unexpected of string * string

  (** Some {!union} couldn't be destructed, w/ the reasons for each {!case}. *)
  exception No_case_matched of exn list

  (** Array of unexpected size encountered  (w/ the expectation). *)
  exception Bad_array_size of int * int

  (** Missing field in an object. *)
  exception Missing_field of string

  (** Supernumerary field in an object. *)
  exception Unexpected_field of string

  val print_error :
    ?print_unknown: (Format.formatter -> exn -> unit) ->
    Format.formatter -> exn -> unit

  (** Helpers for writing encoders. *)
  val cannot_destruct : ('a, Format.formatter, unit, 'b) format4 -> 'a
  val wrap_error : ('a -> 'b) -> 'a -> 'b

  (** Read a JSON document from a string. *)
  val from_string : string -> (json, string) result

  (** Read a stream of JSON documents from a stream of strings.
      A single JSON document may be represented in multiple consecutive
      strings. But only the first document of a string is considered. *)
  val from_stream : string Lwt_stream.t -> (json, string) result Lwt_stream.t

  (** Write a JSON document to a string. This goes via an intermediate
      buffer and so may be slow on large documents. *)
  val to_string : ?minify:bool -> json -> string

  val pp : Format.formatter -> json -> unit

end

module Bson: sig

  type bson = Json_repr_bson.bson
  type t = bson

  (** Construct a BSON object from an encoding. *)
  val construct : 't Encoding.t -> 't -> bson

  (** Destruct a BSON object into a value.
      Fail with an exception if the JSON object and encoding do not match.. *)
  val destruct : 't Encoding.t -> bson -> 't

end

module Binary: sig

  val length : 'a Encoding.t -> 'a -> int
  val read : 'a Encoding.t -> MBytes.t -> int -> int -> (int * 'a) option
  val write : 'a Encoding.t -> 'a -> MBytes.t -> int -> int option
  val to_bytes : 'a Encoding.t -> 'a -> MBytes.t
  val of_bytes : 'a Encoding.t -> MBytes.t -> 'a option
  val of_bytes_exn : 'a Encoding.t -> MBytes.t -> 'a

  (** [to_bytes_list ?copy_blocks blocks_size encod data] encode the
      given data as a list of successive blocks of length
      'blocks_size' at most.

      NB. If 'copy_blocks' is false (default), the blocks of the list
      can be garbage-collected only when all the blocks are
      unreachable (because of the 'optimized' implementation of
      MBytes.sub used internally *)
  val to_bytes_list : ?copy_blocks:bool -> int  -> 'a Encoding.t -> 'a -> MBytes.t list

  (** This type is used when decoding binary data incrementally.
      - In case of 'Success', the decoded data, the size of used data
       to decode the result, and the remaining data are returned
      - In case of error, 'Error' is returned
      - 'Await' status embeds a function that waits for additional data
       to continue decoding, when given data are not sufficient *)
  type 'a status =
    | Success of { res : 'a ; res_len : int ; remaining : MBytes.t list }
    | Await of (MBytes.t -> 'a status)
    | Error

  (** This function allows to decode (or to initialize decoding) a
      stream of 'MByte.t'. The given data encoding should have a
      'Fixed' or a 'Dynamic' size, otherwise an exception
      'Invalid_argument "streaming data with variable size"' is
      raised *)
  val read_stream_of_bytes : ?init:MBytes.t list -> 'a Encoding.t -> 'a status

  (** Like read_stream_of_bytes, but only checks that the stream can
      be read. Note that this is an approximation because failures
      that may come from conversion functions present in encodings are
      not checked *)
  val check_stream_of_bytes : ?init:MBytes.t list -> 'a Encoding.t -> unit status
  val fixed_length : 'a Encoding.t -> int option
  val fixed_length_exn : 'a Encoding.t -> int

end

type json = Json.t
val json: json Encoding.t
type json_schema = Json.schema
val json_schema: json_schema Encoding.t
type bson = Bson.t
