(*
 * Copyright (C) 2009-2013 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

module Status : sig
  type t =
    | Read
    | Write
    | Resizeable
    | Clustered
  with sexp

  include S.PRINT with type t := t

  type error = [
    | `Msg of string
  ]
  type 'a result = ('a, error) Result.result

  val of_string: string -> t result
end

type error = [
  | `UnknownLV of string
  | `DuplicateLV of string
  | `OnlyThisMuchFree of int64 (** needed *) * int64 (** available *)
  | `Msg of string
]

module LVs : sig
  include Map.S with type key = Uuid.t
  val find_by_name : string -> Lv.t t -> Lv.t
end

type metadata = {
  name : string;                (** name given by the user *)
  id : Uuid.t;                  (** arbitrary unique id *)
  creation_host: string;        (** some host identifier *)
  creation_time: int64;         (** seconds since epoch *)
  seqno : int;                  (** sequence number of the next operation *)
  status : Status.t list;       (** status flags *)
  extent_size : int64;          (** the size of a block ("extent") in 512 byte sectors *)
  max_lv : int;
  max_pv : int;
  pvs : Pv.t list;              (** physical volumes *)
  lvs : Lv.t LVs.t;             (** logical volumes *)
  free_space : Pv.Allocator.t;  (** free space in physical volumes, which can be used for logical volumes *)
} with sexp
(** A volume group *)

include S.MARSHAL with type t := metadata
include S.PRINT with type t := metadata
include S.VOLUME
  with type t := metadata
  and type name := string
  and type tag := string
  and type lv_status := Lv.Status.t
  and type size := int64
  and type op := Redo.Op.t
  and type error := error

val pp_error: Format.formatter -> error -> unit
val error_to_msg: 'a result -> ('a, [ `Msg of string ]) Result.result

val do_op: metadata -> Redo.Op.t -> (metadata * Redo.Op.t) result
(** [do_op t op] performs [op], returning the modified volume group [t] *)

module Make(Log: S.LOG)(Block: S.BLOCK)(Time: S.TIME)(Clock: S.CLOCK) : sig

  type vg
  (** A volume group spread over a set of block devices *)

  val metadata_of: vg -> metadata
  (** Extract a snapshot of the volume group metadata *)

  val format: string -> ?creation_host:string -> ?creation_time:int64 ->
      ?magic:Magic.t -> (Pv.Name.t * Block.t) list -> unit result Lwt.t
  (** [format name ?creation_host ?creation_time ?magic devices_and_names]
      initialises a new volume group with name [name], using physical volumes [devices] *)

  val connect: ?flush_interval:float -> Block.t list -> [ `RO | `RW ]
      -> vg result Lwt.t
  (** [connect ?seconds disks flag] opens a volume group contained on [devices].
      If `RO is provided then no updates will be persisted to disk,
      this is particularly useful if the volume group is opened for writing
      somewhere else. If `RW is provided then updates will be appended to
      a redo log and flushed to the LVM metadata. The optional ?flush_interval
      imposes a interval between successive rewrites of the LVM metadata to
      encourage batching. *)

  val update: vg -> Redo.Op.t list -> unit result Lwt.t
  (** [update t updates] performs the operations [updates] and ensures
      the changes are persisted. *)

  val sync: vg -> unit result Lwt.t
  (** [sync t] flushes all pending writes associated with [t] to the
      main metadata area. This is only needed if you plan to switch off
      the redo-log. *)

  module Volume : sig
    include V1_LWT.BLOCK

    val connect: id -> [ `Ok of t | `Error of error ] Lwt.t

    val metadata_of: id -> Lv.t
    (** return the metadata associated with a volume *)
  end

  val find: vg -> string -> Volume.id option
  (** [find vg name] finds the volume with name [name] *)
end
