# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

## This module implements operations required for working with Nimble develop
## files.

import sets, json, sequtils, os, strformat, tables, hashes, strutils, math,
       std/jsonutils

import typetraits except distinctBase

import common, cli, packageinfotypes, packageinfo, packageparser, options,
       version, counttables, aliasthis, paths, displaymessages, sha1hashes,
       tools, vcstools, syncfile, lockfile

type
  DevelopFileJsonData = object
    # The raw data read from the JSON develop file.
    includes: OrderedSet[Path]
      ## Paths to the included in the current one develop files.
    dependencies: OrderedSet[Path]
      ## Paths to the dependencies directories.

  DevFileNameToPkgs* = Table[Path, HashSet[ref PackageInfo]]
    ## Mapping between a develop file name and a set of packages.

  PkgToDevFileNames* = Table[ref PackageInfo, HashSet[Path]]
    ## Mapping between a package and a set of develop files.

  DevelopFileData* = object
    ## The raw data read from the JSON develop file plus the metadata.
    path: Path
      ## The full path to the develop file.
    jsonData: DevelopFileJsonData
      ## The actual content of the develop file.
    nameToPkg: Table[string, ref PackageInfo]
      ## The list of packages coming from the current develop file or some of
      ## its includes, indexed by package name.
    pathToPkg: Table[Path, ref PackageInfo]
      ## The list of packages coming from the current develop file or some of
      ## its includes, indexed by package path.
    devFileNameToPkgs: DevFileNameToPkgs
      ## For each develop file contains references to the packages coming from
      ## it or some of its includes. It is used to keep information for which
      ## packages, the reference count must be decreased when a develop file
      ## is removed.
    pkgToDevFileNames: PkgToDevFileNames
      ## For each package contains the set of names of the develop files where
      ## the path to its directory is mentioned. Used for colliding names error
      ## reporting when packages with same name but different paths are present.
    pkgRefCount: counttables.CountTable[ref PackageInfo]
      ## For each package contains the number of times it is included from
      ## different develop files. When the reference count drops to zero the
      ## package will be removed from all internal meta data structures.
    dependentPkg: PackageInfo
      ## The `PackageInfo` of the package in the current directory.
      ## It can be missing in the case that this is a develop file intended only
      ## for inclusion in other develop files and not related to specific
      ## package.

  DevelopFileDataCache = Table[Path, DevelopFileData]
    ## A cache for the loaded develop files data used to avoid multiple loads
    ## of the same file when its data is queried in the code.

  DevelopFileJsonKeys = enum
    ## Develop file JSON objects names. 
    dfjkVersion = "version"
    dfjkIncludes = "includes"
    dfjkDependencies = "dependencies"

  NameCollisionRecord = tuple[pkgPath, inclFilePath: Path]
    ## Describes the path to a package with a name same as the name of another
    ## package, and the path to develop files where it is found.

  CollidingNames = Table[string, HashSet[NameCollisionRecord]]
    ## Describes Nimble packages names found more than once in a develop file
    ## either directly or via its includes but pointing to different paths.

  InvalidPaths = Table[Path, ref CatchableError]
    ## Describes an invalid path to a Nimble package or included develop file.
    ## Contains the path as a key and the exact error occurred when we had tried
    ## to read the package or the develop file at it.
  
  ErrorsCollection = object
    ## Describes the different errors which are possible to occur on loading of
    ## a develop file.
    collidingNames: CollidingNames
    invalidPackages: InvalidPaths
    invalidIncludeFiles: InvalidPaths

{.warning[UnsafeDefault]: off.}
{.warning[ProveInit]: off.}
aliasThis DevelopFileData.jsonData
{.warning[ProveInit]: on.}
{.warning[UnsafeDefault]: on.}

const
  developFileName* = "nimble.develop"
    ## The default name of a Nimble's develop file. This must always be the name
    ## of develop files which are not only for inclusion but associated with a
    ## specific package.
  developFileVersion* = "0.1.0"
    ## The version of the develop file's JSON schema.

proc initDevelopFileData: DevelopFileData =
  result = DevelopFileData(dependentPkg: initPackageInfo())

proc getNimbleFilePath(pkgInfo: PackageInfo): Path =
  ## This is a version of `PackageInfo`'s `getNimbleFileDir` procedure returning
  ## `Path` type.
  pkgInfo.getNimbleFileDir.Path

proc assertHasDependentPkg(data: DevelopFileData) =
  ## Checks whether there is associated dependent package with the `data`.
  assert data.dependentPkg.isLoaded,
         "This procedure must be used only with associated with particular " &
         "package develop files."

proc getPkgDevFilePath(pkg: PackageInfo): Path =
  ## Returns the path to the develop file associated with the package `pkg`.
  pkg.getNimbleFilePath / developFileName

proc getDependentPkgDevFilePath(data: DevelopFileData): Path =
  ## Returns the path to the develop file of the dependent package associated
  ## with `data`.
  data.assertHasDependentPkg
  data.dependentPkg.getPkgDevFilePath

proc isEmpty*(data: DevelopFileData): bool =
  ## Checks whether there is some content (paths to packages directories or 
  ## includes to other develop files) in the develop file.
  data.includes.len == 0 and data.dependencies.len == 0

