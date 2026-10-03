# GoogleSQL Language Server (WIP)
A minimalistic language server for [GoogleSQL](https://github.com/google/googlesql). Its only target capability is to report syntax errors.

Under the hood it uses the [googlesql-ffi library](https://github.com/Oddys/googlesql-ffi) that exposes the GoogleSQL parser's functionality via C ABI.

To prepare fresh build:
```sh
rm -r .zig-cache zig-out zig-pkg src/c.zig 2>/dev/null
```

To try test script:
```sh
./client.sh | ./zig-out/bin/googlesql_lsp
```

## Coverage
To compute test coverage with kcov:
```sh
kcov --clean --include-path=src --exclude-region=KCOV_EXCL_START:KCOV_EXCL_END zig-out/coverage zig-out/bin/test
```
