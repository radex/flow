(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

(* Entry point to the experimental Hack based bytecode emitter. Contains
 * code for emitting "top level" constructs like classes andfunctions. *)

open Nast
open Utils

open Emitter_core

let emit_func_body_code env body =
  let acts = { empty_nonlocal_actions
               with return_action = Emitter_stmt.default_return_action } in
  let env, terminal =
    with_actions env acts Emitter_stmt.emit_block body.fnb_nast in
  let env = if terminal then env else
            Emitter_stmt.default_return_action
              ~has_value:false ~is_initial:true env in
  env, ()

let emit_func_body env body =
  let env, output, () = collect_output env emit_func_body_code body in
  (* output an iterator count *)
  let env = match env.num_iterators with 0 -> env
    | n -> emit_strs env [".numiters"; string_of_int n; ";"] in
  emit_str_raw env output

let emit_param p =
  assert (not p.param_is_reference); (* actually right *)
  assert (not p.param_is_variadic && p.param_expr = None);
  get_lid_name p.param_id

let fmt_params params =
  let param_names = List.map emit_param params in
  "(" ^ String.concat ", " param_names ^ ")"

let fmt_visibility vis =
  match vis with
  | Public -> "public"
  | Private -> "private"
  | Protected  -> "protected"


let emit_fun nenv x =
  let f = Naming_heap.FunHeap.find_unsafe x in
  let nb = Naming.func_body nenv f in

  assert (f.f_user_attributes = [] &&
          f.f_variadic = FVnonVariadic && f.f_fun_kind = Ast.FSync);

  let env = new_env () in

  let options = ["mayusevv"] in
  let env = emit_enter env ".function" options (strip_ns x)
                       (fmt_params f.f_params) in
  let env = emit_func_body env nb in
  let env = run_cleanups env in
  let env = emit_exit env in

  get_output env

(* XXX: *lots* of duplication from emit_fun *)
let emit_method_ env m name =
  let env = start_new_function env in
  let nb = assert_named_body m.m_body in

  assert (m.m_user_attributes = [] &&
          m.m_variadic = FVnonVariadic && m.m_fun_kind = Ast.FSync);

  let options = bool_option "abstract" m.m_abstract @
                bool_option "final" m.m_final @
                [fmt_visibility m.m_visibility; "mayusevv"] in
  let env = emit_enter env ".method" options name
                       (fmt_params m.m_params) in
  let env = emit_func_body env nb in
  let env = run_cleanups env in
  let env = emit_exit env in
  env
let emit_method env m = emit_method_ env m (snd m.m_name)
let emit_default_ctor env name abstract =
  let options = bool_option "abstract" abstract @ ["public"; "mayusevv"] in
  let env = emit_enter env ".method" options name (fmt_params []) in
  let env = emit_Null env in
  let env = emit_RetC env in
  let env = emit_exit env in
  env

(* extends lists and things are hints,
 * but I *think* it needs to be an apply? *)
let fmt_class_hint = function
  | _, Happly ((_, cls), _) -> strip_ns cls
  | _ -> bug "class hint not apply??"; assert false
let fmt_implements_list classes =
  match classes with
  | [] -> ""
  | xs -> " implements (" ^ String.concat " " (List.map fmt_class_hint xs) ^")"
let fmt_extends_list classes =
  match classes with
  | [] -> ""
  | [x] -> " extends " ^ fmt_class_hint x
  | _ -> bug "nonempty extends list"; assert false

let emit_use env use =
  emit_strs env [".use"; fmt_class_hint use ^ ";"]

let emit_pinit env = function
  | [] -> env
  | vars ->
    let options = ["public"; "private"; "mayusevv"] in
    let env = emit_enter env ".method" options "86pinit" (fmt_params []) in

    let fmt_var_init env (name, expr) =
      let env, skip_label = fresh_label env in
      let env = emit_CheckProp env name in
      let env = emit_cjmp env true skip_label in
      let env = Emitter_expr.emit_expr env expr in
      let env = emit_InitProp env name "NonStatic" in
      emit_label env skip_label
    in
    let env = List.fold_left fmt_var_init env vars in

    let env = emit_Null env in
    let env = emit_RetC env in
    let env = emit_exit env in
    env

(* Returns None if the case has been handled, and Some (name, expr) if
 * it still needs to be taken care of in a pinit *)
let emit_var env var =
  assert (var.cv_final = false); (* props can't be final *)
  assert (var.cv_is_xhp = false);
  let options = fmt_options [fmt_visibility var.cv_visibility] in
  let fmt_prop v =
    emit_strs env [".property"; options; snd var.cv_id; "="; v^";"] in
  match var.cv_expr with
  | None -> fmt_prop "\"\"\"N;\"\"\"", None
  | Some expr ->
    match Emitter_lit.fmt_lit expr with
    | Some lit -> fmt_prop lit, None
    | None -> fmt_prop "uninit", Some (snd var.cv_id, expr)

let class_kind_options  = function
  | Ast.Cabstract -> ["abstract"]
  | Ast.Cnormal -> []
  | Ast.Cinterface -> ["interface"]
  | Ast.Ctrait -> ["final"; "trait"]
  | Ast.Cenum -> unimpl "enum not supported"; assert false

let emit_class nenv x =
  let cls = Naming_heap.ClassHeap.find_unsafe x in
  let cls = Naming.class_meth_bodies nenv cls in
  let env = new_env () in

  (* we only handle a very limited range of things right now *)
  assert (cls.c_is_xhp = false &&
          cls.c_xhp_attr_uses = [] &&
          cls.c_consts = [] &&
          cls.c_typeconsts = [] &&
          cls.c_static_vars = [] &&
          cls.c_static_methods = [] &&
          cls.c_user_attributes = [] &&
          cls.c_enum = None);

  let options = bool_option "final" cls.c_final @
                class_kind_options cls.c_kind in

  (* The "extends" list of an interface is "implements" to hhvm *)
  let implements, extends = match cls.c_kind with
    | Ast.Cinterface -> cls.c_extends, []
    | Ast.Cabstract | Ast.Cnormal | Ast.Ctrait | Ast.Cenum ->
      cls.c_implements, cls.c_extends in

  let extends_list = fmt_extends_list extends in
  let implements_list = fmt_implements_list implements in

  let env = emit_enter env ".class" options (strip_ns x)
                       (extends_list^implements_list) in


  let env = List.fold_left emit_use env cls.c_uses in
  let env, uninit_vars = lmap emit_var env cls.c_vars in
  let uninit_vars = Core_list.filter_map uninit_vars ~f:(fun x->x) in
  let env = List.fold_left emit_method env cls.c_methods in

  (* Now for 86* stuff *)
  let env = match cls.c_constructor with
            | None -> emit_default_ctor env "86ctor"
                                        (cls.c_kind = Ast.Cinterface)
            | Some m -> emit_method_ env m "86ctor" in

  let env = emit_pinit env uninit_vars in

  let env = emit_exit env in

  get_output env


(* Bogusly emit a call to a hardcoded test function *)
let emit_test_call env =
  let env = emit_FPushFuncD env 0 "test" in
  let env = emit_FCall env 0 in
  emit_PopR env

let emit_main classes =
  let env = new_env () in
  let env = emit_enter env ".main" [] "" "" in

  (* emit def classes *)
  let env =
    Core_list.foldi ~f:(fun i env _ -> emit_DefCls env i) ~init:env classes in

  (* emit debugging test *)
  let env = emit_test_call env in

  (* emit the expected return *)
  let env = emit_Int env "1" in
  let env = emit_RetC env in

  let env = emit_exit env in
  Printf.printf "%s\n\n" (get_output env)

let emit_file nenv {FileInfo.file_mode; funs; classes; _} () =
  if file_mode <> Some FileInfo.Mstrict then () else
  let fun_code = List.map (fun (_, x) -> emit_fun nenv x) funs in
  let class_code = List.map (fun (_, x) -> emit_class nenv x) classes in

  emit_main classes;
  List.iter (Printf.printf "%s\n\n") fun_code;
  List.iter (Printf.printf "%s\n\n") class_code
