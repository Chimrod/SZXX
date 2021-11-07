let flags = Unix.[ O_RDONLY; O_NONBLOCK ]

open! Core_kernel
open Lwt.Infix

let extractors =
  SZXX.Xlsx.
    {
      string = (fun _location s -> `String (SZXX.Xml.unescape s));
      error = (fun _location s -> `String (sprintf "#ERROR# %s" s));
      boolean = (fun _location s -> `Bool String.(s = "1"));
      number = (fun _location s -> `Float (Float.of_string s));
      null = `Null;
    }

let feed_string ic =
  SZXX.Zip.String
    (fun () ->
      Lwt_io.read ~count:4096 ic >|= function
      | "" -> None
      | chunk -> Some chunk)

let feed_bigstring ic =
  let open SZXX.Zip in
  let len = Lwt_io.buffer_size ic in
  let buf = Bigstring.create len in
  Bigstring
    (fun () ->
      Lwt_io.read_into_bigstring ic buf 0 len >|= function
      | 0 -> None
      | len -> Some { buf; pos = 0; len })

let readme_example1 filename () =
  let xlsx_path = sprintf "../../../test/files/%s.xlsx" filename in
  Lwt_io.with_file ~flags ~mode:Input xlsx_path (fun ic ->
      let open SZXX.Xlsx in
      let open Lwt.Syntax in
      (* yojson_cell_parser is an easy way to quickly inspect a file by mapping XLSX's data types to JSON *)
      let stream, success = stream_rows_buffer ~feed:(feed_string ic) yojson_cell_parser in
      let processed =
        Lwt_stream.iter
          (fun row -> `List (Array.to_list row.data) |> Yojson.Basic.pretty_to_string |> print_endline)
          stream
      in
      let* () = success in
      (* bind to/await the `success` promise to catch any error that may have terminated the stream early *)
      let* () = processed in
      (* ... *)
      Lwt.return_unit)

let readme_example2 filename () =
  let xlsx_path = sprintf "../../../test/files/%s.xlsx" filename in
  Lwt_io.with_file ~flags ~mode:Input xlsx_path (fun ic ->
      let open SZXX.Xlsx in
      let open Lwt.Syntax in
      let stream, sst_p, success = stream_rows ~feed:(feed_string ic) yojson_cell_parser in
      let filtered =
        Lwt_stream.filter
          (fun row ->
            match row.data.(3), row.row_number with
            | _, i when i > 1000 -> false
            | Available (`Bool x), _ -> x
            | Available _, _
             |Delayed _, _ ->
              false)
          stream
      in
      let count =
        Lwt_stream.fold_s
          (fun row acc ->
            let+ sst = sst_p in
            let _fully_available_row = unwrap_status yojson_cell_parser sst row in
            (* do something with [fully_available_row] *)
            acc + 1)
          filtered 0
      in
      let* () = success in
      let* _count = count in
      Lwt.return_unit)

let xlsx filename () =
  let xlsx_path = sprintf "../../../test/files/%s.xlsx" filename in
  let json_path = sprintf "../../../test/files/%s.json" filename in
  let%lwt against =
    Lwt_io.with_file ~flags ~mode:Input json_path (fun ic ->
        let%lwt contents = Lwt_io.read ic in
        Lwt.return (Yojson.Safe.from_string contents))
  in
  let%lwt parsed =
    Lwt_io.with_file ~flags ~mode:Input xlsx_path (fun ic ->
        let open SZXX.Xlsx in
        let stream, processed = stream_rows_buffer ~feed:(feed_bigstring ic) extractors in
        let json_p = Lwt_stream.fold (fun row acc -> `List (Array.to_list row.data) :: acc) stream [] in
        let%lwt () = processed in
        let%lwt json = json_p in
        Lwt.return (`Assoc [ "data", `List (List.rev json) ]))
  in

  (* let%lwt () =
       Lwt_io.with_file ~flags:[ O_WRONLY; O_NONBLOCK; O_TRUNC ] ~mode:Output json_path (fun oc ->
           Lwt_io.write oc (Yojson.Safe.to_string parsed))
     in *)
  Json_diff.check (parsed : Yojson.Basic.t :> Yojson.Safe.t) against;

  Lwt.return_unit

let stream_rows filename () =
  let xlsx_path = sprintf "../../../test/files/%s.xlsx" filename in
  let json_path = "../../../test/files/streamed.json" in
  let%lwt against =
    Lwt_io.with_file ~flags ~mode:Input json_path (fun ic ->
        let%lwt contents = Lwt_io.read ic in
        Lwt.return (Yojson.Safe.from_string contents))
  in
  let%lwt parsed =
    Lwt_io.with_file ~flags ~mode:Input xlsx_path (fun ic ->
        let open SZXX.Xlsx in
        let stream, sst, processed = stream_rows ~feed:(feed_bigstring ic) yojson_cell_parser in
        let%lwt sst = sst in
        let json_list_p =
          Lwt_stream.map
            (fun status ->
              let row = unwrap_status yojson_cell_parser sst status in
              `List (Array.to_list row.data))
            stream
          |> Lwt_stream.to_list
        in
        let%lwt () = processed in
        let%lwt json_list = json_list_p in
        Lwt.return (`Assoc [ "data", `List json_list ]))
  in
  (* let%lwt () =
       Lwt_io.with_file ~flags:[ O_WRONLY; O_NONBLOCK; O_TRUNC ] ~mode:Output json_path (fun oc ->
           Lwt_io.write oc (Yojson.Safe.to_string parsed))
     in *)
  Json_diff.check parsed against;
  Lwt.return_unit

let () =
  Lwt_main.run
  @@ Alcotest_lwt.run "SZXX XLSX"
       [
         ( "XLSX",
           [
             "simple.xlsx", `Quick, xlsx "simple";
             "financial.xlsx", `Quick, xlsx "financial";
             "zip64.xlsx", `Quick, xlsx "zip64";
             "Readme example 1", `Quick, readme_example1 "financial";
             "Readme example 2", `Quick, readme_example2 "financial";
             "Unbuffed stream", `Quick, stream_rows "financial";
           ] );
       ]
