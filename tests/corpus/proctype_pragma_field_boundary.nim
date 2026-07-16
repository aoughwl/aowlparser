type
  TNimType = object
    finalizer*: pointer
    marker*: proc (p: pointer, op: int) {.nimcall, tags: [], raises: [].}
    deepcopy: proc (p: pointer): pointer {.nimcall, raises: [].}
    when defined(nimSeqsV2):
      typeInfoV2*: pointer
    when defined(nimTypeNames):
      name: cstring
