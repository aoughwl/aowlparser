type
  Mode* = (
    when defined(android) or defined(macos):
      uint16
    else:
      uint32
  )