proc save*(data: DevelopFileData, path: Path, writeEmpty, overwrite: bool) =
  ## Saves the `data` to a JSON file with path `path`. If the `data` is empty
  ## writes an empty JSON file only if `writeEmpty` is `true`.
  ##
  ## Raises an `IOError` if:
  ##   - `overwrite` is `false` and the file with path `path` already exists.
  ##   - for some reason the writing of the file fails.

  if not writeEmpty and data.isEmpty:
    return

  let json = %{
    $dfjkVersion: %developFileVersion,
    $dfjkIncludes: %data.includes.toSeq,
    $dfjkDependencies: %data.dependencies.toSeq,
    }

  if path.fileExists and not overwrite:
    raise nimbleError(fileAlreadyExistsMsg($path))

  writeFile(path, json.pretty)

template save(data: DevelopFileData, args: varargs[untyped]) =
  ## Saves the `data` to a JSON file in in the directory of `data`'s
  ## `dependentPkg` Nimble file.  Delegates the functionality to the `save`
  ## procedure taking path to develop file.
  data.assertHasDependentPkg
  let fileName = data.getDependentPkgDevFilePath
  data.save(fileName, args)

proc developFileExists*(dir: Path): bool =
  ## Returns `true` if there is a Nimble develop file with a default name in
  ## the directory `dir` or `false` otherwise.
  fileExists(dir / developFileName)

proc developFileExists*(pkg: PackageInfo): bool =
  ## Returns `true` if there is a Nimble develop file with a default name in
  ## the directory of the package's `pkg` `.nimble` file or `false` otherwise.
  pkg.getNimbleFilePath.developFileExists

proc raiseDependencyNotInRangeError(
    dependencyNameAndVersion, dependentNameAndVersion: string,
    versionRange: VersionRange) =
  ## Raises `DependencyNotInRange` exception.
  raise nimbleError(
    dependencyNotInRangeErrorMsg(
      dependencyNameAndVersion, dependentNameAndVersion, versionRange),
    dependencyNotInRangeErrorHint)

proc raiseNotADependencyError(
    dependencyNameAndVersion, dependentNameAndVersion: string) =
  ## Raises `NotADependency` exception.
  raise nimbleError(
    notADependencyErrorMsg(dependencyNameAndVersion, dependentNameAndVersion),
    notADependencyErrorHint)

proc validateDependency(dependencyPkg, dependentPkg: PackageInfo) =
  ## Checks whether `dependencyPkg` is a valid dependency of the `dependentPkg`.
  ## If it is not, then raises a `NimbleError` or otherwise simply returns.
  ##
  ## Raises a `NimbleError` if:
  ##   - the `dependencyPkg` is not a dependency of the `dependentPkg`.
  ##   - the `dependencyPkg` is a dependency og the `dependentPkg`, but its
  ##     version is out of the required by `dependentPkg` version range.

  var isNameFound = false
  var versionRange = parseVersionRange("") # any version

  for pkg in dependentPkg.requires:
    if cmpIgnoreStyle(dependencyPkg.name, pkg.name) == 0:
      isNameFound = true
      if Version(dependencyPkg.version) in pkg.ver:
        # `dependencyPkg` is a valid dependency of `dependentPkg`.
        return
      else:
        # The package with a name `dependencyPkg.name` is found among
        # `dependentPkg` dependencies but its version is out of the required
        # range.
        versionRange = pkg.ver
        break

  # If in `dependentPkg` requires clauses is not found a package with a name
  # `dependencyPkg.name` or its version is not in the required range, then
  # `dependencyPkg` is not a valid dependency of `dependentPkg`.

  let dependencyPkgNameAndVersion = dependencyPkg.getNameAndVersion()
  let dependentPkgNameAndVersion = dependentPkg.getNameAndVersion()

  if isNameFound:
    raiseDependencyNotInRangeError(
      dependencyPkgNameAndVersion, dependentPkgNameAndVersion, versionRange)
  else:
    raiseNotADependencyError(
      dependencyPkgNameAndVersion, dependentPkgNameAndVersion)

proc validateIncludedDependency(dependencyPkg, dependentPkg: PackageInfo,
                                requiredVersionRange: VersionRange):
    ref CatchableError =
  ## Checks whether the `dependencyPkg` version is in required by the
  ## `dependentPkg` version range and if not returns a reference to an error
  ## object. Otherwise returns `nil`.

  return
    if Version(dependencyPkg.version) in requiredVersionRange: nil
    else: nimbleError(
      dependencyNotInRangeErrorMsg(
        dependencyPkg.getNameAndVersion, dependentPkg.getNameAndVersion,
        requiredVersionRange),
      dependencyNotInRangeErrorHint)

proc validatePackage(pkgPath: Path, dependentPkg: PackageInfo,
                     options: Options):
    tuple[pkgInfo: PackageInfo, error: ref CatchableError] =
  ## By given file system path `pkgPath`, determines whether it points to a
  ## valid Nimble package.
  ##
  ## If a not empty `dependentPkg` argument is given checks whether the package
  ## at `pkgPath` is a valid dependency of `dependentPkg`.
  ##
  ## Returns a tuple containing:
  ##   - `pkgInfo` - the package info of the package at `pkgPath` in case
  ##                 `pkgPath` directory contains a valid Nimble package.
  ##
  ##   - `error`   - a reference to the exception raised in case `pkgPath` is
  ##                 not a valid package directory or the package in `pkgPath`
  ##                 is not a valid dependency of the `dependentPkg`.

  try:
    result.pkgInfo = getPkgInfo(string(pkgPath), options, true)
    if dependentPkg.isLoaded:
      validateDependency(result.pkgInfo, dependentPkg)
  except CatchableError as error:
    result.error = error

