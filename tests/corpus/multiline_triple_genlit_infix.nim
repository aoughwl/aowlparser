assert fmt"""{(block:
    var res: string
    for i in 1..3:
      res.add $i
    res)}""" == "123"
let a = re"""x"""
