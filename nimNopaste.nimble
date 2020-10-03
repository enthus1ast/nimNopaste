# Package

version       = "0.1.0"
author        = "David Krause"
description   = "a simple nopaste"
license       = "MIT"
srcDir        = "src"
bin           = @["nimNopaste"]


# Dependencies

requires "nim >= 1.2.6"
requires "norm"
requires "https://github.com/enthus1ast/nim-hashids.git"
requires "https://github.com/enthus1ast/prologue.git"
requires "karax"