proc filterAndValidateIncludedPackages(dependentPkg: PackageInfo,
                                       inclFileData: DevelopFileData,
                                       invalidPackages: var InvalidPaths):
    seq[ref PackageInfo] =
  ## Iterates over `dependentPkg` dependencies and for each one found in the
  ## `inclFileData` list of packages checks whether it is in the required
  ## version range. If so stores it to the result sequence and otherwise stores
  ## an error object in `invalidPackages` sequence for future error reporting.

  # For each dependency of the dependent package.
  for pkg in dependentPkg.requires:
    # Check whether it is in the loaded from the included develop file
    # dependencies.
    let inclPkg = inclFileData.nameToPkg.getOrDefault pkg.name
    if inclPkg == nil:
      # If not then continue.
      continue
    # Otherwise validate it against the dependent package.
    let error = validateIncludedDependency(inclPkg[], dependentPkg, pkg.ver)
    if error == nil:
      result.add inclPkg
    else:
      invalidPackages[inclPkg[].getNimbleFilePath] = error

proc hasErrors(errors: ErrorsCollection): bool =
  ## Checks whether there are some errors in the `ErrorsCollection` - `errors`.
  errors.collidingNames.len > 0 or errors.invalidPackages.len > 0 or
  errors.invalidIncludeFiles.len > 0

proc pkgFoundMoreThanOnceMsg*(
    pkgName: string, collisions: HashSet[NameCollisionRecord]): string =
  result = &"A package with name \"{pkgName}\" is found more than once."
  for (pkgPath, inclFilePath) in collisions:
    result &= &"\"{pkgPath}\" from file \"{inclFilePath}\""

proc getErrorsDetails(errors: ErrorsCollection): string =
  ## Constructs a message with details about the collected errors.

  for pkgPath, error in errors.invalidPackages:
    result &= invalidPkgMsg($pkgPath)
    result &= &"\nReason: {error.msg}\n\n"

  for inclFilePath, error in errors.invalidIncludeFiles:
    result &= invalidDevFileMsg($inclFilePath)
    result &= &"\nReason: {error.msg}\n\n"

  for pkgName, collisions in errors.collidingNames:
    result &= pkgFoundMoreThanOnceMsg(pkgName, collisions)
    result &= "\n"

proc add[K, V](t: var Table[K, HashSet[V]], k: K, v: V) =
  ## Adds a value `v` to the hash set corresponding to the key `k` of the table
  ## `t` by first inserting the key `k` and a new hash set into the table `t`,
  ## if they don't already exist.
  t.withValue(k, value) do:
    value[].incl(v)
  do:
    t[k] = [v].toHashSet

proc add[K, V](t: var Table[K, HashSet[V]], k: K, values: HashSet[V]) =
  ## Adds all values from the hash set `values` to the hash set corresponding
  ## to the key `k` of the table `t` by first inserting the key `k` and a new
  ## hash set into the table `t`, if they don't already exist.
  for v in values: t.add(k, v)

proc del[K, V](t: var Table[K, HashSet[V]], k: K, v: V) =
  ## Removed a value `v` from the hash set corresponding to the key `k` of the
  ## table `t` and removes the key and the corresponding hash set from the
  ## table in the case the hash set becomes empty. Does nothing if the key in
  ## not present in the table or the value is not present in the hash set.

  t.withValue(k, value) do:
    value[].excl(v)
    if value[].len == 0:
      t.del(k)

proc assertHasKey[K, V](t: Table[K, V], k: K) =
  ## Asserts that the key `k` is present in the table `t`.
  assert t.hasKey(k),
         &"At this point the key `{k}` should be present in the table {t}."

proc addPackage(data: var DevelopFileData, pkgInfo: PackageInfo,
                comingFrom: Path, actualComingFrom: HashSet[Path],
                collidingNames: var CollidingNames) =
  ## Adds a package `pkgInfo` to the `data` internal meta data structures.
  ##
  ## Other parameters:
  ##   `comingFrom`       - the develop file name which loading causes the
  ##                        package to be included.
  ##
  ##   `actualComingFrom` - the set of actual develop files where the package
  ##                        path is mentioned.
  ##
  ##   `collidingNames`   - an output parameters where packages with same name
  ##                        but with different paths are registered for error
  ##                        reporting.

  var pkg = data.nameToPkg.getOrDefault(pkgInfo.name)
  if pkg == nil:
    # If a package with `pkgInfo.name` is missing add it to the
    # `DevelopFileData` internal data structures add it.
    {.warning[ProveInit]: off.}
    pkg = pkgInfo.newClone
    {.warning[ProveInit]: on.}
    data.pkgRefCount.inc(pkg)
    data.nameToPkg[pkg[].name] = pkg
    data.pathToPkg[pkg[].getNimbleFilePath()] = pkg
    data.devFileNameToPkgs.add(comingFrom, pkg)
    data.pkgToDevFileNames.add(pkg, actualComingFrom)
  else:
    # If a package with `pkgInfo.name` is already included check whether it has
    # the same path as the package we are trying to include.
    let
      alreadyIncludedPkgPath = pkg[].getNimbleFilePath()
      newPkgPath = pkgInfo.getNimbleFilePath()

    if alreadyIncludedPkgPath == newPkgPath:
      # If the paths are the same then increase the reference count of the
      # package and register the new develop files from where it is coming.
      data.pkgRefCount.inc(pkg)
      data.devFileNameToPkgs.add(comingFrom, pkg)
      data.pkgToDevFileNames.add(pkg, actualComingFrom)
    else:
      # But if we already have a package with the same name at different path
      # register the name collision which to be reported as error.
      assertHasKey(data.pkgToDevFileNames, pkg)
      for devFileName in data.pkgToDevFileNames[pkg]:
        collidingNames.add(pkg[].name, (alreadyIncludedPkgPath, devFileName))
      for devFileName in actualComingFrom:
        collidingNames.add(pkg[].name, (newPkgPath, devFileName))

