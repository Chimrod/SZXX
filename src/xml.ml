open! Core_kernel
open Angstrom

let escape_table = function
| "amp" -> "&"
| "lt" -> "<"
| "gt" -> ">"
| "apos" -> "'"
| "quot" -> "\""
| s -> (
  match String.chop_prefix ~prefix:"#" s with
  | None -> sprintf "&%s;" s
  | Some num -> (
    try Int.of_string num |> Char.of_int_exn |> Char.to_string with
    | _ -> sprintf "&%s;" s
  )
)

let unescape s =
  let buf = Buffer.create (String.length s) in
  let _ =
    String.fold s ~init:(false, []) ~f:(fun (escaping, ll) c ->
        match c, escaping with
        | '&', false -> true, ll
        | ';', true ->
          let code = String.of_char_list ll |> String.rev |> escape_table in
          Buffer.add_string buf code;
          false, []
        | c, true -> true, c :: ll
        | c, false ->
          Buffer.add_char buf c;
          false, ll)
  in
  if Buffer.length buf = String.length s then s else Buffer.contents buf

let escapable_string_parser ~separator =
  char separator
  *>
  let is_separator = Char.( = ) separator in
  let buf = Buffer.create 20 in
  let rec loop escaping ll =
    any_char >>= fun x ->
    match x, escaping with
    | '&', false -> (loop [@tailcall]) true ll
    | ';', true ->
      let code = String.of_char_list ll |> String.rev |> escape_table in
      Buffer.add_string buf code;
      (loop [@tailcall]) false []
    | c, _ when is_separator c ->
      List.fold_right ll ~init:() ~f:(fun c () -> Buffer.add_char buf c);
      let result = Buffer.contents buf in
      Buffer.clear buf;
      return result
    | c, true -> (loop [@tailcall]) true (c :: ll)
    | c, false ->
      Buffer.add_char buf c;
      (loop [@tailcall]) false ll
  in
  loop false []

let is_token = function
| '"'
 |'\''
 |'='
 |'<'
 |'?'
 |'/'
 |'>'
 |'['
 |']'
 |'\x20'
 |'\x0d'
 |'\x09'
 |'\x0a' ->
  false
| _ -> true

let is_text = function
| '<' -> false
| _ -> true

let is_ws = function
| '\x20'
 |'\x0d'
 |'\x09'
 |'\x0a' ->
  true
| _ -> false

let maybe p = option None (p >>| Option.return)

let drop p = p *> return ()

let double x y = x, y

let skip_until_string terminate =
  let first = terminate.[0] in
  let len = String.length terminate in
  let rec loop () =
    skip_while (Char.( <> ) first) >>= fun () ->
    peek_string len >>= function
    | x when String.(x = terminate) -> string terminate
    | _ -> (loop [@tailcall]) ()
  in
  loop ()

let ws = skip_while is_ws

let comment = string "<!--" *> skip_until_string "-->"

let blank = drop (sep_by comment ws)

type attr_list = (string * string) list [@@deriving sexp_of]

type element = {
  tag: string;
  attrs: attr_list;
  text: string;
  children: element array;
}
[@@deriving sexp_of]

type content =
  | Text    of string
  | Element of element
  | Skip

type doc = {
  decl_attrs: attr_list option;
  top: element;
}
[@@deriving sexp_of]

let dot tag node = Array.find node.children ~f:(fun x -> String.(x.tag = tag))

let at i node = Option.try_with (fun () -> Int.of_string i |> Array.get node.children)

let get node (steps : (element -> element option) list) =
  let rec loop node = function
    | [] -> node
    | step :: rest -> (loop [@tailcall]) (Option.bind node ~f:step) rest
  in
  loop (Some node) steps

let get_attr { attrs; _ } name = List.find_map attrs ~f:(fun (x, y) -> Option.some_if String.(x = name) y)

