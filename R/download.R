#' A wrapper around a set of downloading functions
#'
#' Currently, this only deals with \code{\link[googledrive]{drive_download}},
#' and \code{\link[utils]{download.file}}.
#'
#' @inheritParams prepInputs
#' @inheritParams extractFromArchive
#' @importFrom Require normPath
#' @param dlFun Optional "download function" name, such as \code{"raster::getData"}, which does
#'              custom downloading, in addition to loading into R. Still experimental.
#' @param ... Passed to \code{dlFun}. Still experimental.
#' @param checksumFile A character string indicating the absolute path to the \code{CHECKSUMS.txt}
#'                     file.
#'
#' @inheritParams Cache
#' @author Eliot McIntire
#' @export
#' @include checksums.R
downloadFile <- function(archive, targetFile, neededFiles,
                         destinationPath = getOption("reproducible.destinationPath"), quick,
                         checksumFile, dlFun = NULL,
                         checkSums, url, needChecksums,
                         overwrite = getOption("reproducible.overwrite", TRUE),
                         verbose = getOption("reproducible.verbose", 1),
                         purge = FALSE, .tempPath, ...) {
  # browser(expr = exists("._downloadFile_1"))
  if (missing(.tempPath)) {
    .tempPath <- tempdir2(rndstr(1, 6))
    on.exit(unlink(.tempPath, recursive = TRUE), add = TRUE)
  }

  if (!is.null(url) || !is.null(dlFun)) {
    missingNeededFiles <- missingFiles(neededFiles, checkSums, targetFile)

    # if (is.null(neededFiles)) {
    #   result <- unique(checkSums$result)
    # } else {
    #   result <- checkSums[checkSums$expectedFile %in% neededFiles, ]$result
    # }
    # if (length(result) == 0) result <- NA
    #
    # missingNeededFiles <- (!(all(compareNA(result, "OK")) && all(neededFiles %in% checkSums$expectedFile)) ||
    #                          is.null(targetFile) || is.null(neededFiles))

    if (missingNeededFiles) { # needed may be missing, but maybe can skip download b/c archive exists
      if (!is.null(archive)) {
        localArchivesExist <- file.exists(archive)
        if (any(localArchivesExist)) {
          filesInLocalArchives <- unique(basename(unlist(lapply(archive, .listFilesInArchive))))
          if (all(neededFiles %in% filesInLocalArchives)) { # local archive has all files needed
            extractedFromArchive <- extractFromArchive(archive = archive[localArchivesExist],
                                                       destinationPath = destinationPath,
                                                       neededFiles = neededFiles, checkSums = checkSums,
                                                       needChecksums = needChecksums,
                                                       checkSumFilePath = checksumFile,
                                                       quick = quick,
                                                       .tempPath = .tempPath)
            checkSums <- if (!file.exists(checksumFile) || is.null(neededFiles)) {
              needChecksums <- 1
              .emptyChecksumsResult
            } else {
              Checksums(
                files = file.path(destinationPath, basename(neededFiles)),
                checksumFile = checksumFile,
                path = destinationPath,
                quickCheck = quick,
                write = FALSE,
                verbose = verbose
              )
            }

            # Check again, post extract ... If FALSE now, then it got it from local, already existing archive
            missingNeededFiles <- missingFiles(neededFiles, checkSums, targetFile)
            if (!missingNeededFiles) {
              archive <- archive[localArchivesExist]
            }
          }
        }
      }
    }

    if (missingNeededFiles) {
      if (needChecksums == 0) needChecksums <- 2 # use binary addition -- 1 is new file, 2 is append
    }

    # browser(expr = exists("._downloadFile_2"))

    if (missingNeededFiles) {
      fileToDownload <- if (is.null(archive[1])) {
        neededFiles
      } else {
        result <- checkSums[checkSums$expectedFile %in% basename(archive[1]), ]$result
        missingArchive <- !isTRUE(result == "OK")
        if (missingArchive) {
          archive[1]
        } else {
          NA # means nothing to download because the archive is already in hand
        }
      }
      skipDownloadMsg <- "Skipping download of url; local copy already exists and passes checksums"

      # The download step
      failed <- 1
      while (failed > 0  && failed < 4) {
        downloadResults <- try(downloadRemote(url = url, archive = archive, # both url and fileToDownload must be NULL to skip downloading
                                              targetFile = targetFile, fileToDownload = fileToDownload,
                                              skipDownloadMsg = skipDownloadMsg,
                                              checkSums = checkSums,
                                              dlFun = dlFun,
                                              destinationPath = destinationPath,
                                              overwrite = overwrite,
                                              needChecksums = needChecksums, verbose = verbose,
                                              .tempPath = .tempPath, ...))
        if (is(downloadResults, "try-error")) {
          if (isTRUE(grepl("already exists", downloadResults)))
            stop(downloadResults)
          failed <- failed + 1
          if (failed >= 4) {
            messCommon <- paste0("Download of ", targetFile, " from ", url, " failed. Please check the url that it is correct.\n",
                                         "If the url is correct, it is possible that manually downloading it will work. ",
                                         "To try this, with your browser, go to\n",
                                         url, ",\n ... then download it manually, give it this name: '", basename(fileToDownload),
                                         "', and place file here: ", destinationPath)
            if (isInteractive() && getOption('reproducible.interactiveOnDownloadFail', TRUE)) {
              mess <- paste0(messCommon,
                   ".\n ------- \nIf you have completed a manual download, press 'y' to continue; otherwise press any other key to stop now. ",
                   "\n(To prevent this behaviour in the future, set options('reproducible.interactiveOnDownloadFail' = FALSE)  )"
              )
              message(mess)
              resultOfPrompt <- .readline("Type y if you have attempted a manual download and put it in the correct place: ")
              resultOfPrompt <- tolower(resultOfPrompt)
              if (!identical(resultOfPrompt, "y")) {
                stop("Download failed")
              }
              downloadResults <- list(destFile = file.path(destinationPath, targetFile),
                                      needChecksums = 2)
            } else {
              stop(messCommon, ".\n-------------------\n",
                   "If manual download was successful, you will likely also need to run Checksums",
                   " manually after you download the file with this command: ",
                   "reproducible:::appendChecksumsTable(checkSumFilePath = '", checksumFile, "', filesToChecksum = '", targetFile,
                   "', destinationPath = '", dirname(checksumFile), "', append = TRUE)")
            }

          } else {
            Sys.sleep(0.5)
          }
        } else {
          if (is(downloadResults$out, "Spatial")) downloadResults$out <- NULL # TODO This appears to be a bug
          failed <- 0
        }
      }
      if (file.exists(checksumFile)) {
        if (is.null(fileToDownload) || tryCatch(is.na(fileToDownload), warning = function(x) FALSE))  { # This is case where we didn't know what file to download, and only now
          # do we know
          fileToDownload <- downloadResults$destFile
        }
        if (!is.null(fileToDownload)) {
          if ((length(readLines(checksumFile)) > 0)) {
            checkSums <-
              Checksums(
                files = file.path(destinationPath, basename(fileToDownload)),
                checksumFile = checksumFile,
                path = destinationPath,
                quickCheck = quick,
                write = FALSE,
                verbose = verbose
              )
            isOK <- checkSums[checkSums$expectedFile %in% basename(fileToDownload) |
                                checkSums$actualFile %in% basename(fileToDownload),]$result
            isOK <- isOK[!is.na(isOK)] == "OK"
            if (length(isOK) > 0) { # This is length 0 if there are no entries in the Checksums
              if (!isTRUE(all(isOK))) {
                if (purge > 0)  {
                  # This is case where we didn't know what file to download, and only now
                  # do we know
                  checkSums <- .purge(checkSums = checkSums,
                                      purge = purge,
                                      url = fileToDownload)
                  downloadResults$needChecksums <- 2
                } else {
                  tf <- tryCatch(
                    basename(targetFile) %in% fileToDownload,
                    error = function(x)
                      FALSE
                  )
                  af <- tryCatch(
                    basename(archive) %in% fileToDownload,
                    error = function(x)
                      FALSE
                  )

                  sc <- sys.calls()
                  piCall <- grep("^prepInputs", sc, value = TRUE)
                  purgeTry <- if (length(piCall)) {
                    gsub(piCall,
                         pattern = ")$",
                         replacement = paste0(", purge = 7)"))
                  } else {
                    ""
                  }
                  stop(
                    "\nDownloaded version of ",
                    normPath(fileToDownload),
                    " from url: ",
                    url,
                    " did not match expected file (checksums failed). There are several options:\n",
                    " 1) This may be an intermittent internet problem -- try to rerun this ",
                    "current function call.\n",
                    " 2) The local copy of the file may have been changed or corrupted -- run:\n",
                    "      file.remove('",
                    normPath(fileToDownload),
                    "')\n",
                    "      then rerun this current function call.\n",
                    " 3) The download is correct, and the Checksums should be rewritten for this file:\n",
                    "      --> rerun this current function call, specifying 'purge = 7' possibly\n",
                    "      ",
                    purgeTry,
                    call. = FALSE
                  )


                }
              } else if (isTRUE(all(isOK))) {
                downloadResults$needChecksums <- 0
              }
            }
          }
        }
      } # checksum file doesn't exist
    } else {
      # not missing any files to download
      fileAlreadyDownloaded <- if (is.null(archive[1])) {
        expectedFile <- checkSums[compareNA(checkSums$result, "OK"),]$expectedFile

        archivePossibly <- setdiff(expectedFile, neededFiles)
        archivePossibly <- .isArchive(archivePossibly)
        if (!is.null(archivePossibly)) {
          archivePossibly
        } else {
          neededFiles
        }

      } else {
        archive
      }

      downloadResults <- list(needChecksums = needChecksums,
                              destFile = file.path(destinationPath, basename(fileAlreadyDownloaded)))
      if (is.null(targetFile)) {
        messagePrepInputs("   Skipping download because all needed files are listed in ",
                "CHECKSUMS.txt file and are present.",
                " If this is not correct, rerun prepInputs with purge = TRUE", verbose = verbose)
      } else {
        if (exists("extractedFromArchive", inherits = FALSE)) {
          messagePrepInputs("  Skipping download: ", paste(neededFiles, collapse = ", ") ,
                  ": extracted from local archive:\n    ",
                  archive, verbose = verbose)
        } else {
          messagePrepInputs("  Skipping download: ", paste(neededFiles, collapse = ", ") ," already present", verbose = verbose)
        }
      }
    }
    archiveReturn <- if (is.null(archive)) {
      .isArchive(downloadResults$destFile)
    } else {
      archive
    }


    # This was commented out because of LandWeb -- removed b/c of this case:
    #  have local archive, but not yet have the targetFile
    # if (!is.null(downloadResults$destFile))
    #   neededFiles <- unique(basename(c(downloadResults$destFile, neededFiles)))
  } else {
    downloadResults <- list(needChecksums = needChecksums, destFile = NULL)
    archiveReturn <- archive
  }
  list(needChecksums = downloadResults$needChecksums, archive = archiveReturn,
       neededFiles = neededFiles,
       downloaded = downloadResults$destFile, checkSums = checkSums, object = downloadResults$out)
}

