# cfgconsts — a config file becomes typed constants, at compile time

```sh
nimony c --path:$PWD/src --path:$PWD/examples/cfgconsts examples/cfgconsts/cfgdemo.nim
```

`app.cfg` is parsed by aowlparser's `cfg-parsed` dialect **inside a nimony
plugin**, which hands the compiler back `const` declarations. They are ordinary
constants from that point on — misspell one and the build fails.

This is the concrete answer to "what is a byte-exact CST of a non-Nim file for?"
A nimony plugin is a program the compiler runs with NIF on stdin-ish
(`paramStr(1)`) and NIF expected back (`paramStr(2)`), so a plugin that also
wants to read a `.cfg`, `.yaml` or `.css` file can parse it into the same node
model it is already emitting — one reader vocabulary on both sides, a parser
already validated on 1,070 real config files, and real positions for errors.

## 🔴 Read this before copying the pattern

Editing `app.cfg` does **not** rebuild the constants. Reproduced: change
`version = "0.4.0"` to `"9.9.9"`, rebuild, and the program still prints `0.4.0`
— no error, no warning.

`runPlugin` keys its cache on `computeChecksum(pluginInput)`, and the input is
the call (`cfgConsts "app.cfg"`), not the file behind it. The compiler tracks
what it handed the plugin and nothing else, and the protocol has no way for a
plugin to declare an extra dependency. Nimony has no `staticRead` either
(`slurp` is a runtime `readFile`), so the bytes cannot be put where the checksum
would see them. Filed to `aowlsem`.

Until that exists:

- `touch` the plugin source when the config changes — the cache also re-runs
  when the plugin binary is newer than its output (verified);
- or don't use a plugin: generate a `.nim` with `aowlparser cfg` as a build
  step, which the compiler tracks correctly because it is an ordinary input.