let parser =
  let xml_string =
    let dq_string = escapable_string_parser ~separator:'"' in
    let sq_string = escapable_string_parser ~separator:'\'' in
    dq_string <|> sq_string
  in
  let token = take_while1 is_token in
  let attr = lift2 double (token <* ws <* char '=') (ws *> xml_string) in
  let decl_parser = string "<?xml " *> many (blank *> attr) <* blank <* string "?>" in
  let doctype_parser =
    let entity =
      string "[<!ENTITY" *> ws *> skip_many (ws *> choice [ token; xml_string ]) <* ws <* string ">]"
    in
    string "<!DOCTYPE" *> ws *> skip_many (ws *> choice [ drop token; drop xml_string; entity ])
    <* ws
    <* char '>'
  in
  let cdata =
    string "<![CDATA["
    *>
    let buf = Buffer.create 20 in
    let rec loop n ll =
      any_char >>= fun c ->
      match c, n with
      | ']', 0 -> (loop [@tailcall]) 1 (']' :: ll)
      | ']', 1 -> (loop [@tailcall]) 2 (']' :: ll)
      | '>', 2 ->
        let result = Buffer.contents buf in
        Buffer.clear buf;
        return result
      | c, 0 ->
        Buffer.add_char buf c;
        (loop [@tailcall]) 0 ll
      | c, _ ->
        List.fold_right (c :: ll) ~init:() ~f:(fun x () -> Buffer.add_char buf x);
        (loop [@tailcall]) 0 []
    in
    loop 0 []
  in
  let element_parser ?filter_map parent_path =
    let box = ref parent_path in
    fix (fun element_parser ->
        lift2 double (char '<' *> ws *> token) (many (ws *> attr) <* ws) >>= fun (tag, attrs) ->
        let path, matching =
          match !box with
          | head :: ([] as tail) when String.(head = tag) -> tail, true
          | head :: tail when String.(head = tag) -> tail, false
          | _ -> [], false
        in
        let buf = Buffer.create 16 in
        let queue = Queue.create ~capacity:1 () in
        let preserve_space =
          lazy
            (List.mem attrs ("xml:space", "preserve")
               ~equal:String.((fun (x1, y1) (x2, y2) -> x1 = x2 && y1 = y2)))
        in
        let restore = !box in
        let nested_choice =
          choice
            [
              (take_while1 is_text >>| fun x -> Text x);
              cdata >>| (fun x -> Text x) <* blank;
              (commit >>| fun () -> box := path) *> element_parser <* blank;
            ]
          >>| function
          | Skip -> ()
          | Text s ->
            if Buffer.length buf > 0 then Buffer.add_char buf ' ';
            Buffer.add_string buf (if force preserve_space then s else String.strip s)
          | Element el -> Queue.enqueue queue el
        in
        let nested =
          let right = lift4 (fun _ _ _ _ -> ()) ws (string tag) ws (char '>') in
          lift4 (fun _ _ _ _ -> box := restore) (char '>') (skip_many nested_choice) (string "</") right
        in
        choice
          [
            (* Self-terminating *)
            (string "/>" >>| fun _ -> Element { tag; attrs; text = ""; children = [||] });
            (* Nested *)
            ( nested *> commit >>| fun () ->
              let el = { tag; attrs; text = Buffer.contents buf; children = Queue.to_array queue } in
              Buffer.reset buf;
              Queue.clear queue;
              match matching, filter_map with
              | true, Some f -> (
                match f el with
                | Some mapped -> Element mapped
                | None -> Skip
              )
              | _ -> Element el );
          ])
  in
  fun ?filter_map path ->
    lift2
      (fun decl_attrs content ->
        let top =
          match
            List.find_map content ~f:(function
              | Element x -> Some x
              | _ -> None)
          with
          | Some x -> x
          | None -> failwithf "XML document must have a top level element" ()
        in
        { decl_attrs; top })
      (blank *> maybe decl_parser)
      (blank *> maybe doctype_parser *> blank *> sep_by blank (element_parser ?filter_map path) <* blank)