.getSourceURL <- function(pattern, x) {
  srcURL <- "sourceURL"
  grepIndex <- grep(srcURL, x = x)
  if (length(grepIndex) == 1) {
    .getSourceURL(pattern, x[[grepIndex]])
  } else if (length(grepIndex) > 1 | length(grepIndex) == 0) {
    y <- grep(pattern = basename(pattern), x)
    if (length(y) == 1) {
      urls <- if (length(grepIndex) > 1)
        eval(x[[y]])$sourceURL
      else
        eval(x)$sourceURL
    } else {
      stop("There is no sourceURL for an object named ", basename(pattern))
    }
  } else {
    stop("There is no sourceURL in module metadata")
  }
}

#' Download file from Google Drive
#'
#' @param url  The url (link) to the file.
#'
#' @author Eliot McIntire and Alex Chubaty
#' @keywords internal
#' @inheritParams preProcess
#'
dlGoogle <- function(url, archive = NULL, targetFile = NULL,
                     checkSums, skipDownloadMsg, destinationPath,
                     overwrite, needChecksums, verbose = getOption("reproducible.verbose", 1),
                     team_drive = NULL) {
  .requireNamespace("googledrive", stopOnFALSE = TRUE)

  if (missing(destinationPath)) {
    destinationPath <- tempdir2(rndstr(1, 6))
  }
  downloadFilename <- assessGoogle(url = url, archive = archive,
                                   targetFile = targetFile,
                                   destinationPath = destinationPath,
                                   verbose = verbose,
                                   team_drive = NULL)

  destFile <- file.path(destinationPath, basename(downloadFilename))
  if (!isTRUE(checkSums[checkSums$expectedFile ==  basename(destFile), ]$result == "OK")) {
    messagePrepInputs("  Downloading from Google Drive.", verbose = verbose)
    fs <- attr(archive, "fileSize")
    if (is.null(fs))
      fs <- attr(assessGoogle(url, verbose = verbose, team_drive = team_drive), "fileSize")
    if (!is.null(fs))
      class(fs) <- "object_size"

    isLargeFile <- ifelse(is.null(fs), FALSE, fs > 1e6)
    if (!isWindows() && requireNamespace("future", quietly = TRUE) && isLargeFile &&
        !.isFALSE(getOption("reproducible.futurePlan"))) {
      messagePrepInputs("Downloading a large file", verbose = verbose)
      fp <- future::plan()
      if (!is(fp, getOption("reproducible.futurePlan"))) {
        fpNew <- getOption("reproducible.futurePlan")
        future::plan(fpNew, workers = 2)
        on.exit({
          future::plan(fp)
        })
      }
      a <- future::future({
        googledrive::drive_deauth()
        retry(quote(googledrive::drive_download(googledrive::as_id(url), path = destFile,
                                                overwrite = overwrite, verbose = TRUE)))
        },
        globals = list(drive_download = googledrive::drive_download,
                       as_id = googledrive::as_id,
                       retry = retry,
                       drive_deauth = googledrive::drive_deauth,
                       url = url,
                       overwrite = overwrite,
                       destFile = destFile))
      cat("\n")
      notResolved <- TRUE
      while (notResolved) {
        Sys.sleep(0.05)
        notResolved <- !future::resolved(a)
        fsActual <- file.size(destFile)
        class(fsActual) <- "object_size"
        if (!is.na(fsActual))
          cat(format(fsActual, units = "auto"), "of", format(fs, units = "auto"),
              "downloaded         \r")
      }
      cat("\nDone!\n")
    } else {
      a <- retry(quote(googledrive::drive_download(googledrive::as_id(url), path = destFile,
                                                   overwrite = overwrite, verbose = TRUE))) ## TODO: unrecognized type "shp"
    }
  } else {
    messagePrepInputs(skipDownloadMsg, verbose = verbose)
    needChecksums <- 0
  }
  return(list(destFile = destFile, needChecksums = needChecksums))
}

