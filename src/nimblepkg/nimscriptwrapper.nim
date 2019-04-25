# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

## Implements the new configuration system for Nimble. Uses Nim as a
## scripting language.

import common, version, options, packageinfo, cli
import hashes, json, os, streams, strutils, strtabs,
  tables, times, osproc, sets, pegs

type
  Flags = TableRef[string, seq[string]]
  ExecutionResult*[T] = object
    success*: bool
    command*: string
    arguments*: seq[string]
    flags*: Flags
    retVal*: T

const
  internalCmd = "e"
  nimscriptApi = staticRead("nimscriptapi.nim")

proc execNimscript(nimsFile, actionName: string, options: Options,
  live = true): tuple[output: string, exitCode: int] =
  var
    cmd = ("nim e --hints:off --verbosity:0 -p:" & (getTempDir() / "nimblecache").quoteShell &
      " " & nimsFile.quoteShell & " " & actionName).strip()

  if live:
    result.exitCode = execCmd(cmd)
    let
      outFile = nimsFile & ".out"
    if outFile.fileExists():
      result.output = outFile.readFile()
      discard outFile.tryRemoveFile()
  else:
    result = execCmdEx(cmd, options = {poUsePath})

proc setupNimscript*(scriptName: string, options: Options):
  tuple[nimsFile, iniFile: string] =
  let
    cacheDir = getTempDir() / "nimblecache"
    nimscriptApiFile = cacheDir / "nimscriptapi.nim"
    shash = $scriptName.hash().abs()
    prjCacheDir = cacheDir / scriptName.splitFile().name & "_" & shash
    nimsCacheFile =
      prjCacheDir / scriptName.extractFilename().changeFileExt ".nims"

  result.nimsFile = scriptName.parentDir() / scriptName.splitFile().name &
    "_" & shash & ".nims"
  result.iniFile =
    prjCacheDir / scriptName.extractFilename().changeFileExt ".ini"

  let
    isNimscriptApiCached =
      nimscriptApiFile.fileExists() and nimscriptApiFile.getLastModificationTime() > 
      getAppFilename().getLastModificationTime()
    
    isScriptResultCached =
      prjCacheDir.dirExists() and nimsCacheFile.fileExists() and
      result.iniFile.fileExists() and
      scriptName.getLastModificationTime() < nimsCacheFile.getLastModificationTime()

    isScriptResultCopied =
      isScriptResultCached and result.nimsFile.fileExists() and
      result.nimsFile.getLastModificationTime() >=
      nimsCacheFile.getLastModificationTime()

  if not isNimscriptApiCached:
    createDir(cacheDir)
    writeFile(nimscriptApiFile, nimscriptApi)

  if not isScriptResultCached:
    createDir(prjCacheDir)
    writeFile(nimsCacheFile, """
import system except getCommand, setCommand, switch, `--`,
  packageName, version, author, description, license, srcDir, binDir, backend,
  skipDirs, skipFiles, skipExt, installDirs, installFiles, installExt, bin, foreignDeps,
  requires, task, packageName
""" &
      "import nimscriptapi, strutils\n" & scriptName.readFile() & "\nonExit()\n")
    discard tryRemoveFile(result.iniFile)

  if not isScriptResultCopied:
    nimsCacheFile.copyFile(result.nimsFile)

  if not result.iniFile.fileExists():
    let
      (output, exitCode) =
        result.nimsFile.execNimscript("printPkgInfo", options, live=false)

    if exitCode == 0 and output.len != 0:
      result.iniFile.writeFile(output)
    else:
      raise newException(NimbleError, output & "\nprintPkgInfo() failed")

proc execScript*(scriptName, actionName: string, options: Options):
  ExecutionResult[bool] =
  let
    (nimsFile, iniFile) = setupNimscript(scriptName, options)

    (output, exitCode) = nimsFile.execNimscript(actionName, options)

  defer:
    nimsFile.removeFile()

  if exitCode != 0:
    raise newException(NimbleError, output)

  let
    j =
      if output.len != 0:
        parseJson(output)
      else:
        parseJson("{}")

  result.flags = newTable[string, seq[string]]()
  result.success = j{"success"}.getBool()
  result.command = j{"command"}.getStr()
  if "project" in j:
    result.arguments.add j["project"].getStr()
  if "flags" in j:
    for flag, vals in j["flags"].pairs:
      result.flags[flag] = @[]
      for val in vals.items():
        result.flags[flag].add val.getStr()
  result.retVal = j{"retVal"}.getBool()

proc execTask*(scriptName, taskName: string,
    options: Options): ExecutionResult[bool] =
  ## Executes the specified task in the specified script.
  ##
  ## `scriptName` should be a filename pointing to the nimscript file.
  display("Executing",  "task $# in $#" % [taskName, scriptName],
          priority = HighPriority)

  result = execScript(scriptName, taskName, options)

proc execHook*(scriptName, actionName: string, before: bool,
    options: Options): ExecutionResult[bool] =
  ## Executes the specified action's hook. Depending on ``before``, either
  ## the "before" or the "after" hook.
  ##
  ## `scriptName` should be a filename pointing to the nimscript file.
  let hookName =
    if before: actionName.toLowerAscii & "Before"
    else: actionName.toLowerAscii & "After"
  display("Attempting", "to execute hook $# in $#" % [hookName, scriptName],
          priority = MediumPriority)

  result = execScript(scriptName, hookName, options)

proc hasTaskRequestedCommand*(execResult: ExecutionResult): bool =
  ## Determines whether the last executed task used ``setCommand``
  return execResult.command != internalCmd

proc listTasks*(scriptName: string, options: Options) =
  discard execScript(scriptName, "", options)