proc values[K, V](t: Table[K, V]): seq[V] =
  ## Returns a sequence containing table's `t` values.
  result.setLen(t.len)
  var i: Natural = 0
  for v in t.values:
    result[i] = v
    inc(i)

proc addPackages(lhs: var DevelopFileData, pkgs: seq[ref PackageInfo],
                 rhsPath: Path, rhsPkgToDevFileNames: PkgToDevFileNames,
                 collidingNames: var CollidingNames) =
  ## Adds packages from `pkgs` sequence to the develop file data `lhs`.
  for pkgRef in pkgs:
    assertHasKey(rhsPkgToDevFileNames, pkgRef)
    lhs.addPackage(pkgRef[], rhsPath, rhsPkgToDevFileNames[pkgRef],
                   collidingNames)

proc mergeIncludedDevFileData(lhs: var DevelopFileData, rhs: DevelopFileData,
                              errors: var ErrorsCollection) =
  ## Merges develop file data `rhs` coming from some included develop file into
  ## `lhs`. If `lhs` represents develop file data of some package, but not a
  ## free develop file, then first filter and validate `rhs` packages against
  ## `lhs`'s list of dependencies.

  let pkgs =
    if lhs.dependentPkg.isLoaded:
      filterAndValidateIncludedPackages(
        lhs.dependentPkg, rhs, errors.invalidPackages)
    else:
      rhs.nameToPkg.values

  lhs.addPackages(pkgs, rhs.path, rhs.pkgToDevFileNames, errors.collidingNames)

proc mergeFollowedDevFileData(lhs: var DevelopFileData, rhs: DevelopFileData,
                              errors: var ErrorsCollection) =
  ## Merges develop file data `rhs` coming from some followed package's develop
  ## file into `lhs`.
  rhs.assertHasDependentPkg
  lhs.addPackages(rhs.nameToPkg.values, rhs.path, rhs.pkgToDevFileNames,
                  errors.collidingNames)

proc load(path: Path, dependentPkg: PackageInfo, options: Options,
          silentIfFileNotExists, raiseOnValidationErrors: bool):
    DevelopFileData

template load(dependentPkg: PackageInfo, args: varargs[untyped]):
    DevelopFileData =
  ## Loads data for the `dependentPkg`'s develop file by searching it in the
  ## package's Nimble file directory. Delegates the functionality to the `load`
  ## procedure taking path to develop file.
  dependentPkg.assertIsLoaded
  load(dependentPkg.getPkgDevFilePath, dependentPkg, args)

proc load(path: Path, dependentPkg: PackageInfo, options: Options,
          silentIfFileNotExists, raiseOnValidationErrors: bool):
    DevelopFileData =
  ## Loads data from a develop file at path `path`.
  ##
  ## If `silentIfFileNotExists` then does nothing in the case the develop file
  ## does not exists.
  ##
  ## If `raiseOnValidationErrors` raises a `NimbleError` in the case some of the
  ## contents of the develop file are invalid.
  ##
  ## Raises if the develop file or some of the included develop files:
  ##   - cannot be read.
  ##   - has an invalid JSON schema.
  ##   - contains a path to some invalid package.
  ##   - contains paths to multiple packages with the same name.

  var cache {.global.}: DevelopFileDataCache
  if cache.hasKey(path):
    return cache[path]
  
  result = initDevelopFileData()
  result.path = path
  result.dependentPkg = dependentPkg

  if silentIfFileNotExists and not path.fileExists:
    return

  var
    errors {.global.}: ErrorsCollection
    visitedFiles {.global.}: HashSet[Path]
    visitedPkgs {.global.}: HashSet[Path]

  visitedFiles.incl path
  if dependentPkg.isLoaded:
    visitedPkgs.incl dependentPkg.getNimbleFileDir

  try:
    fromJson(result.jsonData, parseFile(path), Joptions(allowExtraKeys: true))
  except ValueError as error:
    raise nimbleError(notAValidDevFileJsonMsg($path), details = error)

  for depPath in result.dependencies:
    let depPath = if depPath.isAbsolute:
      depPath.normalizedPath else: (path.splitFile.dir / depPath).normalizedPath
    let (pkgInfo, error) = validatePackage(
      depPath, result.dependentPkg, options)
    if error == nil:
      result.addPackage(pkgInfo, path, [path].toHashSet, errors.collidingNames)
    else:
      errors.invalidPackages[depPath] = error

  for inclPath in result.includes:
    let inclPath = inclPath.normalizedPath
    if visitedFiles.contains(inclPath):
      continue
    var inclDevFileData = initDevelopFileData()
    try:
      inclDevFileData = load(inclPath, initPackageInfo(), options, false, false)
    except CatchableError as error:
      errors.invalidIncludeFiles[path] = error
      continue
    result.mergeIncludedDevFileData(inclDevFileData, errors)

  if result.dependentPkg.isLoaded:
    # If this is a package develop file, but not a free one, for each of the
    # package's develop mode dependencies load its develop file if it is not
    # already loaded and merge its data to the current develop file's data.
    for path, pkg in result.pathToPkg.dup:
      if visitedPkgs.contains(path):
        continue
      var followedPkgDevFileData = initDevelopFileData()
      try:
        followedPkgDevFileData = load(pkg[], options, true, false)
      except:
        # The errors will be accumulated in `errors` global variable and
        # reported by the `load` call which initiated the recursive process.
        discard
      result.mergeFollowedDevFileData(followedPkgDevFileData, errors)

  if not errors.hasErrors:
      cache[path] = result
      return result
  elif raiseOnValidationErrors:
    raise nimbleError(failedToLoadFileMsg($path),
                      details = nimbleError(errors.getErrorsDetails))

