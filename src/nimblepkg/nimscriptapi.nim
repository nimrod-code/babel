# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

## This module is implicitly imported in NimScript .nimble files.

import system except getCommand, setCommand, switch, `--`
import strformat, strutils, tables

var
  packageName* = ""    ## Set this to the package name. It
                       ## is usually not required to do that, nims' filename is
                       ## the default.
  version*: string     ## The package's version.
  author*: string      ## The package's author.
  description*: string ## The package's description.
  license*: string     ## The package's license.
  srcdir*: string      ## The package's source directory.
  binDir*: string      ## The package's binary directory.
  backend*: string     ## The package's backend.

  skipDirs*, skipFiles*, skipExt*, installDirs*, installFiles*,
    installExt*, bin*: seq[string] = @[] ## Nimble metadata.
  requiresData*: seq[string] = @[] ## The package's dependencies.

  foreignDeps*: seq[string] = @[] ## The foreign dependencies. Only
                                  ## exported for 'distros.nim'.

  beforeHooks: seq[string] = @[]
  afterHooks: seq[string] = @[]
  commandLineParams: seq[string] = @[]
  flags: TableRef[string, seq[string]]

  command = "e"
  project = ""
  success = false
  retVal = true

proc requires*(deps: varargs[string]) =
  ## Call this to set the list of requirements of your Nimble
  ## package.
  for d in deps: requiresData.add(d)

proc getParams() =
  for i in 4 .. paramCount():
    commandLineParams.add paramStr(i).normalize

proc getCommand(): string =
  return command

proc setCommand(cmd: string, prj = "") =
  command = cmd
  if prj.len != 0:
    project = prj

proc switch(key: string, value="") =
  if flags.isNil:
    flags = newTable[string, seq[string]]()

  if flags.hasKey(key):
    flags[key].add(value)
  else:
    flags[key] = @[value]

template `--`(key, val: untyped) =
  switch(astToStr(key), strip astToStr(val))

template `--`(key: untyped) =
  switch(astToStr(key), "")

template printIfLen(varName) =
  if varName.len != 0:
    iniOut &= astToStr(varName) & ": \"" & varName & "\"\n"

template printSeqIfLen(varName) =
  if varName.len != 0:
    iniOut &= astToStr(varName) & ": \"" & varName.join(", ") & "\"\n"

proc printPkgInfo() =
  if backend.len == 0:
    backend = "c"

  var
    iniOut = "[Package]\n"
  if packageName.len != 0:
    iniOut &= "name: \"" & packageName & "\"\n"
  printIfLen version
  printIfLen author
  printIfLen description
  printIfLen license
  printIfLen srcdir
  printIfLen binDir
  printIfLen backend

  printSeqIfLen skipDirs
  printSeqIfLen skipFiles
  printSeqIfLen skipExt
  printSeqIfLen installDirs
  printSeqIfLen installFiles
  printSeqIfLen installExt
  printSeqIfLen bin
  printSeqIfLen beforeHooks
  printSeqIfLen afterHooks

  if requiresData.len != 0:
    iniOut &= "\n[Deps]\n"
    iniOut &= &"requires: \"{requiresData.join(\", \")}\"\n"

  echo iniOut

proc onExit() =
  if "printPkgInfo".normalize in commandLineParams:
    printPkgInfo()
  else:
    var
      output = ""
    output &= "\"success\": " & $success & ", "
    output &= "\"command\": \"" & command & "\", "
    if project.len != 0:
      output &= "\"project\": \"" & project & "\", "
    if not flags.isNil and flags.len != 0:
      output &= "\"flags\": {"
      for key, val in flags.pairs:
        output &= "\"" & key & "\": ["
        for v in val:
          output &= "\"" & v & "\", "
        output = output[0 .. ^3] & "], "
      output = output[0 .. ^3] & "}, "

    output &= "\"retVal\": " & $retVal

    echo "{" & output & "}"

# TODO: New release of Nim will move this `task` template under a
# `when not defined(nimble)`. This will allow us to override it in the future.
template task*(name: untyped; description: string; body: untyped): untyped =
  ## Defines a task. Hidden tasks are supported via an empty description.
  ## Example:
  ##
  ## .. code-block:: nim
  ##  task build, "default build is via the C backend":
  ##    setCommand "c"
  proc `name Task`*() = body

  if commandLineParams.len == 0 or "help" in commandLineParams:
    success = true
    echo(astToStr(name), "        ", description)
  elif astToStr(name).normalize in commandLineParams:
    success = true
    `name Task`()

template before*(action: untyped, body: untyped): untyped =
  ## Defines a block of code which is evaluated before ``action`` is executed.
  proc `action Before`*(): bool =
    result = true
    body

  beforeHooks.add astToStr(action)

  if (astToStr(action) & "Before").normalize in commandLineParams:
    success = true
    retVal = `action Before`()

template after*(action: untyped, body: untyped): untyped =
  ## Defines a block of code which is evaluated after ``action`` is executed.
  proc `action After`*(): bool =
    result = true
    body

  afterHooks.add astToStr(action)

  if (astToStr(action) & "After").normalize in commandLineParams:
    success = true
    retVal = `action After`()

proc getPkgDir(): string =
  ## Returns the package directory containing the .nimble file currently
  ## being evaluated.
  result = currentSourcePath.rsplit(seps={'/', '\\', ':'}, maxsplit=1)[0]

getParams()
