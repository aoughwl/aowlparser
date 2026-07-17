proc f() =
  procBody.insert(0): quote do:
    {.push warning[resultshadowed]: off.}
    var x = 1
    {.pop.}
  var it = newProc(sym, [quote do: owned(FutureBase), retParam], body)