proc addDevelopPackage(data: var DevelopFileData, pkg: PackageInfo): bool =
  ## Adds package `pkg`'s path to the develop file.
  ##
  ## Returns `true` if:
  ##   - the path is successfully added to the develop file.
  ##   - the path is already present in the develop file.
  ##     (Only a warning in printed in this case.)
  ##
  ## Returns `false` in the case of error when:
  ##   - a package with the same name but at different path is already present
  ##     in the develop file or some of its includes.
  ##   - the package `pkg` is not a valid dependency of the dependent package.

  let pkgDir = pkg.getNimbleFilePath()

  # Check whether the develop file already contains a package with a name
  # `pkg.name` at different path.
  if data.nameToPkg.hasKey(pkg.name) and not data.pathToPkg.hasKey(pkgDir):
    let otherPath = data.nameToPkg[pkg.name][].getNimbleFilePath()
    displayError(pkgAlreadyPresentAtDifferentPathMsg(pkg.name, $otherPath))
    return false

  if data.dependentPkg.isLoaded:
    # Check whether `pkg` is a valid dependency.
    try:
      validateDependency(pkg, data.dependentPkg)
    except CatchableError as error:
      displayError(error)
      return false

  # Add `pkg` to the develop file model.
  let success = not data.dependencies.containsOrIncl(pkgDir)

  var collidingNames: CollidingNames
  addPackage(data, pkg, data.path, [data.path].toHashSet, collidingNames)
  assert collidingNames.len == 0, "Must not have the same package name at " &
                                  "path different than already existing one."

  if success:
    displaySuccess(pkgAddedInDevModeMsg(pkg.getNameAndVersion, $pkgDir))
  else:
    displayWarning(pkgAlreadyInDevModeMsg(pkg.getNameAndVersion, $pkgDir))

  return true

proc addDevelopPackage(data: var DevelopFileData, path: Path,
                       options: Options): bool =
  ## Adds path `path` to some package directory to the develop file.
  ##
  ## Returns `true` if:
  ##   - the path is successfully added to the develop file.
  ##   - the path is already present in  .
  ##     (Only a warning in printed in this case.)
  ##
  ## Returns `false` in the case of error when:
  ##   - the path in `path` does not point to a valid Nimble package.
  ##   - a package with the same name but at different path is already present
  ##     in the develop file or some of its includes.
  ##   - the package `pkg` is not a valid dependency of the dependent package.

  let (pkgInfo, error) = validatePackage(path, initPackageInfo(), options)
  if error != nil:
    displayError(invalidPkgMsg($path))
    displayDetails(error)
    return false

  return addDevelopPackage(data, pkgInfo)

# proc addDevelopPackageEx*(data: var DevelopFileData, path: Path,
#                           options: Options) =
#   ## Adds a package at path `path` to a free develop file intended for inclusion
#   ## in other packages develop files.
#   ##
#   ## Raises if:
#   ##   - the path in `path` does not point to a valid Nimble package.
#   ##   - a package with the same name but at different path is already present
#   ##     in the develop file or some of its includes.
#   ##   - the path is already present in the develop file.

#   assert not data.dependentPkg.isSome,
#          "This procedure can only be used for free develop files intended " &
#          "for inclusion in other packages develop files."

#   let (pkg, error) = validatePackage(path, PackageInfo.none, options)
#   if error != nil:
#     raise error

#   # Check whether the develop file already contains a package with a name
#   # `pkg.name` at different path.
#   if data.nameToPkg.hasKey(pkg.name) and not data.pathToPkg.hasKey(path):
#     raise nimbleError(
#       pkgAlreadyPresentAtDifferentPathMsg(pkg.name, $data.pathToPkg[pkg.name]))

#   # Add `pkg` to the develop file model.
#   let success = not data.dependencies.containsOrIncl(path)

#   var collidingNames: CollidingNames
#   addPackage(data, pkg, data.path, [data.path].toHashSet, collidingNames)
#   assert collidingNames.len == 0, "Must not have the same package name at " &
#                                   "path different than already existing one."

#   if not success:
#     raise nimbleError(pkgAlreadyInDevModeMsg(pkg.getNameAndVersion, $path))

proc removePackage(data: var DevelopFileData, pkg: ref PackageInfo,
                   devFileName: Path) =
  ## Decreases the reference count for a package at path `path` and removes the
  ## package from the internal meta data structures in case the reference count
  ## drops to zero.

  # If the package is found it must be excluded from the develop file mappings
  # by using the name of the develop file as result of which manipulation the
  # package is being removed.
  data.devFileNameToPkgs.del(devFileName, pkg)
  data.pkgToDevFileNames.del(pkg, devFileName)

  # Also the reference count of the package should be decreased.
  let removed = data.pkgRefCount.dec(pkg)
  if not removed:
    # If the reference count is not zero no further processing is needed.
    return

  # But if the reference count is zero the package should be removed from all
  # other meta data structures to free memory for it and its indexes.
  data.nameToPkg.del(pkg[].name)
  data.pathToPkg.del(pkg[].getNimbleFilePath())

  # The package `pkg` could already be missing from `pkgToDevFileNames` if it
  # is removed with the removal of `devFileName` value, but if it is included
  # from some of `devFileName`'s includes it will still be present and we
  # should remove it completely to free its memory.
  data.pkgToDevFileNames.del(pkg)

