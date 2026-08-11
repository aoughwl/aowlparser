## webdemo.nim — CSS, HTML and both-at-once, checked while compiling.
import std / syncio

template css(s: string): string {.plugin: "mcsslit".}
template html(s: string): string {.plugin: "mhtmllit".}
template web(s: string): string {.plugin: "mweblit".}

const style = css"""
body { color: red; }
.header { font-weight: bold; }
"""

const fragment = html"""<div class="header"><span>hi</span></div>"""

const page = web"""
<style>body { margin: 0; }</style>
<div class="header">
  <ul><li>one<li>two</ul>
</div>
"""

echo style
echo fragment
echo page
