type
  Dirent* = object
    when defined(haiku):
      d_dev*: int
    d_ino*: int
    when defined(dragonfly):
      d_type*: uint8
    elif defined(linux):
      d_reclen*: cshort
    when not defined(haiku):
      d_name*: array[0..255, char]
    else:
      d_name*: UncheckedArray[char]