proc removePackage(data: var DevelopFileData, path, devFileName: Path) =
  ## Decreases the reference count for a package at path `path` and removes the
  ## package from the internal meta data structures in case the reference count
  ## drops to zero.

  let pkg = data.pathToPkg.getOrDefault(path)
  if pkg == nil:
    # If there is no package at path `path` found.
    return

  data.removePackage(pkg, devFileName)

proc removeDevelopPackageByPath(data: var DevelopFileData, path: Path): bool =
  ## Removes path `path` to some package directory from the develop file.
  ## If the `path` is not present in the develop file prints a warning.
  ##
  ## Returns `true` if path `path` is successfully removed from the develop file
  ## or `false` if there is no such path added in it.

  let success = not data.dependencies.missingOrExcl(path)

  if success:
    let nameAndVersion = data.pathToPkg[path][].getNameAndVersion()
    data.removePackage(path, data.path)
    displaySuccess(pkgRemovedFromDevModeMsg(nameAndVersion, $path))
  else:
    displayWarning(pkgPathNotInDevFileMsg($path))

  return success

proc removeDevelopPackageByName(data: var DevelopFileData, name: string): bool =
  ## Removes path to a package with name `name` from the develop file.
  ## If a package with name `name` is not present in the develop file prints a
  ## warning.
  ##
  ## Returns `true` if a package with name `name` is successfully removed from
  ## the develop file or `false` if there is no such package added in it.

  let
    pkg = data.nameToPkg.getOrDefault(name)
    path = if pkg != nil: pkg[].getNimbleFilePath() else: ""
    success = not data.dependencies.missingOrExcl(path)

  if success:
    data.removePackage(path, data.path)
    displaySuccess(pkgRemovedFromDevModeMsg(pkg[].getNameAndVersion, $path))
  else:
    displayWarning(pkgNameNotInDevFileMsg(name))

  return success

proc includeDevelopFile(data: var DevelopFileData, path: Path,
                        options: Options): bool =
  ## Includes a develop file at path `path` to the current project's develop
  ## file.
  ##
  ## Returns `true` if the develop file at `path` is:
  ##   - successfully included in the current project's develop file.
  ##   - already present in the current project's develop file.
  ##     (Only a warning in printed in this case.)
  ##
  ## Returns `false` in the case of error when:
  ##   - the develop file at `path` could not be loaded.
  ##   - the inclusion of the develop file at `path` causes a packages names
  ##     collisions with already added from different place packages with
  ##     the same name, but with different location.

  var inclFileData = initDevelopFileData()
  try:
    inclFileData = load(path, initPackageInfo(), options, false, true)
  except CatchableError as error:
    displayError(failedToLoadFileMsg($path))
    displayDetails(error)
    return false

  let success = not data.includes.containsOrIncl(path)

  if success:
    var errors: ErrorsCollection
    data.mergeIncludedDevFileData(inclFileData, errors)
    if errors.hasErrors:
      displayError(failedToInclInDevFileMsg($path, $data.path))
      displayDetails(errors.getErrorsDetails)                              
      # Revert the inclusion in the case of merge errors.
      data.includes.excl(path)
      for pkgPath, _ in inclFileData.pathToPkg:
        data.removePackage(pkgPath, path)
      return false

    displaySuccess(inclInDevFileMsg($path))
  else:
    displayWarning(alreadyInclInDevFileMsg($path))

  return true

proc excludeDevelopFile(data: var DevelopFileData, path: Path): bool =
  ## Excludes a develop file at path `path` from the current project's develop
  ## file. If there is no such, then only a warning is printed.
  ##
  ## Returns `true` if a develop file at path `path` is successfully removed
  ## from the current project's develop file or `false` if there is no such
  ## file included in the current one.

  let success = not data.includes.missingOrExcl(path)

  if success:
    assertHasKey(data.devFileNameToPkgs, path)

    # Copy the references of the packages which should be deleted, because
    # deleting from the same hash set which we iterate will not be correct.
    var packages = data.devFileNameToPkgs[path].toSeq

    # Try to remove the packages coming from the develop file at path `path` or
    # some of its includes by decreasing their reference count and appropriately
    # updating all other internal meta data structures.
    for pkg in packages:
      data.removePackage(pkg, path)

    displaySuccess(exclFromDevFileMsg($path))
  else:
    displayWarning(notInclInDevFileMsg($path))

  return success

proc createEmptyDevelopFile(path: Path, options: Options): bool =
  ## Creates an empty develop file at given path `path` or with a default name
  ## in the current directory if there is no path given.

  let filePath = if path.len == 0: Path(developFileName) else: path

  try:
    var data = initDevelopFileData()
    data.save(filePath, writeEmpty = true, overwrite = false)
  except CatchableError as error:
    displayError(error)
    return false

  displaySuccess(emptyDevFileCreatedMsg($filePath))
  return true

proc assertDevelopActionIsSet(options: Options) =
  ## Asserts that the currently set action in the `options` object is `develop`.
  assert options.action.typ == actionDevelop,
         "This procedure must be called only on develop command."

