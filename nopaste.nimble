# Package

version       = "0.1.1"
author        = "David Krause"
description   = "a simple nopaste"
license       = "MIT"
srcDir        = "src"
bin           = @["nopaste"]


# Dependencies

requires "nim >= 1.2.6"
requires "norm"
requires "https://github.com/enthus1ast/nim-hashids.git"
requires "prologue"
requires "karax"
