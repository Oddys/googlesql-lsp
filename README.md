# GoogleSQL Language Server (WIP)
A minimalistic language server for [GoogleSQL](https://github.com/google/googlesql). Its only target capability is to report syntax errors.

Under the hood it uses the [googlesql-ffi library](https://github.com/Oddys/googlesql-ffi) that exposes the GoogleSQL parser's functionality via C ABI:
- The build artifact of googlesql-ffi - libgooglesql_parser.a - must be placed into lib/ directory here.
- [googlesql_parser.h](include/googlesql_parser.h) is a copy of googlesql-ffi's [googlesql_parser.h](https://github.com/Oddys/googlesql-ffi/blob/ffi/googlesql/ffi/googlesql_parser.h)
