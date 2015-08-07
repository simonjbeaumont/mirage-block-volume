(*
 * Copyright (C) 2009-2015 Citrix Systems Inc.
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
open Sexplib.Std
open Lvm_internal
open Absty
open Expect
open Redo
open Result

let (>>|=) m f = Lwt.bind m (function
| `Error e -> Lwt.return (`Error e)
| `Ok x -> f x)

module Status = struct
  type t =
    | Read
    | Write
    | Resizeable
    | Clustered
  with sexp

  type error = [
    | `Msg of string
  ]
  type 'a result = ('a, error) Result.result

  let to_string = function
    | Resizeable -> "RESIZEABLE"
    | Write -> "WRITE"
    | Read -> "READ"
    | Clustered -> "CLUSTERED"

  let of_string = function
    | "RESIZEABLE" -> return Resizeable
    | "WRITE" -> return Write
    | "READ" -> return Read
    | "CLUSTERED" -> return Clustered
    | x -> `Error (`Msg (Printf.sprintf "Bad VG status string: %s" x))
end

type lv_status = Lv.Status.t

module StringMap = Map.Make(struct
  type t = string
  let compare (a: string) (b: string) = compare a b
end)

module UuidMap = Map.Make(struct
  type t = Uuid.t
  let compare (a: t) (b: t) = compare a b
end)

module LVs = struct
  include UuidMap

  let find_by_name name t =
    filter (fun _ lv -> lv.Lv.name = name) t |> choose |> snd

  type t' = (Uuid.t * Lv.t) list with sexp
  let t_of_sexp _ s =
    let t' = t'_of_sexp s in
    List.fold_left (fun map (k, v) -> UuidMap.add k v map) UuidMap.empty t'
  let sexp_of_t _ t =
    let t' = UuidMap.fold (fun k v acc -> (k, v) :: acc) t [] in
    sexp_of_t' t'
end

type metadata = {
  name : string;
  id : Uuid.t;
  creation_host: string;
  creation_time: int64;
  seqno : int;
  status : Status.t list;
  extent_size : int64;
  max_lv : int;
  max_pv : int;
  pvs : Pv.t list; (* Device to pv map *)
  lvs : Lv.t LVs.t;
  free_space : Pv.Allocator.t;
  (* XXX: hook in the redo log *)
} with sexp

let to_string metadata = Sexplib.Sexp.to_string_hum (sexp_of_metadata metadata)
  
let marshal vg b =
  let b = ref b in
  let bprintf fmt = Printf.kprintf (fun s ->
    let len = String.length s in
    Cstruct.blit_from_string s 0 !b 0 len;
    b := Cstruct.shift !b len
  ) fmt in
  bprintf "%s {\nid = \"%s\"\nseqno = %d\n" vg.name (Uuid.to_string vg.id) vg.seqno;
  bprintf "status = [%s]\nextent_size = %Ld\nmax_lv = %d\nmax_pv = %d\n\n"
    (String.concat ", " (List.map (o quote Status.to_string) vg.status))
    vg.extent_size vg.max_lv vg.max_pv;
  bprintf "physical_volumes {\n";
  b := List.fold_left (fun b pv -> Pv.marshal pv b) !b vg.pvs;
  bprintf "}\n\n";

  bprintf "logical_volumes {\n";
  b := LVs.fold (fun _ lv b -> Lv.marshal lv b) vg.lvs !b;
  bprintf "}\n}\n";

  bprintf "# Generated by MLVM version 0.1: \n\n";
  bprintf "contents = \"Text Format Volume Group\"\n";
  bprintf "version = 1\n\n";
  bprintf "description = \"\"\n\n";
  bprintf "creation_host = \"%s\"\n" vg.creation_host;
  bprintf "creation_time = %Ld\n\n" vg.creation_time;
  !b
    
(*************************************************************)
(* METADATA CHANGING OPERATIONS                              *)
(*************************************************************)

type op = Redo.Op.t

type error = [
  | `UnknownLV of string
  | `DuplicateLV of string
  | `OnlyThisMuchFree of int64 * int64
  | `Msg of string
]

type 'a result = ('a, error) Result.result

