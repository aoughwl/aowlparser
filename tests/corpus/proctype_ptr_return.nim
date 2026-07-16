type JitCallback* = proc (a: pointer): ptr JitStack {.cdecl.}