proc updateDevelopFile*(dependentPkg: PackageInfo, options: Options): bool =
  ## Updates a dependent package `dependentPkg`'s develop file with an
  ## information from the Nimble's command line.
  ##   - Adds newly installed develop packages.
  ##   - Adds packages by path.
  ##   - Removes packages by path.
  ##   - Removes packages by name.
  ##   - Includes other develop files.
  ##   - Excludes other develop files.
  ##
  ## Returns `true` if all operations are successful and `false` otherwise.
  ## Raises if cannot load an existing develop file.

  options.assertDevelopActionIsSet
  dependentPkg.assertIsLoaded

  var
    hasError = false
    hasSuccessfulRemoves = false
    data = load(dependentPkg, options, true, true)

  defer:
    data.save(writeEmpty = hasSuccessfulRemoves, overwrite = true)

  for (actionType, argument) in options.action.devActions:
    case actionType
    of datNewFile:
      hasError = not createEmptyDevelopFile(argument, options) or hasError
    of datAdd:
      hasError = not data.addDevelopPackage(argument, options) or hasError
    of datRemoveByPath:
      hasSuccessfulRemoves = data.removeDevelopPackageByPath(argument) or
                             hasSuccessfulRemoves
    of datRemoveByName:
      hasSuccessfulRemoves = data.removeDevelopPackageByName(argument) or
                             hasSuccessfulRemoves
    of datInclude:
      hasError = not data.includeDevelopFile(argument, options) or hasError
    of datExclude:
      hasSuccessfulRemoves = data.excludeDevelopFile(argument) or
                             hasSuccessfulRemoves

  return not hasError

proc executeDevActionsAllowedOutsidePkgDir*(options: Options): bool =
  ## Executes develop command sub-commands allowed outside a valid package
  ## directory. Currently this is only `--create, -c` option for creating an
  ## empty develop file.

  options.assertDevelopActionIsSet

  var hasError = false
  for (actionType, argument) in options.action.devActions:
    case actionType
    of datNewFile:
      hasError = not createEmptyDevelopFile(argument, options) or hasError
    else:
      discard
  return not hasError

proc processDevelopDependencies*(dependentPkg: PackageInfo, options: Options):
    seq[PackageInfo] =
  ## Returns a sequence with the develop mode dependencies of the `dependentPkg`
  ## and recursively all of their develop mode dependencies.

  let data = load(dependentPkg, options, true, true)
  result = newSeqOfCap[PackageInfo](data.nameToPkg.len)
  for _, pkg in data.nameToPkg:
    result.add pkg[]

proc getDevelopDependencies*(dependentPkg: PackageInfo, options: Options):
    Table[string, ref PackageInfo] =
  ## Returns a table with a mapping between names and `PackageInfo`s of develop
  ## mode dependencies of package `dependentPkg` and recursively all of their
  ## develop mode dependencies.

  let data = load(dependentPkg, options, true, true)
  return data.nameToPkg

type
  ValidationErrorKind* = enum
    ## Types of possible errors when validating the develop file against the
    ## lock file with corresponding parts of their error messages.
    vekDirIsNotUnderVersionControl = "is not under version control."
    vekWorkingCopyIsNotClean       = "has not clean working copy."
    vekVcsRevisionIsNotPushed      = "has not pushed VCS revisions."
    vekWorkingCopyNeedsSync        = "has not synced working copy."
    vekWorkingCopyNeedsLock        = "has not locked commits."
    vekWorkingCopyNeedsMerge       = "has local changes which are in " &
                                     "conflict with the remote changes."

  ValidationErrorFlags = set[ValidationErrorKind]
    ## Set containing flags for the already met validation errors.

  ValidationError* = object
    ## Contains information for a validation error for some develop mode
    ## package.
    kind*: ValidationErrorKind
    path*: Path

  ValidationErrors* = Table[string, ValidationError]
    ## Mapping between package names and their validation errors info.

  NeedsOperation = enum
    ## Helper enum for the return type of the procedure determining whether a
    ## develop mode dependency working copy needs some operation to resolve the
    ## conflict between it and the lock file.
    needsNone, needsLock, needsSync, needsMerge

proc assertHasValidationErrors(errors: ValidationErrors) =
  assert errors.len > 0, "Must have validation errors."

proc getValidationErrorMessage*(name: string, error: ValidationError): string =
  ## By given validation error `error` constructs a validation error message for
  ## given develop mode dependency package with name `name`.
  &"Package \"{name}\" at \"{error.path}\" {error.kind}.\n"

proc getValidationErrorsMessage*(errors: ValidationErrors): string =
  ## Constructs an error message reporting develop mode dependencies validation
  ## errors.

  errors.assertHasValidationErrors
  result = "Some of package's develop mode dependencies are invalid.\n"
  for name, error in errors:
    result &= getValidationErrorMessage(name, error)

