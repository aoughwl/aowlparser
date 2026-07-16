type R = object
  case
  of Ok:
    v: int
  of Err:
    e: string