#' Download file from generic source url
#'
#' @param url  The url (link) to the file.
#' @param needChecksums Logical indicating whether to generate checksums.
#'
#' ## TODO: add overwrite arg to the function?
#'
#' @author Eliot McIntire and Alex Chubaty
#' @keywords internal
#' @inheritParams preProcess
dlGeneric <- function(url, needChecksums, destinationPath, verbose = getOption("reproducible.verbose", 1)) {
  .requireNamespace("httr", stopOnFALSE = TRUE)
  if (missing(destinationPath)) {
    destinationPath <- tempdir2(rndstr(1, 6))
  }

  bn <- basename(url)
  bn <- gsub("\\?|\\&", "_", bn) # causes errors with ? and maybe &
  destFile <- file.path(destinationPath, bn)

  # if (suppressWarnings(httr::http_error(url))) ## TODO: http_error is throwing warnings
  #   stop("Can not access url ", url)

  messagePrepInputs("  Downloading ", url, " ...", verbose = verbose)

  ua <- httr::user_agent(getOption("reproducible.useragent"))
  request <- suppressWarnings(
    ## TODO: GET is throwing warnings
    httr::GET(url, ua, httr::progress(),
              httr::write_disk(destFile, overwrite = TRUE)) ## TODO: overwrite?
  )
  httr::stop_for_status(request)

  list(destFile = destFile, needChecksums = needChecksums)
}

