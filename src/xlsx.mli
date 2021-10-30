open! Core_kernel

type location = {
  sheet_number: int;
  row_number: int;
  col_index: int;
}
[@@deriving sexp_of]

type 'a cell_parser = {
  string: location -> string -> 'a;
  error: location -> string -> 'a;
  boolean: location -> string -> 'a;
  number: location -> string -> 'a;
  null: 'a;
}

type delayed_string = {
  location: location;
  sst_index: string;
}
[@@deriving sexp_of]

type 'a status =
  | Available of 'a
  | Delayed   of delayed_string
[@@deriving sexp_of]

type 'a row = {
  sheet_number: int;
  row_number: int;
  data: 'a array;
}
[@@deriving sexp_of]

type sst

(**
   Stream rows from an [Lwt_io.input_channel].
   SZXX does not hold onto memory any longer than it needs to.
   Most XLSX files can be streamed without buffering.
   However, some documents that make use of the Shared Strings Table (SST) will place it at the end of the Zip archive,
   forcing SZXX to buffer those rows until the SST is found in the archive.
   Using inline strings and/or placing the SST before the worksheets allows SZXX as efficiently as possible.

   [SZXX.Xlsx.stream_rows ?only_sheet readers ic]

   [only_sheet]: when present, only stream rows from this sheet, numbered from 1.

   [readers]: the parsers to convert from [string] into the type used in your application.
   [SZXX.Xlsx.yojson_readers] is provided for convenience.

   Note: you must pass your own readers if you need XML escaping, call [SZXX.Xml.unescape].

   Note: XLSX dates are encoded as numbers, call [SZXX.Xlsx.parse_date] or [SZXX.Xlsx.parse_datetime] in your readers to convert them.

   [ic]: The channel to read from

   Returned: [stream * sst promise * unit promise]

   [stream]: Lwt_stream.t of rows where the cell data is either [Available v] where [v] is of the type returned by your readers,
   or [Delayed d]. [Delayed] cells are caused by that cell's reliance on the SST.

   [sst promise]: A promise resolved once the SST is available.

   [unit promise]: A promise resolved once all the rows have been written to the stream.
   It is important to bind to/await this promise in order to capture any errors encountered while processing the file.
*)
val stream_rows :
  ?only_sheet:int ->
  feed:Zip.feed ->
  'a cell_parser ->
  'a status row Lwt_stream.t * sst Lwt.t * unit Lwt.t

val stream_rows_buffer :
  ?only_sheet:int -> feed:Zip.feed -> 'a cell_parser -> 'a row Lwt_stream.t * unit Lwt.t

val stream_rows_unparsed :
  ?only_sheet:int -> feed:Zip.feed -> unit -> Xml.DOM.element row Lwt_stream.t * sst Lwt.t * unit Lwt.t

(** Convenience cell_parser to read rows as JSON *)
val yojson_cell_parser : [> `Bool   of bool | `Float  of float | `String of string | `Null ] cell_parser

(** Convert an XML element returned by [stream_rows_unparsed] into a nicer [Xlsx.row] *)
val parse_row : ?sst:sst -> 'a cell_parser -> Xml.DOM.element row -> 'a status row

(** XLSX dates are stored as floats. Converts from a [float] to a [Date.t] *)
val parse_date : float -> Date.t

(** XLSX datetimes are stored as floats. Converts from a [float] to a [Time.t] *)
val parse_datetime : zone:Time.Zone.t -> float -> Time.t

(** Converts from a cell ref such as [D7] or [AA2] to a 0-based column index *)
val column_to_index : string -> int

(**
   Unwraps a single row, resolving all SST references.

   A common workflow is to call [Lwt_stream.filter] on the stream returned by [stream_rows],
   discarding uninteresting rows in order to buffer as few rows as possible,
   then await the [sst Lwt.t], and finally consume the stream, calling [unwrap_status] on each row to get the String data.
*)
val unwrap_status : 'a cell_parser -> sst -> 'a status row -> 'a row

(**
   Resolve a single reference into the Shared Strings Table.
*)
val resolve_sst_index : sst -> sst_index:string -> string option
