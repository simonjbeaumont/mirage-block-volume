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

open Absty
open Redo
open Logging

type status =
    | Read
    | Write
    | Resizeable
    | Clustered

and vg = {
  name : string;
  id : Lvm_uuid.t;
  seqno : int;
  status : status list;
  extent_size : int64;
  max_lv : int;
  max_pv : int;
  pvs : Pv.physical_volume list; (* Device to pv map *)
  lvs : Lv.logical_volume list;
  free_space : Allocator.t;
  redo_lv : string option; (* Name of the redo LV *)
  ops : sequenced_op list;
} with rpc
  
let status_to_string s =
  match s with
    | Resizeable -> "RESIZEABLE"
    | Write -> "WRITE"
    | Read -> "READ"
    | Clustered -> "CLUSTERED"

let status_of_string s =
  match s with 
    | "RESIZEABLE" -> Resizeable
    | "WRITE" -> Write
    | "READ" -> Read
    | "CLUSTERED" -> Clustered
    | _ -> failwith (Printf.sprintf "Unknown VG status string '%s'" s)

let write_to_buffer b vg =
  let bprintf = Printf.bprintf in
  bprintf b "%s {\nid = \"%s\"\nseqno = %d\n"
    vg.name (Lvm_uuid.to_string vg.id) vg.seqno;
  bprintf b "status = [%s]\nextent_size = %Ld\nmax_lv = %d\nmax_pv = %d\n\n"
    (String.concat ", " (List.map (o quote status_to_string) vg.status))
    vg.extent_size vg.max_lv vg.max_pv;

  bprintf b "physical_volumes {\n";
  List.iter (Pv.write_to_buffer b) vg.pvs;
  bprintf b "}\n\n";

  bprintf b "logical_volumes {\n";
  List.iter (Lv.write_to_buffer b) vg.lvs;
  bprintf b "}\n}\n";

  bprintf b "# Generated by MLVM version 0.1: \n\n";
  bprintf b "contents = \"Text Format Volume Group\"\n";
  bprintf b "version = 1\n\n";
  bprintf b "description = \"\"\n\n";
  bprintf b "creation_host = \"%s\"\n" "<need uname!>";
  bprintf b "creation_time = %Ld\n\n" (Int64.of_float (Unix.time ()))
    

let to_string vg = 
  let size=65536 in (* 64k. no particular reason *)
  let b = Buffer.create size in
  write_to_buffer b vg;
  Buffer.contents b


(*************************************************************)
(* METADATA CHANGING OPERATIONS                              *)
(*************************************************************)

