{-|

Helpers for the /security-advisories/ file system.

Top-level functions that take a @FilePath@ expect the path to the
top-level directory of the /security-advisories/ repository (i.e.
it must have the @advisories/@ subdirectory).

-}
module Security.Advisories.Filesystem
  (
    dirNameAdvisories
  , dirNameReserved
  , isSecurityAdvisoriesRepo
  , getReservedIds
  , getAdvisoryIds
  , getAllocatedIds
  , greatestId
  , getGreatestId
  , forReserved
  , forAdvisory
  ) where

import Control.Applicative (liftA2)
import Data.Foldable (fold)
import Data.Semigroup (Max(Max, getMax))
import Data.Traversable (for)

import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Writer.Strict (execWriterT, tell)
import System.FilePath ((</>), takeBaseName)
import System.Directory (doesDirectoryExist)
import System.Directory.PathWalk

import Security.Advisories.HsecId (HsecId, parseHsecId, placeholder)


dirNameAdvisories :: FilePath
dirNameAdvisories = "advisories"

dirNameReserved :: FilePath
dirNameReserved = "reserved"

-- | Check whether the directory appears to be the root of a
-- /security-advisories/ filesystem.  Only checks that the
-- @advisories@ subdirectory exists.
--
isSecurityAdvisoriesRepo :: FilePath -> IO Bool
isSecurityAdvisoriesRepo path =
  doesDirectoryExist (path </> dirNameAdvisories)


-- | Get a list of reserved HSEC IDs.  The order is unspecified.
--
getReservedIds :: FilePath -> IO [HsecId]
getReservedIds root =
  forReserved root (\_ hsid -> pure [hsid])

-- | Get a list of used IDs (does not include reserved IDs)
-- There may be duplicates and the order is unspecified.
--
getAdvisoryIds :: FilePath -> IO [HsecId]
getAdvisoryIds root =
  forAdvisory root (\_ hsid -> pure [hsid])

-- | Get all allocated IDs, including reserved IDs.
-- There may be duplicates and the order is unspecified.
--
getAllocatedIds :: FilePath -> IO [HsecId]
getAllocatedIds root =
  liftA2 (<>)
    (getAdvisoryIds root)
    (getReservedIds root)

-- | Return the greatest ID in a collection of IDs.  If the
-- collection is empty, return the 'placeholder'.
--
greatestId :: (Foldable t) => t HsecId -> HsecId
greatestId = getMax . foldr ((<>) . Max) (Max placeholder)

-- | Return the greatest ID in the database, including reserved IDs.
-- If there are IDs in the database, returns the 'placeholder'.
--
getGreatestId :: FilePath -> IO HsecId
getGreatestId = fmap greatestId . getAllocatedIds


-- | Invoke a callback for each HSEC ID in the reserved
-- directory.  The results are combined monoidally.
--
forReserved
  :: (MonadIO m, Monoid r)
  => FilePath -> (FilePath -> HsecId -> m r) -> m r
forReserved root =
  _forFiles (root </> dirNameAdvisories </> dirNameReserved)

-- | Invoke a callback for each HSEC ID under each of the advisory
-- subdirectories, excluding the @reserved@ directory.  The results
-- are combined monoidally.
--
-- The same ID could appear multiple times.  In particular, the callback
-- is invoked for symbolic links as well as regular files.
--
forAdvisory
  :: (MonadIO m, Monoid r)
  => FilePath -> (FilePath -> HsecId -> m r) -> m r
forAdvisory root go = do
  let dir = root </> dirNameAdvisories
  subdirs <- filter (/= dirNameReserved) <$> _getSubdirs dir
  fmap fold $ for subdirs $ \subdir -> _forFiles (dir </> subdir) go

-- | Get names (not paths) of subdirectories of the given directory
-- (one level).  There's no monoidal, interruptible variant of
-- @pathWalk@ so we use @WriterT@ to smuggle the result out.
--
_getSubdirs :: (MonadIO m) => FilePath -> m [FilePath]
_getSubdirs root =
  execWriterT $
    pathWalkInterruptible root $ \_ subdirs _ -> do
      tell subdirs
      pure Stop

_forFiles
  :: (MonadIO m, Monoid r)
  => FilePath  -- ^ (sub)directory name
  -> (FilePath -> HsecId -> m r)
  -> m r
_forFiles root go =
  pathWalkAccumulate root $ \_ _ files ->
    fmap fold $ for files $ \file ->
      case parseHsecId (takeBaseName file) of
        Nothing -> pure mempty
        Just hsid -> go (root </> file) hsid
