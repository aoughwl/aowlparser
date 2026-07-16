proc reg(future: int, cb: int) =
  future.addCallback(
      proc() =
      cb(future)
    )
  foo(proc =
    bar(future))