#' @inheritParams prepInputs
downloadRemote <- function(url, archive, targetFile, checkSums, dlFun = NULL,
                           fileToDownload, skipDownloadMsg,
                           destinationPath, overwrite, needChecksums, .tempPath,
                           verbose = getOption("reproducible.verbose", 1), ...) {
  # browser(expr = exists("._downloadRemote_1"))
  if (missing(.tempPath)) {
    .tempPath <- tempdir2(rndstr(1, 6))
    on.exit({unlink(.tempPath, recursive = TRUE)},
            add = TRUE)
  }

  dots <- list(...)

  if (!is.null(url) || !is.null(dlFun)) { # if no url, no download
    #if (!is.null(fileToDownload)  ) { # don't need to download because no url --- but need a case
      if (!isTRUE(tryCatch(is.na(fileToDownload), warning = function(x) FALSE)))  {
        ## NA means archive already in hand
        if (!is.null(dlFun)) {
          dlFunName <- dlFun
          dlFun <- .extractFunction(dlFun)
          fun <- .fnCleanup(dlFun, callingFun = "downloadRemote")
          forms <- .argsToRemove
          #dots <- list(...)
          overlappingForms <- fun$formalArgs[fun$formalArgs %in% forms]
          overlappingForms <- grep("\\.\\.\\.", overlappingForms, invert = TRUE, value = TRUE)

          # remove arguments that are in .argsToRemove, i.e., the sequence
          args <- if (length(overlappingForms)) {
            append(list(...), mget(overlappingForms))
          } else {
            list(...)
          }
          args <- args[!names(args) %in% forms]
          if (is.null(targetFile)) {
            fileInfo <- file.info(dir(destinationPath))
          }
          # browser(expr = exists("._downloadRemote_1"))
          out <- do.call(dlFun, args = args)
          needSave <- TRUE
          if (is.null(targetFile)) {
            fileInfoAfter <- file.info(dir(destinationPath))
            possibleTargetFile <- setdiff(rownames(fileInfoAfter), rownames(fileInfo))
            if (length(possibleTargetFile)) {
              destFile <- targetFile <- possibleTargetFile
              needSave <- FALSE
            } else {
              destFile <- normPath(file.path(destinationPath, basename(tempfile(fileext = ".rds"))))
            }
          } else {
            destFile <- normPath(file.path(destinationPath, targetFile))
          }

          # some functions will load the object, not just download them, since we may not know
          #   where the function actually downloaded the file, we save it as an RDS file
          if (needSave) {
            if (!file.exists(destFile))
              saveRDS(out, file = destFile)
          }
          downloadResults <- list(out = out, destFile = normPath(destFile), needChecksums = 2)
        } else if (grepl("drive.google.com", url)) {
          #browser(expr = exists("._downloadRemote_2"))
          if (!requireNamespace("googledrive", quietly = TRUE))
            stop(requireNamespaceMsg("googledrive", "to use google drive files"))

          downloadResults <- dlGoogle(
            url = url,
            archive = archive,
            targetFile = targetFile,
            checkSums = checkSums,
            skipDownloadMsg = skipDownloadMsg,
            destinationPath = .tempPath,
            overwrite = overwrite,
            needChecksums = needChecksums,
            verbose = verbose,
            team_drive = dots[["team_drive"]]
          )

        } else if (grepl("dl.dropbox.com", url)) {
          stop("Dropbox downloading is currently not supported")
        } else if (grepl("onedrive.live.com", url)) {
          stop("Onedrive downloading is currently not supported")
        } else {
          downloadResults <- dlGeneric(url = url, needChecksums = needChecksums,
                                       destinationPath = .tempPath)
        }
        # if destinationPath is tempdir, then don't copy and remove

        # Don't use .tempPath directly because of non-google approaches too
        if (!(identical(dirname(normPath(downloadResults$destFile)), normPath(destinationPath)))) {
          desiredPath <- normPath(file.path(destinationPath, basename(downloadResults$destFile)))

          desiredPathExists <- file.exists(desiredPath)
          if (desiredPathExists && !isTRUE(overwrite)) {

            stopMess <- paste(desiredPath, " already exists and overwrite = FALSE; would you like to overwrite anyway? Y or N:  ")
            if (interactive()) {
              interactiveRes <- readline(stopMess)
              if (startsWith(tolower(interactiveRes), "y"))
                overwrite = TRUE
            }
            if (!identical(overwrite, TRUE)) {
              stop(targetFile, " already exists at ", desiredPath, ". Use overwrite = TRUE?")
            }
          }
          if (desiredPathExists) {
            file.remove(desiredPath)
          }

          # Try hard link first -- the only type that R deeply recognizes
          # if that fails, fall back to copying the file.
          # NOTE: never use symlink because the original will be deleted.
          result <- hardLinkOrCopy(downloadResults$destFile, desiredPath)

          # result <- suppressWarningsSpecific(
          #   file.link(downloadResults$destFile, desiredPath),
          #   falseWarnings = "already exists|Invalid cross-device")
          # # result <- suppressWarnings(
          # #   file.link(downloadResults$destFile, desiredPath)
          # # )
          #
          # if (.isFALSE(result)) {
          #   result <- file.copy(downloadResults$destFile, desiredPath)
          # }

          tmpFile <- downloadResults$destFile
          downloadResults$destFile <- file.path(destinationPath, basename(downloadResults$destFile))
        }
      #}
    } else {
      messagePrepInputs(skipDownloadMsg, verbose = verbose)
      downloadResults <- list(needChecksums = 0, destFile = NULL)
    }
  } else {
    messagePrepInputs("No downloading; no url", verbose = verbose)
  }
  downloadResults
}

