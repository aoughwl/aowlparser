type
  Rule = object
    ruleInvocations {.requiresInit.}: Table[string, int]
    plain: bool
