(*pp camlp4of *)

(* Copyright Jeremy Yallop 2007.
   This file is free software, distributed under the MIT license.
   See the file COPYING for details.
*)

module InContext (L : Base.Loc) =
struct
  open Base
  open Utils
  open Type
  open Camlp4.PreCast
  include Base.InContext(L)

  let classname = "Bounded"

  let instance = object (self)
    inherit make_module_expr ~classname ~allow_private:false

    method tuple ctxt ts = 
    let minBounds, maxBounds = 
      List.split (List.map
                    (fun t -> let e = self#expr ctxt t in 
                       <:expr< let module M = $e$ in M.min_bound >>,
                       <:expr< let module M = $e$ in M.max_bound >>) ts) in
    <:module_expr< struct type a = $atype_expr ctxt (`Tuple ts)$
                          let min_bound = $tuple_expr minBounds$ 
                          let max_bound = $tuple_expr maxBounds$ end >>

    method sum ?eq ctxt ((tname,_,_,_,_) as decl) summands = 
    let names = ListLabels.map summands
        ~f:(function
              | (name,[]) -> name
              | (name,_) -> raise (Underivable ("Bounded cannot be derived for the type "^
                                                  tname ^" because the constructor "^
                                                  name^" is not nullary"))) in
        <:module_expr< struct type a = $atype ctxt decl$
                       let min_bound = $uid:List.hd names$ 
                       and max_bound = $uid:List.last names$ end >>

    method variant ctxt decl (_, tags) = 
    let names = ListLabels.map tags
        ~f:(function
              | Tag (name, None) -> name
             | Tag (name, _) -> raise (Underivable ("Bounded cannot be derived because the tag "^
                                                      name^" is not nullary"))
             | _ -> raise (Underivable ("Bounded cannot be derived for this "
                                        ^"polymorphic variant type"))) in
      <:module_expr< struct type a = $atype ctxt decl$
                     let min_bound = `$List.hd names$ 
                     and max_bound = `$List.last names$ end >>

  (* should perhaps implement this one *)
  method record ?eq _ (tname,_,_,_,_) = raise (Underivable ("Bounded cannot be derived for record types (i.e. "^
                                                     tname^")"))
  end
end

let _ = Base.register "Bounded" 
  ((fun (loc, context, decls) -> 
     let module M = InContext(struct let loc = loc end) in
       M.generate ~context ~decls ~make_module_expr:M.instance#rhs ~classname:M.classname ()),
   (fun (loc, context, decls) -> 
      let module M = InContext(struct let loc = loc end) in
        M.gen_sigs ~context ~decls ~classname:M.classname))
