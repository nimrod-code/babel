# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import os, std/sha1, strformat, algorithm
import common, version, sha1hashes, vcstools, paths

type
  ChecksumError* = object of NimbleError

proc checksumError*(name: string, version: Version,
                    vcsRevision, checksum, expectedChecksum: Sha1Hash):
    ref ChecksumError =
  result = newNimbleError[ChecksumError](&"""
Downloaded package checksum does not correspond to that in the lock file:
  Package:           {name}@v.{version}@r.{vcsRevision}
  Checksum:          {checksum}
  Expected checksum: {expectedChecksum}
""")

proc updateSha1Checksum(checksum: var Sha1State, fileName, filePath: string) =
  if not filePath.fileExists:
    # In some cases a file name returned by `git ls-files` or `hg manifest`
    # could be an empty directory name and if so trying to open it will result
    # in a crash. This happens for example in the case of a git sub module
    # directory from which no files are being installed.
    return
  checksum.update(fileName)
  let file = filePath.open(fmRead)
  defer: close(file)
  const bufferSize = 8192
  var buffer = newString(bufferSize)
  while true:
    var bytesRead = readChars(file, buffer)
    if bytesRead == 0: break
    checksum.update(buffer[0..<bytesRead])

proc calculateDirSha1Checksum*(dir: string): Sha1Hash =
  ## Recursively calculates the sha1 checksum of the contents of the directory
  ## `dir` and its subdirectories.
  ##
  ## Raises a `NimbleError` if:
  ##   - the external command for getting the package file list fails.
  ##   - the directory does not exist.

  var packageFiles = getPackageFileList(dir.Path)
  packageFiles.sort
  var checksum = newSha1State()
  for file in packageFiles:
    updateSha1Checksum(checksum, file, dir / file)
  result = initSha1Hash($SecureHash(checksum.finalize()))
