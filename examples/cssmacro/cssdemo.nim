## demo.nim — CSS checked by the compiler.
import std / syncio

template css(s: string): string {.plugin: "mcsslit".}

const style = css"""
body { color: red; }
.header { font-weight: bold; }
"""

echo style
