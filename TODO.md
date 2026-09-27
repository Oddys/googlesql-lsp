Functionality:
- [x] Add sending diagnostics (didOpen, didChange, didClose)
- [ ] Enable parsers
- [ ] Add debouncing / move parsing off the request thread. At that point, store the version next to the text in files.
- [ ] Implement handling of partial updates
- [ ] Add other MacOS and Linux build targets
- [ ] Optimize build for Prod

Chores:
- [ ] Unify function parameter names in Handler
- [ ] Unify imports (use aliasing for structs in lsp.types)
- [ ] Add kcov to build.zig
