let flag =
  x.substructureKind in {A, B} or
  (x.kind == DotToken and (block:
    var probe = x; inc probe
    probe.substructureKind == ParamsU))
