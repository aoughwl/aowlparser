const b = T is object
type
  T = tuple[`type`: string]
  O = object
    case kind: bool
    of true:
      aa: proc ()
    else:
      bb: int