let pp_error fmt = function
  | `Msg x -> Format.pp_print_string fmt x 
  | `UnknownLV x ->
    Format.fprintf fmt "The LV %s was not found" x
  | `DuplicateLV x ->
    Format.fprintf fmt "The LV name already exists: %s" x
  | `OnlyThisMuchFree(needed, available) ->
    Format.fprintf fmt "Only this much space free: %Ld (needed %Ld)" available needed

let error_to_msg = function
  | `Ok x -> `Ok x
  | `Error y ->
    let b = Buffer.create 16 in
    let fmt = Format.formatter_of_buffer b in
    pp_error fmt y;
    Format.pp_print_flush fmt ();
    `Error (`Msg (Buffer.contents b))

let with_lv vg lv_id fn =
  try LVs.find lv_id vg.lvs |> fn
  with Not_found -> `Error (`UnknownLV (Uuid.to_string lv_id))

let with_lv_by_name vg lv_name fn =
  try LVs.find_by_name lv_name vg.lvs |> fn
  with Not_found -> `Error (`UnknownLV (lv_name))

let expand vg id segments =
  let open Redo.Op in
  with_lv vg id (fun lv ->
    (* Compute the new physical extents, remove from free space *)
    let extents = List.fold_left (fun acc x ->
      Pv.Allocator.merge acc (Lv.Segment.to_allocation x)
    ) [] segments in
    let free_space = Pv.Allocator.sub vg.free_space extents in
    (* This operation is idempotent so we assume that segments may be
        duplicated. We remove the duplicates here. *)
    let segments =
          Lv.Segment.sort (segments @ lv.Lv.segments)
      |> List.fold_left (fun (last_start, acc) segment ->
            (* Check if the segments are identical *)
            if segment.Lv.Segment.start_extent = last_start
            then last_start, acc
            else segment.Lv.Segment.start_extent, segment :: acc
          ) (-1L, [])
      |> snd
      |> List.rev in
    let lv = {lv with Lv.segments} in
    return {vg with lvs = LVs.add lv.Lv.id lv vg.lvs; free_space=free_space}
  )

let do_op vg op : (metadata * op) result =
  let open Redo.Op in
  match op with
  | LvCreate lv ->
    let new_free_space = Pv.Allocator.sub vg.free_space (Lv.to_allocation lv) in
    return ({vg with lvs = LVs.add lv.Lv.id lv vg.lvs; free_space = new_free_space},op)
  | LvExpand (id, l) -> expand vg id l.lvex_segments >>= fun vg -> return (vg, op)
  | LvTransfer (src, dst, segments) ->
    with_lv vg src (fun src_lv ->
      let current = Lv.to_allocation src_lv in
      let to_free = List.fold_left Pv.Allocator.merge [] (List.map Lv.Segment.to_allocation segments) in
      let reduced = Pv.Allocator.sub current to_free in
      let segments' = Lv.Segment.linear 0L reduced in
      let src_lv = { src_lv with Lv.segments = segments' } in
      let vg = {vg with lvs = LVs.add src_lv.Lv.id src_lv vg.lvs} in
      expand vg dst segments >>= fun vg -> return (vg, op)
    )
  | LvReduce (id, l) ->
    with_lv vg id (fun lv ->
      let allocation = Lv.to_allocation lv in
      Lv.reduce_size_to lv l.lvrd_new_extent_count >>= fun lv ->
      let new_allocation = Lv.to_allocation lv in
      let free_space = Pv.Allocator.sub (Pv.Allocator.merge vg.free_space allocation) new_allocation in
      return ({vg with lvs = LVs.add lv.Lv.id lv vg.lvs; free_space},op))
  | LvRemove id ->
    begin match with_lv vg id (fun lv ->
      let allocation = Lv.to_allocation lv in
      return ({vg with lvs = LVs.remove lv.Lv.id vg.lvs; free_space = Pv.Allocator.merge vg.free_space allocation },op))
    with | `Error (`UnknownLV _) -> return (vg, op) | r -> r end
  | LvRename (id, l) ->
    with_lv vg id (fun lv ->
      let lvs = LVs.(add id { lv with Lv.name = l.lvmv_new_name }
        (remove lv.Lv.id vg.lvs)) in
      return ({vg with lvs }, op))
  | LvAddTag (id, tag) ->
    with_lv vg id (fun lv ->
      let tags = lv.Lv.tags in
      let lv' = {lv with Lv.tags = if List.mem tag tags then tags else tag::tags} in
      return ({vg with lvs = LVs.add lv.Lv.id lv' vg.lvs},op))
  | LvRemoveTag (id, tag) ->
    with_lv vg id (fun lv ->
      let tags = lv.Lv.tags in
      let lv' = {lv with Lv.tags = List.filter (fun t -> t <> tag) tags} in
      return ({vg with lvs = LVs.add lv.Lv.id lv' vg.lvs},op))
  | LvSetStatus (id, status) ->
    with_lv vg id (fun lv ->
      let lv' = {lv with Lv.status=status} in
      return ({vg with lvs = LVs.add lv.Lv.id lv' vg.lvs},op))

(* Convert from bytes to extents, rounding up *)
let bytes_to_extents bytes vg =
  let extents_in_sectors = vg.extent_size in
  let open Int64 in
  let extents_in_bytes = mul extents_in_sectors 512L in
  div (add bytes (sub extents_in_bytes 1L)) extents_in_bytes

let create vg name ?(creation_host="unknown") ?(creation_time=0L) ?(tags=[]) ?(status=Lv.Status.([Read; Write; Visible])) size : ('a, error) Result.result = 
  if LVs.exists (fun _ lv -> lv.Lv.name = name) vg.lvs
  then `Error (`DuplicateLV name)
  else match Pv.Allocator.find vg.free_space (bytes_to_extents size vg) with
  | `Ok lvc_segments ->
    let segments = Lv.Segment.sort (Lv.Segment.linear 0L lvc_segments) in
    let id = Uuid.create () in
    Name.open_error @@ all @@ List.map Name.Tag.of_string tags >>= fun tags ->
    let lv = Lv.({ name; id; tags; status; creation_host; creation_time; segments }) in
    do_op vg Redo.Op.(LvCreate lv)
  | `Error (`OnlyThisMuchFree (needed, available)) ->
    `Error (`OnlyThisMuchFree (needed, available))

let rename vg old_name new_name =
  with_lv_by_name vg old_name (fun lv ->
    do_op vg Redo.Op.(LvRename (lv.Lv.id,{lvmv_new_name=new_name})))

let resize vg name new_size =
  let new_size = bytes_to_extents new_size vg in
  with_lv_by_name vg name
    (fun lv ->
      let current_size = Lv.size_in_extents lv in
      let to_allocate = Int64.sub new_size current_size in
      if to_allocate > 0L then match Pv.Allocator.find vg.free_space to_allocate with
      | `Ok extents ->
         let lvex_segments = Lv.Segment.linear current_size extents in
         return Redo.Op.(LvExpand (lv.Lv.id,{lvex_segments}))
      | `Error (`OnlyThisMuchFree (needed, available)) ->
        `Error (`OnlyThisMuchFree (needed, available))
      else
         return Redo.Op.(LvReduce (lv.Lv.id,{lvrd_new_extent_count=new_size}))
    ) >>= fun op ->
  do_op vg op

let remove vg name =
  with_lv_by_name vg name (fun lv ->
    do_op vg Redo.Op.(LvRemove lv.Lv.id))

let add_tag vg name tag =
  with_lv_by_name vg name (fun lv ->
    Name.open_error @@ Name.Tag.of_string tag >>= fun tag ->
    do_op vg Redo.Op.(LvAddTag (lv.Lv.id, tag)))

let remove_tag vg name tag =
  with_lv_by_name vg name (fun lv ->
    Name.open_error @@ Name.Tag.of_string tag >>= fun tag ->
    do_op vg Redo.Op.(LvRemoveTag (lv.Lv.id, tag)))

let set_status vg name status =
  with_lv_by_name vg name (fun lv ->
  do_op vg Redo.Op.(LvSetStatus (lv.Lv.id,status)))

module Make(Log: S.LOG)(Block: S.BLOCK)(Time: S.TIME)(Clock: S.CLOCK) = struct

module Pv_IO = Pv.Make(Block)
module Label_IO = Label.Make(Block)
module Metadata_IO = Metadata.Make(Block)

open IO

type devices = (Pv.Name.t * Block.t) list

module Volume = struct
  type id = {
    metadata: metadata; (* need pe_start *)
    devices: devices;
    lv: Lv.t;
  }

  let metadata_of { lv } = lv

  type t = {
    id: id;
    devices: devices;
    name_to_pe_starts: (Pv.Name.t * int64) list;
    sector_size: int;
    extent_size: int64;
    lv: Lv.t;
    mutable disconnected: bool;
  }

  let id t = t.id

  type error = [
    | `Unknown of string
    | `Unimplemented
    | `Is_read_only
    | `Disconnected
  ]

  type info = {
    read_write: bool;
    sector_size: int;
    size_sectors: int64;
  }

  type 'a io = 'a Lwt.t

  type page_aligned_buffer = Cstruct.t

  open Lwt

  let connect ({ metadata; devices; lv } as id) =
    (* We need the to add the pe_start later *)
    let name_to_pe_starts = List.map (fun (name, _) ->
      let pv = List.find (fun x -> x.Pv.name = name) metadata.pvs in
      name, pv.Pv.pe_start
    ) devices in
    (* We require all the devices to have identical sector sizes *)
    Lwt_list.map_p
      (fun (_, device) ->
        Block.get_info device
        >>= fun info ->
        return info.Block.sector_size
      ) devices
    >>= fun sizes ->
    let biggest = List.fold_left max min_int sizes in
    let smallest = List.fold_left min max_int sizes in
    if biggest <> smallest
    then return (`Error (`Unknown (Printf.sprintf "The underlying block devices have mixed sector sizes: %d <> %d" smallest biggest)))
    else
      (* We don't need to hang onto the VG metadata as the `type id` is abstract
         and therefore no-one can interpret the values! *)
      let id = { id with metadata = { id.metadata with lvs = LVs.empty } } in
      return (`Ok {
        id; devices; sector_size = biggest; extent_size = metadata.extent_size;
        disconnected = false; lv; name_to_pe_starts
      })

  let get_info t =
    let read_write = List.mem Lv.Status.Write t.lv.Lv.status in
    let segments = List.fold_left (fun acc s -> Int64.add acc s.Lv.Segment.extent_count) 0L t.lv.Lv.segments in
    let size_sectors = Int64.mul segments t.extent_size in
    return { read_write; sector_size = t.sector_size; size_sectors }

  let io op t sector_start buffers =
    if t.disconnected
    then return (`Error `Disconnected)
    else begin
      let rec loop sector_start = function
      | [] -> return (`Ok ())
      | b :: bs ->
        let start_le = Int64.div sector_start t.extent_size in
        let start_offset = Int64.rem sector_start t.extent_size in
        match Lv.find_extent t.lv start_le with
        | Some { Lv.Segment.cls = Lv.Segment.Linear l; start_extent; extent_count } ->
          let start_pe = Int64.(add l.Lv.Linear.start_extent (sub start_le start_extent)) in
          let phys_offset = Int64.(add (mul start_pe t.extent_size) start_offset) in
          let will_read = min (Cstruct.len b / t.sector_size) (Int64.to_int t.extent_size) in
          if List.mem_assoc l.Lv.Linear.name t.devices then begin
            let device = List.assoc l.Lv.Linear.name t.devices in
            let pe_start = List.assoc l.Lv.Linear.name t.name_to_pe_starts in
            op device (Int64.add pe_start phys_offset) [ Cstruct.sub b 0 (will_read * t.sector_size) ]
            >>|= fun () ->
            let b = Cstruct.shift b (will_read * t.sector_size) in
            let bs = if Cstruct.len b > 0 then b :: bs else bs in
            let sector_start = Int64.(add sector_start (of_int will_read)) in
            loop sector_start bs
          end else return (`Error (`Unknown (Printf.sprintf "Unknown physical volume %s" (Pv.Name.to_string l.Lv.Linear.name))))
        | None -> return (`Error (`Unknown (Printf.sprintf "Logical extent %Ld has no segment" start_le))) in
      loop sector_start buffers
    end

  let read = io Block.read
  let write = io Block.write

  let disconnect t =
    t.disconnected <- true;
    return ()
end

module Redo_log = Shared_block.Journal.Make(Log)(Volume)(Time)(Clock)(Redo.Op)

type vg = {
  mutable metadata: metadata;
  devices: devices;
  redo_log: Redo_log.t option;
  mutable wait_for_flush_t: unit -> unit Lwt.t;
  m: Lwt_mutex.t;
  flag: [ `RO | `RW ];
}

let metadata_of vg = vg.metadata

let find { metadata; devices } name =
  try
     let lv =
       LVs.(filter (fun _ lv -> lv.Lv.name = name) metadata.lvs |> choose)
       |> snd
     in
     Some { Volume.metadata; devices; lv }
  with Not_found ->
     None

let id_to_devices devices : 'a result Lwt.t =
  (* We need the uuid contained within the Pv_header to figure out
     the mapping between PV and real device. Note we don't use the
     device 'hint' within the metadata itself. *)
  IO.FromResult.all (Lwt_list.map_p (fun device ->
    let open Lwt in
    Label_IO.read device
    >>= fun r ->
    let open IO.FromResult in
    Label.open_error r
    >>= fun label ->
    let open Lwt in
    Lwt.return (`Ok (label.Label.pv_header.Label.Pv_header.id, device))
  ) devices)

let write metadata devices : unit result Lwt.t =
  let devices = List.map snd devices in
  id_to_devices devices
  >>= fun id_to_devices ->

  let buf = Cstruct.create (Int64.to_int Constants.max_metadata_size) in
  let buf' = marshal metadata buf in
  let md = Cstruct.sub buf 0 buf'.Cstruct.off in
  let open IO.FromResult in
  let rec write_pv pv acc = function
    | [] -> return (List.rev acc)
    | m :: ms ->
      if not(List.mem_assoc pv.Pv.id id_to_devices)
      then Lwt.return (`Error (`Msg (Printf.sprintf "Unable to find device corresponding to PV %s" (Uuid.to_string pv.Pv.id))))
      else begin
        let open Lwt in
        Metadata_IO.write (List.assoc pv.Pv.id id_to_devices) m md >>= fun h ->
        let open IO.FromResult in
        Metadata.open_error h
        >>= fun h ->
        write_pv pv (h :: acc) ms
      end in
  let rec write_vg acc = function
    | [] -> return (List.rev acc)
    | pv :: pvs ->
      if not(List.mem_assoc pv.Pv.id id_to_devices)
      then Lwt.return (`Error (`Msg (Printf.sprintf "Unable to find device corresponding to PV %s" (Uuid.to_string pv.Pv.id))))
      else begin
        let open Lwt in
        Label_IO.write (List.assoc pv.Pv.id id_to_devices) pv.Pv.label >>= fun r ->
        let open IO.FromResult in
        Label.open_error r
        >>= fun () -> 
        let open IO in
        write_pv pv [] pv.Pv.headers >>= fun headers ->
        write_vg ({ pv with Pv.headers = headers } :: acc) pvs
      end in
  let open IO in
  write_vg [] metadata.pvs >>= fun _pvs ->
  return ()

let run metadata ops : metadata result Lwt.t =
  let open Result in
  let rec loop metadata = function
    | [] -> return metadata
    | x :: xs ->
      do_op metadata x
      >>= fun (metadata, _) ->
      loop metadata xs in
  Lwt.return (loop metadata ops)

let _redo_log_name = "mirage_block_volume_redo_log"
let _redo_log_size = Int64.(mul 32L (mul 1024L 1024L))

let format name ?(creation_host="unknown") ?(creation_time=0L) ?(magic = `Lvm) devices =
  let open IO in
  let rec write_pv acc = function
    | [] -> return (List.rev acc)
    | (name, dev) :: pvs ->
      Pv_IO.format dev ~magic name >>= fun pv ->
      write_pv (pv :: acc) pvs in
  let open Lwt in
  write_pv [] devices >>= fun pvs ->
  let open IO.FromResult in
  Pv.open_error pvs
  >>= fun pvs ->
  let open IO in
  let free_space = List.flatten (List.map (fun pv -> Pv.Allocator.create pv.Pv.name pv.Pv.pe_count) pvs) in
  let vg = { name; id=Uuid.create (); creation_host; creation_time; seqno=1; status=[Status.Read; Status.Write; Status.Resizeable];
    extent_size=Constants.extent_size_in_sectors; max_lv=0; max_pv=0; pvs;
    lvs=LVs.empty; free_space; } in
  ( match magic with
    | `Lvm -> return vg
    | `Journalled ->
      ( match create vg _redo_log_name _redo_log_size ~creation_host ~creation_time with
        | `Ok (metadata, Redo.Op.LvCreate lv) ->
          let module Eraser = EraseBlock.Make(Volume) in
          begin let open Lwt in
            let lv = { Volume.metadata; devices; lv } in
            Volume.connect lv
            >>= function
            | `Ok disk ->
              let open IO in
              Eraser.erase ~pattern:"Block erased because this is the mirage-block-volume redo_log" disk
              >>= fun () ->
              return metadata
            | `Error _ -> Lwt.return (`Error (`Msg "Failed to open the redo_log to erase it"))
          end
        | `Ok (_, _) ->
          (* create guarantees to return a Redo.Op.LvCreate *)
          assert false
        | `Error x -> Lwt.return (`Error x)
      )
  ) >>= fun metadata ->
  write metadata devices >>= fun () ->
  return ()

let read flush_interval devices flag : vg result Lwt.t =
  id_to_devices devices
  >>= fun id_to_devices ->
  let id_to_devices = (id_to_devices :> (Uuid.t * Block.t) list) in
  (* Read metadata from any of the provided devices *)
  ( match devices with
    | [] -> return (`Error (`Msg "Vg.read needs at least one device"))
    | devices -> begin
      IO.FromResult.all (Lwt_list.map_s
        (fun device ->
          (Pv_IO.read_metadata device :> Cstruct.t result Lwt.t)
        ) devices)
      >>= function
      | [] -> return (`Error (`Msg "Failed to find metadata on any of the devices"))
      | md :: _ ->
        let text = Cstruct.to_string md in
        let lexbuf = Lexing.from_string text in
        return (`Ok (Lvmconfigparser.start Lvmconfiglex.lvmtok lexbuf))
      end
  ) >>= fun config ->
  let config = (config :> Lvm_internal.Absty.absty result) in
  let open IO.FromResult in
  ( match config with
    | `Ok (AStruct c) -> `Ok c
    | _ -> `Error (`Msg "VG metadata doesn't begin with a structure element") ) >>= fun config ->
  let vg = filter_structs config in
  ( match vg with
    | [ name, _ ] -> `Ok name
    | [] -> `Error (`Msg "VG metadata contains no defined volume groups")
    | _ -> `Error (`Msg "VG metadata contains multiple volume groups") ) >>= fun name ->
  expect_mapped_struct name vg >>= fun alist ->
  expect_mapped_string "id" alist >>= fun id ->
  expect_mapped_string "creation_host" config >>= fun creation_host ->
  expect_mapped_int "creation_time" config >>= fun creation_time ->
  (Uuid.of_string id :> Uuid.t result) >>= fun id ->
  expect_mapped_int "seqno" alist >>= fun seqno ->
  let seqno = Int64.to_int seqno in
  map_expected_mapped_array "status" 
    (fun a -> let open Result in expect_string "status" a >>= fun x ->
              Status.of_string x) alist >>= fun status ->
  expect_mapped_int "extent_size" alist >>= fun extent_size ->
  expect_mapped_int "max_lv" alist >>= fun max_lv ->
  let max_lv = Int64.to_int max_lv in
  expect_mapped_int "max_pv" alist >>= fun max_pv ->
  let max_pv = Int64.to_int max_pv in
  expect_mapped_struct "physical_volumes" alist >>= fun pvs ->
  ( match expect_mapped_struct "logical_volumes" alist with
    | `Ok lvs -> `Ok lvs
    | `Error _ -> `Ok [] ) >>= fun lvs ->
  let open IO in
  ( all (Lwt_list.map_s (fun (a,_) ->
    let open IO.FromResult in
    expect_mapped_struct a pvs >>= fun x ->
    expect_mapped_string "id" x >>= fun id ->
    match Uuid.of_string id with
    | `Ok id ->
      if not(List.mem_assoc id id_to_devices)
      then Lwt.return (`Error (`Msg (Printf.sprintf "Unable to find a device containing PV with id %s" (Uuid.to_string id))))
      else Pv_IO.read (List.assoc id id_to_devices) a x
    | `Error x -> fail x
  ) pvs) :> Pv.t list result Lwt.t) >>= fun pvs ->
  ( all (Lwt_list.map_s (fun (a,_) ->
    let open IO.FromResult in
    expect_mapped_struct a lvs >>= fun x ->
    Lwt.return (Lv.of_metadata a x)
  ) lvs) :> Lv.t list result Lwt.t) >>= fun lvs ->
  (* Now we need to set up the free space structure in the PVs *)
  let free_space = List.flatten (List.map (fun pv -> Pv.Allocator.create pv.Pv.name pv.Pv.pe_count) pvs) in

  let free_space = List.fold_left (fun free_space lv -> 
    let lv_allocations = Lv.to_allocation lv in
    Pv.Allocator.sub free_space lv_allocations) free_space lvs in
  let lvs = List.fold_left (fun acc lv -> LVs.add lv.Lv.id lv acc) LVs.empty lvs in
  let vg = { name; id; creation_host; creation_time; seqno; status; extent_size; max_lv; max_pv; pvs; lvs;  free_space; } in
  (* Segments reference PVs by name, not uuid, so we need to build up
     the name to device mapping. *)
  let id_to_name = List.map (fun pv -> pv.Pv.id, pv.Pv.name) pvs in
  let name_to_devices =
    id_to_devices
  |> List.map (fun (id, device) ->
      if List.mem_assoc id id_to_name
      then Some (List.assoc id id_to_name, device)
      else None (* passed in devices list was a proper superset of pvs in metadata *)
     )
  |> List.fold_left (fun acc x -> match x with None -> acc | Some x -> x :: acc) [] in
  
  let on_disk_metadata = ref vg in
  let perform ops =
    let open Lwt in
    run !on_disk_metadata ops
    >>|= fun metadata ->
    write metadata name_to_devices
    >>|= fun () ->
    on_disk_metadata := metadata;
    return (`Ok ()) in

  let redo_log = None in
  let wait_for_flush_t () = Lwt.return () in
  let m = Lwt_mutex.create () in
  let t = { metadata = vg; devices = name_to_devices; redo_log; wait_for_flush_t; m; flag } in

  (* Assuming the PV headers all have the same magic *)
  if flag = `RO
  then return t
  else match pvs with
  | { Pv.headers = h :: _ } :: _ ->
    begin match Metadata.Header.magic h with
    | `Lvm -> return t
    | `Journalled ->
      begin match find t _redo_log_name with
      | None ->
        Log.error "VG is set to Journalled mode but there is no %s" _redo_log_name;
        return t
      | Some lv ->
        begin let open Lwt in
        Volume.connect lv
        >>= function
        | `Ok disk ->
          let open Lwt in
          Log.info "Enabling redo-log on volume group";
          Redo_log.start ~name:_redo_log_name ~client:"mirage-block-volume" ~flush_interval disk (fun ops -> Lwt.map error_to_msg (perform ops))
          >>= fun r ->
          let open IO.FromResult in
          Redo_log.open_error r
          >>= fun r ->
          (* NB the metadata we read in is already out of date! *)
          return { t with metadata = !on_disk_metadata; redo_log = Some r }
        | `Error _ ->
          let open IO in
          Log.error "Failed to connect to the redo log volume";
          return t
        end
      end
    end
  | _ ->
    Log.error "Failed to read headers to discover whether we're in Journalled mode";
    return t

let connect ?(flush_interval=120.) devices flag = read flush_interval devices flag

let update vg ops : unit result Lwt.t =
  if vg.flag = `RO
  then Lwt.return (`Error (`Msg "Volume group is read-only"))
  else Lwt_mutex.with_lock vg.m
    (fun () ->
      run vg.metadata ops
      >>= fun metadata ->
      (* Write either to the metadata area or the redo-log *)
      ( match vg.redo_log with
        | None ->
          write metadata vg.devices
        | Some r ->
          (IO.FromResult.all (Lwt_list.map_s (Redo_log.push r) ops) :> Redo_log.waiter list result Lwt.t)
          >>= fun waiters ->
          let open Lwt in
          (* we only need the last waiter *)
          ( match List.rev waiters with
            | last :: _ -> vg.wait_for_flush_t <- last
            | [] -> () );
          return (`Ok ()) ) >>= fun () ->
      (* Update our cache of the metadata *)
      vg.metadata <- metadata;
      return ()
    )

let sync vg =
  let open Lwt in
  vg.wait_for_flush_t ()
  >>= fun () ->
  let open IO in
  return ()

end