proc allAreSet(errorFlags: set[ValidationErrorKind]): bool =
  ## Checks whether all possible validation error flags are set.
  cast[uint](errorFlags) == uint(2'd ^ ValidationErrorKind.enumLen - 1)

proc getValidationsErrorsHint(errors: ValidationErrors): string =
  ## Constructs a hint message for resolving develop mode dependencies
  ## validation errors.

  errors.assertHasValidationErrors
  var errorFlags: ValidationErrorFlags

  for _, error in errors:
    case error.kind:
    of vekDirIsNotUnderVersionControl, vekWorkingCopyIsNotClean,
       vekVcsRevisionIsNotPushed:
      if error.kind notin errorFlags:
        result &=
          "When you are using a lock file Nimble requires develop mode " &
          "dependencies to be under version control, all local changes to be " &
          "committed and pushed on some remote, and lock file to be updated.\n"
    of vekWorkingCopyNeedsSync:
      if error.kind notin errorFlags:
        result &=
          "You have to call `nimble sync` to synchronize your develop mode " &
          "dependencies working copies with the latest lock file.\n"
    of vekWorkingCopyNeedsLock:
      if error.kind notin errorFlags:
        result &=
          "You have to call `nimble lock` to update your lock file with the " &
          "latest versions of your develop mode dependencies working copies.\n"
    of vekWorkingCopyNeedsMerge:
      if error.kind notin errorFlags:
        result &=
          "You have to merge or rebase working copies of your develop mode " &
          "dependencies which have conflicts with remote changes."

    errorFlags.incl error.kind
    if errorFlags.allAreSet: break

proc pkgDirIsNotUnderVersionControl(depPkg: PackageInfo): bool =
  ## Checks whether a develop mode dependency package directory is under version
  ## control.
  depPkg.getNimbleFileDir.getVcsType == vcsTypeNone

proc workingCopyIsNotClean(depPkg: PackageInfo): bool =
  ## Checks whether a working copy directory of a develop mode dependency
  ## package is clean. Untracked files are not considered.
  not depPkg.getNimbleFileDir.isWorkingCopyClean

proc vcsRevisionIsNotPushed(depPkg: PackageInfo): bool =
  ## Checks whether current VCS revision of the working copy directory of a
  ## develop mode dependency package is pushed on some remote.
  not depPkg.getNimbleFileDir.isVcsRevisionPresentOnSomeRemote(
    depPkg.vcsRevision)

proc workingCopyNeeds*(dependencyPkg, dependentPkg: PackageInfo,
                       options: Options): NeedsOperation =
  ## Be getting in consideration the information from the develop mode
  ## dependency working copy directory, the lock file and the sync file
  ## determines what kind of operation is needed to resolve the conflicts
  ## if any.

  let
    lockFileVcsRev = dependentPkg.lockedDeps.getOrDefault(
      dependencyPkg.name, notSetLockFileDep).vcsRevision
    syncFile = getSyncFile(dependentPkg)
    syncFileVcsRev = syncFile.getDepVcsRevision(dependencyPkg.name)
    workingCopyVcsRev = getVcsRevision(dependencyPkg.getNimbleFileDir)

  if lockFileVcsRev == syncFileVcsRev and syncFileVcsRev == workingCopyVcsRev:
    # When all revisions are matching nothing have to be done.
    return needsNone
  
  if lockFileVcsRev == syncFileVcsRev and syncFileVcsRev != workingCopyVcsRev:
    # When lock file and sync file revisions are matching, but working copy
    # revision is different, then most probably there are local changes and
    # `nimble lock` is needed.
    return needsLock

  if lockFileVcsRev != syncFileVcsRev and syncFileVcsRev == workingCopyVcsRev:
    # When lock file revision is different from sync file revision, but sync
    # file revision is equal to working copy revision then most probably we have
    # `pull` executed but we forgot to call `nimble sync`.
    return needsSync

  if lockFileVcsRev == workingCopyVcsRev and
     workingCopyVcsRev != syncFileVcsRev:
    # When lock file revision is equal to working copy revision, but they are
    # different from sync file revision, most probably this is because of
    # damaged sync file. Everything is Ok, because the sync file will be
    # rewritten on the next `nimble lock` or `nimble sync` command.
    return needsNone

  if lockFileVcsRev != syncFileVcsRev and
     lockFileVcsRev != workingCopyVcsRev and
     syncFileVcsRev != workingCopyVcsRev:
    # When all revisions are different from one another this indicates that
    # there are local changes which are conflicting with remote changes. The
    # user have to resolve them manually by merging or rebasing.
    return needsMerge

  assert false, "Here all cases are covered and the program " &
                "flow must not reach this assert."

  return needsNone

template addError(error: ValidationErrorKind) =
    errors[depPkg.name] = ValidationError(
      path: depPkg.getNimbleFileDir, kind: error)

proc findValidationErrorsOfDevDepsWithLockFile*(
    dependentPkg: PackageInfo, options: Options,
    errors: var ValidationErrors) =
  ## Collects validation errors for the develop mode dependencies with the
  ## content of the lock file by getting in consideration the information from
  ## the sync file. In the case of discrepancy, gives a useful advice what have
  ## to be done to resolve the conflicts for the not matching packages.

  dependentPkg.assertIsLoaded

  let developDependencies = processDevelopDependencies(dependentPkg, options)

  for depPkg in developDependencies:
    if depPkg.pkgDirIsNotUnderVersionControl:
      addError(vekDirIsNotUnderVersionControl)
    elif depPkg.workingCopyIsNotClean:
      addError(vekWorkingCopyIsNotClean)
    elif depPkg.vcsRevisionIsNotPushed:
      addError(vekVcsRevisionIsNotPushed)
    elif depPkg.workingCopyNeeds(dependentPkg, options) == needsSync:
      addError(vekWorkingCopyNeedsSync)
    elif depPkg.workingCopyNeeds(dependentPkg, options) == needsLock:
      addError(vekWorkingCopyNeedsLock)
    elif depPkg.workingCopyNeeds(dependentPkg, options) == needsMerge:
      addError(vekWorkingCopyNeedsMerge)

proc validationErrors*(errors: ValidationErrors): ref NimbleError =
  result = nimbleError(
    msg  = errors.getValidationErrorsMessage,
    hint = errors.getValidationsErrorsHint)

proc validateDevelopFileAgainstLockFile(
    dependentPkg: PackageInfo, options: Options) =
  ## Does validation of the develop file dependencies against the data written
  ## in the lock file.

  var errors: ValidationErrors

  findValidationErrorsOfDevDepsWithLockFile(dependentPkg, options, errors)
  if errors.len > 0:
    raise validationErrors(errors)

proc validateDevelopFile*(dependentPkg: PackageInfo, options: Options) =
  ## The procedure is used in the Nimble's `check` command to transitively
  ## validate the contents of the develop files.

  discard load(dependentPkg, options, true, true)
  if dependentPkg.areLockedDepsLoaded:
    validateDevelopFileAgainstLockFile(dependentPkg, options)