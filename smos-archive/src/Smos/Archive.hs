{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Smos.Archive
  ( smosArchive
  , module Smos.Archive.Config
  ) where

import Data.Time
import Data.Tree

import System.Exit

import Path
import Path.IO

import Smos.Archive.Config
import Smos.Archive.OptParse
import Smos.Archive.OptParse.Types
import Smos.Data

import Smos.Archive.Prompt

smosArchive :: SmosArchiveConfig -> IO ()
smosArchive = runReaderT $ liftIO getSettings >>= archive

archive :: Settings -> Q ()
archive Settings {..} = do
  let from = setFile
  to <- determineToFile from
  liftIO $ do
    checkFromFile from
    moveToArchive from to

determineToFile :: Path Abs File -> Q (Path Abs File)
determineToFile file = do
  workflowDir <- askWorkflowDir
  case stripProperPrefix workflowDir file of
    Nothing ->
      liftIO $
      die $
      unlines
        [ "The smos file"
        , fromAbsFile file
        , "is not in the smos workflow directory"
        , fromAbsDir workflowDir
        ]
    Just rf -> do
      archiveDir <- askArchiveDir
      let ext = fileExtension rf
      withoutExt <- setFileExtension "" rf
      today <- liftIO $ utctDay <$> getCurrentTime
      let newRelFile = fromRelFile withoutExt ++ "_" ++ formatTime defaultTimeLocale "%F" today
      arf' <- parseRelFile newRelFile
      arf'' <- setFileExtension ext arf'
      pure $ archiveDir </> arf''

checkFromFile :: Path Abs File -> IO ()
checkFromFile from = do
  mErrOrSF <- readSmosFile from
  case mErrOrSF of
    Nothing -> die $ unwords ["File does not exist:", fromAbsFile from]
    Just (Left e) ->
      die $ unlines [unwords ["Failed to read file to archive:", fromAbsFile from], e]
    Just (Right sf) ->
      unless (all (isDone . entryState) (concatMap flatten (smosFileForest sf))) $ do
        res <-
          promptYesNo No $
          unwords
            [ "Not all entries in"
            , fromAbsFile from
            , "are done. Are you sure that you want to archive it?"
            ]
        case res of
          Yes -> pure ()
          No -> die "Not archiving."

isDone :: Maybe TodoState -> Bool
isDone (Just "DONE") = True
isDone (Just "CANCELLED") = True
isDone (Just "FAILED") = True
isDone _ = True

moveToArchive :: Path Abs File -> Path Abs File -> IO ()
moveToArchive from to = do
  ensureDir $ parent to
  mErrOrSmosFile <- readSmosFile from
  case mErrOrSmosFile of
    Nothing -> die $ unwords ["The file to archive does not exist:", fromAbsFile from]
    Just (Left err) -> die $ unlines ["The file to archive doesn't look like a smos file:", err]
    Just (Right sf) -> do
      e2 <- doesFileExist to
      if e2
        then die $ unwords ["Proposed archive file", fromAbsFile to, "already exists."]
        else do
          now <- liftIO getCurrentTime
          let archivedSmosFile = prepareToArchive now sf
          writeSmosFile to archivedSmosFile
          removeFile from

prepareToArchive :: UTCTime -> SmosFile -> SmosFile
prepareToArchive = smosFileClockOutEverywhere
