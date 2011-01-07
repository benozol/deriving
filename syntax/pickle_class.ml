(*pp camlp4of *)

(* Copyright Jeremy Yallop 2007.
   This file is free software, distributed under the MIT license.
   See the file COPYING for details.
*)

open Defs

module Description : ClassDescription = struct
  let classname = "Pickle"
  let runtimename = "Deriving_Pickle"
  let default_module = Some "Defaults"
  let allow_private = false
  let predefs = [
    ["int"], "int";
    ["bool"], "bool";
    ["unit"], "unit";
    ["char"], "char";
    (* ["int32"], "int32"; *)
    (* ["Int32";"t"], "int32"; *)
    (* ["int64"], "int64"; *)
    (* ["Int64";"t"], "int64"; *)
    (* ["nativeint"], "nativeint"; *)
    ["float"], "float";
    ["num"], "num";
    ["string"], "string";
    ["list"], "list";
    ["ref"], "ref";
    ["option"], "option";
  ]
  let depends = [Typeable_class.Typeable.depends; Eq_class.Eq.depends]
end

module InContext (L : Loc) : Class = struct

  open Base
  open Utils
  open Type
  open Camlp4.PreCast

  open Description
  open L
  module Helpers = Base.InContext(L)(Description)
  open Helpers
  open Description

  let bind, seq = 
    let bindop = ">>=" and seqop = ">>" in
      <:expr< $lid:bindop$ >>, <:expr< $lid:seqop$ >>

  let unpickle_record_bindings ctxt (tname,params,rhs,cs,_) (fields : field list) e = <:expr<
      let module Mutable = struct
        type $Ast.TyDcl (loc, "t", [], Untranslate.repr 
            (instantiate_modargs_repr ctxt 
               (Record (List.map (fun (n,p,_) -> (n,p,`Mutable)) fields))), [])$
      end in $e$ >>

  let unpickle_record ctxt (tname,_,_,_,_ as decl) fields call_expr = 
    let msg = "unexpected object encountered unpickling "^tname in
    let assignments = 
      List.fold_right
        (fun (id,_,_) exp ->
           <:expr< this.Mutable.$lid:id$ <- $lid:id$; $exp$ >>)
        fields
      <:expr< return self >> in
    let inner = 
      List.fold_right
        (fun (id,([],t),_) exp ->
           <:expr< $bind$ ($call_expr ctxt t "unpickle"$ $lid:id$)
             (fun $lid:id$ -> $exp$) >>)
        fields
        assignments in
    let idpat = patt_list (List.map (fun (id,_,_) -> <:patt< $lid:id$ >>) fields) in
      unpickle_record_bindings ctxt decl fields
        (<:expr< R.record
           (fun self -> function
                  | $idpat$ -> let this = (Obj.magic self : Mutable.t) in $inner$
                  | _ -> raise ($uid:runtimename$.UnpicklingError $str:msg$)) $`int:List.length fields$ >>)

  let pickle_record ctxt decl fields call_expr =
    let inner =
      List.fold_right 
        (fun (id,([],t),_) e ->
           <:expr< $bind$ ($call_expr ctxt t "pickle"$ $lid:id$) 
                          (fun $lid:id$ -> $e$) >>)
        fields
        <:expr< (W.store_repr this
                   ($uid:runtimename$.Repr.make
                      $expr_list (List.map (fun (id,_,_) -> <:expr< $lid:id$ >>) fields)$)) >>
    in
      [ <:match_case< ($record_pattern fields$ as obj) ->
                       W.allocate obj (fun this -> $inner$) >> ]


  let rebind_params ctxt name : Ast.str_item = 
    NameMap.fold
      (fun _ param s -> <:str_item< $s$ module $uid:param$ = $uid:param$.$uid:name$ >>)
      ctxt.argmap
      <:str_item< >>

  let wrap ctxt ~picklers ~unpickler =
    let unpickler = <:expr< let module R = Utils(Typeable) in $unpickler$ >> in
    let pickle = <:expr<
      let module W = Utils(Typeable)(Eq) in
      let rec pickle = function $list:picklers$ in pickle >> in
    [ <:str_item< open $uid:runtimename$.Write >>;
      <:str_item< let pickle = $pickle$ >>;
      <:str_item< open $uid:runtimename$.Read >>;
      <:str_item< let unpickle = $unpickler$ >> ]

    let instance = object (self)
    inherit make_module_expr

    method tuple ctxt ts = 
      let nts = List.length ts in
      let ids = (List.mapn (fun t n -> (Printf.sprintf "id%d" n, t)) ts) in
      let eidlist = expr_list (List.map (fun (id,_) -> <:expr< $lid:id$ >>) ids) in
      let pidlist = patt_list (List.map (fun (id,_) -> <:patt< $lid:id$ >>) ids) in
      let _, tpatt,texpr = tuple ~param:"id" nts in
      let picklers =
        let inner = 
          List.fold_right
            (fun (id,t) expr -> 
               <:expr< $bind$ ($self#call_expr ctxt t "pickle"$ $lid:id$) 
                            (fun $lid:id$ -> $expr$) >>)
            ids
            <:expr< W.store_repr this ($uid:runtimename$.Repr.make $eidlist$) >> in
          [ <:match_case< ($tpatt$ as obj) -> 
                  W.allocate obj (fun this -> $inner$) >>]

      and unpickler = 
        let msg = "unexpected object encountered unpickling "^string_of_int nts^"-tuple" in
        let inner = 
          List.fold_right 
            (fun (id,t) expr ->
               <:expr< $bind$ ($self#call_expr ctxt t "unpickle"$ $lid:id$) (fun $lid:id$ -> $expr$) >>)
            ids
            <:expr< return $texpr$ >> in
          <:expr< R.tuple
            (function
               | $pidlist$ -> $inner$
               | _ -> raise ($uid:runtimename$.UnpicklingError $str:msg$)) >> in
        wrap ctxt ~picklers ~unpickler

    method polycase ctxt tagspec : Ast.match_case = match tagspec with
    | Tag (name, None) -> <:match_case<
        (`$name$ as obj) ->
          W.allocate obj
              (fun thisid -> 
                 W.store_repr thisid
                    ($uid:runtimename$.Repr.make ~constructor:$`int:(tag_hash name)$ [])) >>
    | Tag (name, Some t) -> <:match_case< 
        (`$name$ v1 as obj) ->
           W.allocate obj
            (fun thisid ->
             $bind$ ($self#call_expr ctxt t "pickle"$ v1)
                    (fun mid -> 
                    (W.store_repr thisid
                        ($uid:runtimename$.Repr.make ~constructor:$`int:(tag_hash name)$ [mid])))) >>
    | Extends t -> 
        let patt, guard, cast = cast_pattern ctxt t in <:match_case<
         ($patt$ as obj) when $guard$ ->
            ($self#call_expr ctxt t "pickle"$ $cast$) >>

    method polycase_un ctxt tagspec : Ast.match_case = match tagspec with
    | (name, None)   -> <:match_case< $`int:(tag_hash name)$, [] -> return `$name$ >>
    | (name, Some t) -> <:match_case< $`int:(tag_hash name)$, [x] -> 
      $bind$ ($self#call_expr ctxt t "unpickle"$ x) (fun o -> return (`$name$ o)) >>

    method extension ctxt tname ts : Ast.match_case =
      (* Try each extension in turn.  If we get an UnknownTag failure,
         try the next one.  This is

         * safe because any two extensions that define the same tag
           must be compatible at that point

         * fast because we can tell on the first integer comparison
           whether we've picked the right path or not.
      *)
      let inner = List.fold_right 
        (fun t exp -> <:expr<
           let module M = $(self#expr ctxt t)$ in
             try $exp$
             with $uid:runtimename$.UnknownTag (n,_) -> (M.unpickle id :> a $uid:runtimename$.Read.m) >>)
        ts
        <:expr< raise ($uid:runtimename$.UnknownTag (n, ($str:"Unexpected tag encountered during unpickling of "
                                       ^tname$))) >>
    in <:match_case< n,_ -> $inner$ >>

    method variant ctxt (tname,_,_,_,_ as decl) (_, tags) = 
      let unpickler = 
        let tags, extensions = either_partition
          (function Tag (name,t) -> Left (name,t) | Extends t -> Right t) tags in
        let tag_cases = List.map (self#polycase_un ctxt) tags in
        let extension_case = self#extension ctxt tname extensions in
          <:expr< fun id -> R.sum (function $list:tag_cases @ [extension_case]$) id >>
      in
        wrap ctxt ~picklers:(List.map (self#polycase ctxt) tags) ~unpickler

    method case ctors ctxt (name, params') n : Ast.match_case * Ast.match_case = 
    let nparams = List.length params' in
    let ids = List.map (fun n ->  <:expr< $lid:Printf.sprintf "id%d" n$ >>) (List.range 0 nparams) in
    let exp = 
      List.fold_right2
        (fun p n tail -> 
           <:expr< $bind$ ($self#call_expr ctxt p "pickle"$ $lid:Printf.sprintf "v%d" n$)
                          (fun $lid:Printf.sprintf "id%d" n$ -> $tail$)>>)
        params'
        (List.range 0 nparams)
        <:expr< W.store_repr thisid ($uid:runtimename$.Repr.make ~constructor:$`int:n$ $expr_list ids$) >> in
      match params' with
        | [] -> <:match_case< $uid:name$ as obj -> 
                              W.allocate obj (fun thisid -> $exp$) >>,
                <:match_case< $`int:n$, [] -> return $uid:name$ >>
        | _  -> let _, tpatt, _ = tuple ~param:"v" nparams in
	        <:match_case< $uid:name$ $tpatt$ as obj -> 
                              W.allocate obj (fun thisid -> $exp$) >>,
    let _, _, tuple = tuple ~param:"id" nparams in
    let patt, exp = 
      List.fold_right2 
        (fun n t (pat, exp) ->
           let m = Printf.sprintf "M%d" n and id = Printf.sprintf "id%d" n in
           <:patt< $lid:id$ :: $pat$ >>,
           <:expr< let module $uid:m$ = $self#expr ctxt t$
                    in $bind$ ($uid:m$.unpickle $lid:id$) (fun $lid:id$ -> $exp$) >>)
        (List.range 0 nparams)
        params'
      (<:patt< [] >>, <:expr< return ($uid:name$ $tuple$) >>) in
      <:match_case< $`int:n$, $patt$ -> $exp$ >>

  method sum ?eq ctxt (tname,_,_,_,_ as decl) summands =
    let nctors = List.length summands in
    let picklers, unpicklers = List.split (List.mapn (self#case nctors ctxt) summands) in
    wrap ctxt
      ~picklers
      ~unpickler:<:expr< fun id -> 
        let f = function $list:unpicklers$ 
                 | n,_ -> raise ($uid:runtimename$.UnpicklingError ($str:"Unexpected tag when unpickling "
                                                  ^tname^": "$^ string_of_int n))
        in R.sum f id >>

  method record ?eq ctxt (tname,_,_,_,_ as decl) (fields : Type.field list) = 
      wrap ctxt
        ~picklers:(pickle_record ctxt decl fields self#call_expr)
        ~unpickler:(unpickle_record ctxt decl fields self#call_expr)
  end

  let make_module_expr = instance#rhs
  let generate = default_generate ~make_module_expr ~make_module_type
  let generate_sigs = default_generate_sigs ~make_module_sig
  let generate_expr = instance#expr

end

module Pickle = Base.Register(Description)(InContext)