let do_op vg op =
	(if vg.seqno <> op.so_seqno then failwith "Failing to do VG operation out-of-order");
	let rec createsegs ss lstart =
		match ss with
			| a::ss ->
				let length = Allocator.get_size a in
				let pv_name = Allocator.get_name a in
				({Lv.s_start_extent = lstart; s_extent_count = length;
				  s_cls = Lv.Linear {Lv.l_pv_name = pv_name;
					l_pv_start_extent=Allocator.get_start a}})::createsegs ss (Int64.add lstart length)
			| _ -> []
	in
	let change_lv lv_name fn =
		let lv,others = List.partition (fun lv -> lv.Lv.name=lv_name) vg.lvs in
		match lv with
			| [lv] ->
			  fn lv others
			| _ -> failwith "Unknown LV"
	in
	let vg = {vg with seqno = vg.seqno + 1; ops=op::vg.ops} in
	match op.so_op with
		| LvCreate (name,l) ->
			let new_free_space = Allocator.alloc_specified_areas vg.free_space l.lvc_segments in
			let segments = Lv.sort_segments (createsegs l.lvc_segments 0L) in
			let lv =
				{ Lv.name = name; id = l.lvc_id; tags = [];
				  status = [Lv.Read; Lv.Visible]; segments = segments } in
			{vg with lvs = lv::vg.lvs; free_space = new_free_space}
		| LvExpand (name,l) ->
			change_lv name (fun lv others ->
				let old_size = Lv.size_in_extents lv in
				let free_space = Allocator.alloc_specified_areas vg.free_space l.lvex_segments in
				let segments = createsegs l.lvex_segments old_size in
				let lv = {lv with Lv.segments = Lv.sort_segments (segments @ lv.Lv.segments)} in
				{vg with lvs = lv::others; free_space=free_space})
		| LvReduce (name,l) ->
			change_lv name (fun lv others ->
				let allocation = Lv.allocation_of_lv lv in
				let lv = Lv.reduce_size_to lv l.lvrd_new_extent_count in
				let new_allocation = Lv.allocation_of_lv lv in
				let free_space = Allocator.alloc_specified_areas (Allocator.free vg.free_space allocation) new_allocation in
				{vg with
				  lvs = lv::others; free_space=free_space})
		| LvRemove name ->
			change_lv name (fun lv others ->
				let allocation = Lv.allocation_of_lv lv in
				{vg with lvs = others; free_space = Allocator.free vg.free_space allocation })
		| LvRename (name,l) ->
			change_lv name (fun lv others ->
				{vg with lvs = {lv with Lv.name=l.lvmv_new_name}::others })
		| LvAddTag (name, tag) ->
			change_lv name (fun lv others ->
				let tags = lv.Lv.tags in
				let lv' = {lv with Lv.tags = if List.mem tag tags then tags else tag::tags} in
				{vg with lvs = lv'::others})
		| LvRemoveTag (name, tag) ->
			change_lv name (fun lv others ->
				let tags = lv.Lv.tags in
				let lv' = {lv with Lv.tags = List.filter (fun t -> t <> tag) tags} in
				{vg with lvs = lv'::others})


let create_lv vg name size =
  let id = Lvm_uuid.create () in
  let new_segments,new_free_space = Allocator.alloc vg.free_space size in
  do_op vg {so_seqno=vg.seqno; so_op=LvCreate (name,{lvc_id=id; lvc_segments=new_segments})}

let rename_lv vg old_name new_name =
  do_op vg {so_seqno=vg.seqno; so_op=LvRename (old_name,{lvmv_new_name=new_name})}

let resize_lv vg name new_size =
  let lv,others = List.partition (fun lv -> lv.Lv.name=name) vg.lvs in
  let op = match lv with 
    | [lv] ->
	let current_size = Lv.size_in_extents lv in
	if new_size > current_size then
	  let new_segs,_ = Allocator.alloc vg.free_space (Int64.sub new_size current_size) in
	  LvExpand (name,{lvex_segments=new_segs})
	else
	  LvReduce (name,{lvrd_new_extent_count=new_size})
    | _ -> failwith "Can't find LV"
  in
  do_op vg {so_seqno=vg.seqno; so_op=op}

let remove_lv vg name =
  do_op vg {so_seqno=vg.seqno; so_op=LvRemove name}

let add_tag_lv vg name tag =
	do_op vg {so_seqno = vg.seqno; so_op = LvAddTag (name, tag)}

let remove_tag_lv vg name tag =
	do_op vg {so_seqno = vg.seqno; so_op = LvRemoveTag (name, tag)}

(******************************************************************************)

let human_readable vg =
  let pv_strings = List.map Pv.human_readable vg.pvs in
    String.concat "\n" pv_strings


let find_lv vg lv_name =
  List.find (fun lv -> lv.Lv.name = lv_name) vg.lvs

let with_open_redo vg f =
	match vg.redo_lv with
	| Some lv_name -> 
		let lv = List.find (fun lv -> lv.Lv.name=lv_name) vg.lvs in
		let dev = (List.hd vg.pvs).Pv.dev in
		let (dev,pos) = 
			if !Constants.dummy_mode
			then (Printf.sprintf "%s/%s/redo" !Constants.dummy_base dev,0L)
			else (* get_absolute_pos_of_sector vg lv 0L *) failwith "where does the redo log go?" in  
		let fd = Unix.openfile dev [Unix.O_RDWR; Unix.O_CREAT] 0o644 in
		Pervasiveext.finally (fun () -> f (fd,pos)) (fun () -> Unix.close fd)
	| None -> failwith "vg.ml/with_open_redo: vg.redo_lv == None, but should not be."

let read_redo vg =
	with_open_redo vg (fun (fd,pos) ->
				   Redo.read fd pos (Constants.extent_size))

let write_redo vg =
  with_open_redo vg (fun (fd,pos) ->
    Redo.write fd pos (Constants.extent_size) vg.ops;
    {vg with ops=[]})
    
let reset_redo vg =
  with_open_redo vg (fun (fd,pos) ->
    Redo.reset fd pos)

let apply_redo vg  =
  let ops = List.rev (read_redo vg) in
  let rec apply vg ops =
    match ops with
      | op::ops ->
	  if op.so_seqno=vg.seqno 
	  then begin
	    debug "Applying operation op=%s" (Redo.redo_to_human_readable op);
	    apply (do_op vg op) ops
	  end else begin
	    debug "Ignoring operation op=%s" (Redo.redo_to_human_readable op);
	    apply vg ops
	  end
      | _ -> vg
  in apply vg ops

let write_full vg =
  let pvs = vg.pvs in
  let md = to_string vg in
  let vg = 
    {vg with pvs = List.map (fun pv -> 
      Label.write pv.Pv.label;
      { pv with Pv.mda_headers = 
	  List.map (fun mdah -> 
	    Metadata.write pv.Pv.real_device mdah md) pv.Pv.mda_headers}) pvs}
  in
  (match vg.redo_lv with Some _ -> reset_redo vg | None -> ());
  vg

let init_redo_log vg =
  match vg.redo_lv with 
    | Some _ -> vg 
    | None ->
	let vg = write_full (create_lv vg Constants.redo_log_lv_name 1L) in
	{vg with redo_lv=Some Constants.redo_log_lv_name}

let write vg force_full =
  if force_full 
  then write_full vg
  else 
    match vg.redo_lv with None -> write_full vg | Some _ -> write_redo vg

let of_metadata config pvdatas =
  let config = 
    match config with 
      | AStruct c -> c 
      | _ -> failwith "Bad metadata" in
  let vg = filter_structs config in
  if List.length vg <> 1 then 
    failwith "Could not find singleton volume group";
  let (name, _) = List.hd vg in
  let alist = expect_mapped_struct name vg in
  let id = Lvm_uuid.of_string (expect_mapped_string "id" alist) in
  let seqno = expect_mapped_int "seqno" alist in
  let status = map_expected_mapped_array "status" 
    (fun a -> status_of_string (expect_string "status" a)) alist in
  let extent_size = expect_mapped_int "extent_size" alist in
  let max_lv = Int64.to_int (expect_mapped_int "max_lv" alist) in
  let max_pv = Int64.to_int (expect_mapped_int "max_pv" alist) in
  let pvs = expect_mapped_struct "physical_volumes" alist in
  let pvs = List.map (fun (a,_) -> Pv.of_metadata a (expect_mapped_struct a pvs) pvdatas) pvs in
  let lvs = try expect_mapped_struct "logical_volumes" alist with _ -> [] in
  let lvs = List.map (fun (a,_) -> Lv.of_metadata a (expect_mapped_struct a lvs)) lvs in

  (* Now we need to set up the free space structure in the PVs *)
  let free_space = List.flatten (List.map (fun pv -> Allocator.create pv.Pv.name pv.Pv.pe_count) pvs) in

  let free_space = List.fold_left (fun free_space lv -> 
    let lv_allocations = Lv.allocation_of_lv lv in
    debug "Allocations for lv %s:\n%s\n" lv.Lv.name (Allocator.to_string lv_allocations);
    Allocator.alloc_specified_areas free_space lv_allocations) free_space lvs in
  
  let got_redo_lv = List.exists (fun lv -> lv.Lv.name = Constants.redo_log_lv_name) lvs in

  let vg = {
    name=name;
   id=id;
   seqno=Int64.to_int seqno;
   status=status;
   extent_size=extent_size;
   max_lv=max_lv;
   max_pv=max_pv;
   pvs=pvs;
   lvs=lvs; 
   free_space=free_space; 
   redo_lv=if got_redo_lv then Some Constants.redo_log_lv_name else None;
   ops=[]; 
  } in
  
  if got_redo_lv then apply_redo vg else vg

let create_new name devices_and_names =
	let pvs = List.map (fun (dev,name) -> Pv.create_new dev name) devices_and_names in
	debug "PVs created";
	let free_space = List.flatten (List.map (fun pv -> Allocator.create pv.Pv.name pv.Pv.pe_count) pvs) in
	let vg = 
		{ name=name;
		id=Lvm_uuid.create ();
		seqno=1;
		status=[Read; Write];
		extent_size=Constants.extent_size_in_sectors;
		max_lv=0;
		max_pv=0;
		pvs=pvs;
		lvs=[];
		free_space=free_space;
		redo_lv=None;
		ops=[];
		}
	in
	ignore (write vg true);
	debug "VG created"

let parse text pvdatas =
  let lexbuf = Lexing.from_string text in
  of_metadata (Lvmconfigparser.start Lvmconfiglex.lvmtok lexbuf) pvdatas

let load devices =
  debug "Vg.load";
  let mds_and_pvdatas = List.map Pv.find_metadata devices in
  let md = fst (List.hd mds_and_pvdatas) in
  let pvdatas = List.map snd mds_and_pvdatas in
  parse md pvdatas

let set_dummy_mode base_dir mapper_name full_provision =
  Constants.dummy_mode := true;
  Constants.dummy_base := base_dir;
  Constants.mapper_name := mapper_name;
  Constants.full_provision := full_provision