missingFiles <- function(files, checkSums, targetFile) {
  if (is.null(files)) {
    result <- unique(checkSums$result)
  } else {
    result <- checkSums[checkSums$expectedFile %in% files, ]$result
  }
  if (length(result) == 0) result <- NA

  (!(all(compareNA(result, "OK")) && all(files %in% checkSums$expectedFile)) ||
      #                     is.null(targetFile) ||
      is.null(files))
}

assessGoogle <- function(url, archive = NULL, targetFile = NULL,
                         destinationPath = getOption("reproducible.destinationPath"),
                         verbose = getOption("reproducible.verbose", 1),
                         team_drive = NULL) {
  if (!requireNamespace("googledrive", quietly = TRUE))
    stop(requireNamespaceMsg("googledrive", "to use google drive files"))
  if (.isRstudioServer()) {
    .requireNamespace("httr", stopOnFALSE = TRUE)
    opts <- options(httr_oob_default = TRUE)
    on.exit(options(opts))
  }

  if (is.null(archive)) {
    fileAttr <- retry(quote(googledrive::drive_get(googledrive::as_id(url), team_drive = team_drive)))
    fileSize <- fileAttr$drive_resource[[1]]$size ## TODO: not returned with team drive (i.e., NULL)
    if (!is.null(fileSize)) {
      fileSize <- as.numeric(fileSize)
      class(fileSize) <- "object_size"
      messagePrepInputs("  File on Google Drive is ", format(fileSize, units = "auto"), verbose = verbose)
    }
    archive <- .isArchive(fileAttr$name)
    if (is.null(archive)) {
      if (is.null(targetFile)) {
        # make the guess
        targetFile <- fileAttr$name
      }
      downloadFilename <- targetFile # override if the targetFile is not an archive
    } else {
      archive <- file.path(destinationPath, basename(archive))
      downloadFilename <- archive
    }
  } else {
    downloadFilename <- archive
  }
  if (exists("fileSize", inherits = FALSE)) {
    setattr(downloadFilename, name = "fileSize", value = fileSize)
  }
  return(downloadFilename)
}

requireNamespaceMsg <- function(pkg, extraMsg = character(), minVersion = NULL) {
  mess <- paste0(pkg, if (!is.null(minVersion))
    paste0("(>=", minVersion, ")"), " is required but not yet installed. Try: ",
    "install.packages('",pkg,"')")
  if (length(extraMsg) > 0)
    mess <- paste(mess, extraMsg)
  mess
}

.isRstudioServer <- function() {
  isRstudioServer <- FALSE

  if (isTRUE("tools:rstudio" %in% search())) { ## running in Rstudio
    rsAPIFn <- get(".rs.api.versionInfo", as.environment("tools:rstudio"))
    versionInfo <- rsAPIFn()
    if (!is.null(versionInfo)) {
      isRstudioServer <- identical("server", versionInfo$mode)
    }
  }
  isRstudioServer
}
