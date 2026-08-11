## demo.nim — a config file becomes real constants, at compile time.
##
## Build:  nimony c --path:<aowlparser>/src examples/cfgconsts/demo.nim
##
## `cfgConsts` is a nimony plugin (mcfgconsts.nim). The compiler runs it, it
## parses app.cfg with aowlparser's cfg-parsed dialect, and it hands back NIF
## declaring one constant per `key = value`. They are ordinary consts from that
## point on: typo one and the compile fails.
import std / syncio

template cfgConsts(path: string) {.plugin: "mcfgconsts".}

# 🔴 READ mcfgconsts.nim's header before copying this pattern. Editing app.cfg
# does NOT rebuild these constants: the plugin cache is keyed on the plugin's
# INPUT, which is this call — the path — and not on the file behind it. Nimony
# has no `staticRead`, so there is no way to put the bytes into the input today.
cfgConsts("examples/cfgconsts/app.cfg")

echo appName
echo version
echo port
echo level
