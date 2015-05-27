{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveDataTypeable #-}

-- TODO: use Network.HTTP.Download
module Stack.Setup
  ( setupEnv
  ) where

-- Copied imports from stackage-setup
---------------------------------------------------------------------
-- import Control.Applicative ((<$>), (<*))
import Control.Exception (Exception)
import Control.Exception.Enclosed (handleIO)
import Control.Monad (liftM, when)
import Control.Monad.Catch (MonadThrow, throwM, MonadMask)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, ReaderT (..))
-- import Control.Monad.Trans.Control (MonadBaseControl)
-- import Control.Monad.Trans.Resource (runResourceT)
-- import Crypto.Hash
-- import Crypto.Hash.Conduit (sinkHash)
-- import Data.Aeson (FromJSON(..), withObject, (.:), (.:?), (.!=))
-- import qualified Data.Aeson as Aeson
-- import Data.ByteString (ByteString)
-- import qualified Data.ByteString as S
-- import qualified Data.ByteString.Lazy as LByteString
-- import qualified Data.Char as Char
import Data.Conduit (($$))
import qualified Data.Conduit.List as CL
import Control.Applicative ((<$>), (<*>))
import Data.Aeson
import Data.Word (Word)
-- import Data.Conduit.Binary (sinkFile)
-- import Data.Foldable (forM_)
-- import Data.HashMap.Strict (HashMap)
-- import qualified Data.HashMap.Strict as HashMap
import qualified Data.List as List
import Data.Monoid
import qualified Data.Yaml as Yaml
import Data.Text (Text)
-- import qualified Data.Text as Text
-- import qualified Data.Text.Lazy as LText
-- import qualified Data.Text.Lazy.Encoding as LText
import Data.Typeable (Typeable)
-- import qualified Data.Yaml as Yaml
import Network.HTTP.Client.Conduit
-- import Network.HTTP.Client.TLS (tlsManagerSettings)
-- import Network.HTTP.Types (hUserAgent)
import System.Directory
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (searchPathSeparator)
-- import System.Environment (lookupEnv, setEnv)
-- import System.Exit (exitFailure)
-- import System.IO (stderr, hPutStrLn)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (rawSystem)
-- import System.Process (callProcess, readProcess)

-- Imports and new definitions for Stack.Setup
-------------------------------------------------------------------
import Stack.Types

import Distribution.System (OS (..), Arch (..), buildOS, buildArch)
-- -- import Control.Monad.Reader (asks)
import           Stack.Build.Types
import qualified Data.ByteString.Char8 as S8
-- -- import qualified Stack.Types as Stack
import Path (Path, Abs, Dir, parseRelDir, parseAbsDir, mkRelFile)
import qualified Path
import Control.Monad.Logger
import qualified Data.Text as T
import Data.List (intercalate)
import Path (toFilePath)
import qualified Data.Map as Map
import Data.Map (Map)
import qualified Data.Set as Set
import Data.Set (Set)
import System.Process.Read hiding (callProcess) -- FIXME don't hide
import Stack.GhcPkg
import qualified System.FilePath as FP
import Data.Maybe (catMaybes, listToMaybe)
import Data.List (sortBy)
import Data.Ord (comparing)
import Network.HTTP.Download (download)

data DownloadPair = DownloadPair Version Text
instance FromJSON DownloadPair where
    parseJSON = withObject "DownloadPair" $ \o -> DownloadPair
        <$> o .: "version"
        <*> o .: "url"

data MajorVersion = MajorVersion !Word !Word
    deriving (Typeable, Eq, Ord)
instance Show MajorVersion where
    show (MajorVersion x y) = concat [show x, ".", show y]
instance FromJSON a => FromJSON (Map MajorVersion a) where
    parseJSON val = do
        m <- parseJSON val
        fmap Map.fromList $ mapM go $ Map.toList m
      where
        go (k, v) = do
            (x, y) <- either (fail . show) (return . getMajorVersion)
                    $ parseVersionFromString k
            return (MajorVersion x y, v)

data SetupInfo = SetupInfo
    { siSevenzExe :: Text
    , siSevenzDll :: Text
    , siPortableGit :: DownloadPair
    , siGHCs :: Map Text (Map MajorVersion DownloadPair)
    }
instance FromJSON SetupInfo where
    parseJSON = withObject "SetupInfo" $ \o -> SetupInfo
        <$> o .: "sevenzexe"
        <*> o .: "sevenzdll"
        <*> o .: "portable-git"
        <*> o .: "ghc"

-- | Download the most recent SetupInfo
getSetupInfo :: (MonadIO m, MonadThrow m) => Manager -> m SetupInfo
getSetupInfo manager = do
    bss <- liftIO $ flip runReaderT manager
         $ withResponse req $ \res -> responseBody res $$ CL.consume
    let bs = S8.concat bss
    either throwM return $ Yaml.decodeEither' bs
  where
    req = "https://raw.githubusercontent.com/fpco/stackage-content/master/stack/stack-setup.yaml"

-- | Modify the environment variables (like PATH) appropriately, possibly doing installation too
setupEnv :: (MonadIO m, MonadMask m, MonadLogger m)
         => Bool -- ^ install GHC if missing?
         -> Manager
         -> BuildConfig
         -> m BuildConfig
setupEnv installIfMissing manager bconfig = do
    -- Check the available GHCs
    let menv0 = configEnvOverride (bcConfig bconfig) EnvSettings
            { esIncludeLocals = False
            , esIncludeGhcPackagePath = False
            }
        expected = bcGhcVersion bconfig
    minstalled <- getInstalledGHC menv0
    let needLocal = case minstalled of
            Nothing -> True
            Just installed ->
                -- we allow a newer version of GHC within the same major series
                getMajorVersion installed /= getMajorVersion expected ||
                expected > installed

    -- If we need to install a GHC, try to do so
    mghcBin <- if needLocal
        then do
            $logDebug "Looking for a local copy of GHC"
            mghcBin <- getLocalGHC bconfig expected
            case mghcBin of
                Just ghcBin -> do
                    $logDebug $ "Local copy found at: " <> T.intercalate ", " (map T.pack ghcBin)
                    return $ Just ghcBin
                Nothing
                    | installIfMissing -> do
                        $logDebug $ "None found, installing: " <> versionText expected
                        ghcBin <- installLocalGHC manager bconfig expected
                        return $ Just ghcBin
                    | otherwise ->
                        throwM $ GHCVersionMismatch minstalled (bcGhcVersion bconfig)
        else return Nothing

    -- Modify the initial environment to include the GHC path, if a local GHC
    -- is being used
    let env0 = case (menv0, mghcBin) of
            (EnvOverride x, Nothing) -> x
            (EnvOverride x, Just ghcBin) ->
                let mpath = Map.lookup "PATH" x
                    path = T.intercalate (T.singleton searchPathSeparator)
                        $ map T.pack ghcBin ++ maybe [] return mpath
                 in Map.insert "PATH" path x

    -- extra installation bin directories
    mkDirs <- runReaderT extraBinDirs bconfig
    let mpath = Map.lookup "PATH" env0
        depsPath = mkPath (mkDirs False) mpath
        localsPath = mkPath (mkDirs True) mpath

    deps <- runReaderT packageDatabaseDeps bconfig
    depsExists <- liftIO $ doesDirectoryExist $ toFilePath deps
    localdb <- runReaderT packageDatabaseLocal bconfig
    localdbExists <- liftIO $ doesDirectoryExist $ toFilePath localdb
    global <- getGlobalDB $ EnvOverride $ Map.insert "PATH" depsPath env0
    let mkGPP locals = T.pack $ intercalate [searchPathSeparator] $ concat
            [ [toFilePath localdb | locals && localdbExists]
            , [toFilePath deps | depsExists]
            , [toFilePath global]
            ]

    let mkEnvOverride es = EnvOverride
            $ Map.insert "PATH" (if esIncludeLocals es then localsPath else depsPath)
            $ (if esIncludeGhcPackagePath es
                    then Map.insert "GHC_PACKAGE_PATH" (mkGPP (esIncludeLocals es))
                    else id)
            $ Map.insert "HASKELL_PACKAGE_SANDBOX"
                (T.pack $ if esIncludeLocals es
                    {- This is what we'd ideally want to provide, but
                     - HASKELL_PACKAGE_SANDBOX isn't set up to respect it. Need
                     - to figure out a better solution, maybe creating a
                     - combined database and passing that in?
                    then intercalate [searchPathSeparator]
                            [ toFilePath localdb
                            , toFilePath deps
                            ]
                    -}
                    then toFilePath localdb
                    else toFilePath deps)
            $ env0
    return bconfig { bcConfig = (bcConfig bconfig) { configEnvOverride = mkEnvOverride } }
  where
    mkPath dirs mpath = T.pack $ intercalate [searchPathSeparator]
        (map toFilePath dirs ++ maybe [] (return . T.unpack) mpath)

-- | Get the major version of the installed GHC, if available
getInstalledGHC :: (MonadIO m) => EnvOverride -> m (Maybe Version)
getInstalledGHC menv = do
    exists <- doesExecutableExist menv "ghc"
    if exists
        then do
            eres <- liftIO $ tryProcessStdout menv "ghc" ["--numeric-version"]
            return $ do
                Right bs <- Just eres
                parseVersion $ S8.takeWhile isValidChar bs
        else return Nothing
  where
    isValidChar '.' = True
    isValidChar c = '0' <= c && c <= '9'

-- | Get the bin directory for a local copy of GHC meeting the given version
-- requirement, if it exists
getLocalGHC :: (HasConfig config, MonadIO m, MonadLogger m, MonadThrow m)
            => config
            -> Version
            -> m (Maybe [FilePath])
getLocalGHC config' expected = do
    let dir = toFilePath $ configLocalGHCs $ getConfig config'
    contents <- liftIO $ handleIO (const $ return []) (getDirectoryContents dir)
    pairs <- liftIO $ fmap catMaybes $ mapM (toMaybePair dir) contents
    case listToMaybe $ reverse $ map snd $ sortBy (comparing fst) pairs of
        Nothing -> return Nothing
        Just (ghcDir, ghcBin) ->
            case buildOS of
                Windows -> do
                    gitDirs' <- getGitDirs Nothing dir contents
                    return $ Just
                        $ ghcBin
                        : (ghcDir FP.</> "mingw" FP.</> "bin")
                        : gitDirs'
                _ -> return $ Just [ghcBin]
  where
    expectedMajor = getMajorVersion expected
    toMaybePair root name
        | Just noGhc <- List.stripPrefix "ghc-" name
        , Just version <- parseVersionFromString noGhc
        , getMajorVersion version == expectedMajor
        , version >= expected = do
            let dir = root FP.</> name
                bin = dir FP.</> "bin"
                ghc = bin FP.</> "ghc" ++ exeSuffix
            exists <- doesFileExist ghc
            return $ if exists
                then Just (version, (dir, bin))
                else Nothing
        | otherwise = return Nothing

    exeSuffix =
        case buildOS of
            Windows -> ".exe"
            _ -> ""

-- | Get the installation directories for Git on Windows
getGitDirs :: (MonadIO m, MonadLogger m, MonadThrow m)
           => Maybe (SetupInfo, Manager) -- ^ Just if we want to setup
           -> FilePath -- ^ root installation directory
           -> [FilePath] -- ^ contents of that directory
           -> m [FilePath] -- ^ extra directories for the PATH
getGitDirs mSetup root contents = do
    pairs <- liftM catMaybes $ mapM toMaybePair contents
    case listToMaybe $ reverse $ map snd $ sortBy (comparing fst) pairs of
        Just dirs -> return dirs
        Nothing -> case mSetup of
            Just (si, manager) -> setupGit si manager root
            Nothing -> do
                $logWarn "Using local GHC installation, but no local Git available"
                return []
  where
    toMaybePair name
        | Just noGit <- List.stripPrefix "git-" name
        , Just version <- parseVersionFromString noGit = do
            let dir = root FP.</> name
                dirs = gitDirs dir
            exists <- liftIO $ doesDirectoryExist $ head dirs
            return $ if exists
                then Just (version, gitDirs dir)
                else Nothing
        | otherwise = return Nothing

-- | Install a local copy of GHC in the given major version with at least the
-- given version. In other words, if 7.8.3 is specified, 7.8.4 may be selected.
-- Return the bin directory.
installLocalGHC :: (MonadIO m, MonadLogger m, HasConfig env, MonadThrow m, MonadMask m)
                => Manager -> env -> Version -> m [FilePath]
installLocalGHC manager config' version = do
    rel <- parseRelDir $ "ghc-" <> versionString version
    let dest = configLocalGHCs (getConfig config') Path.</> rel
    si <- getSetupInfo manager
    $logDebug $ "Attempting to install GHC " <> versionText version <>
                " to " <> T.pack (toFilePath dest)
    flip runReaderT config' $ case (buildOS, buildArch) of
        (Linux, X86_64) -> posix si "linux64" manager version dest
        (Windows, _) -> windows si manager version dest (configLocalGHCs $ getConfig config')
        (os, arch) -> throwM $ UnsupportedSetupCombo os arch

data SetupException = UnsupportedSetupCombo OS Arch
                    | MissingDependencies [String]
                    | UnknownGHCVersion Version (Set MajorVersion)
                    | UnknownOSKey Text
    deriving Typeable
instance Exception SetupException
instance Show SetupException where
    show (UnsupportedSetupCombo os arch) = concat
        [ "I don't know how to install GHC for "
        , show (os, arch)
        , ", please install manually"
        ]
    show (MissingDependencies tools) =
        "The following executables are missing and must be installed:" ++
        intercalate ", " tools
    show (UnknownGHCVersion version known) = concat
        [ "No information found for GHC version "
        , versionString version
        , ". Known GHC major versions: "
        , intercalate ", " (map show $ Set.toList known)
        ]
    show (UnknownOSKey oskey) =
        "Unable to find installation URLs for OS key: " ++
        T.unpack oskey

-- | Get the DownloadPair for the given OS and GHC version
getGHCPair :: MonadThrow m
           => SetupInfo
           -> Text -- ^ OS key
           -> Version -- ^ GHC version
           -> m DownloadPair
getGHCPair si osKey version =
    case Map.lookup osKey $ siGHCs si of
        Nothing -> throwM $ UnknownOSKey osKey
        Just m ->
            case Map.lookup major m of
                Nothing -> throwM $ UnknownGHCVersion version (Map.keysSet m)
                Just pair -> return pair
  where
    (x, y) = getMajorVersion version
    major = MajorVersion x y

-- | Install GHC for 64-bit Linux
posix :: (MonadIO m, MonadLogger m, MonadReader env m, HasConfig env, MonadThrow m, MonadMask m)
      => SetupInfo
      -> Text -- ^ OS key
      -> Manager
      -> Version
      -> Path Abs Dir
      -> m [FilePath]
posix si osKey manager reqVersion dest = do
    menv <- getMinimalEnvOverride
    checkDependencies ["make", "tar", "xz"]
    DownloadPair version url <- getGHCPair si osKey reqVersion
    let dirPiece = "ghc-" <> versionString version
    req <- parseUrl $ T.unpack url
    withSystemTempDirectory "stack-setup" $ \root' -> do
        root <- parseAbsDir root'
        let file = root Path.</> $(mkRelFile "ghc.tar.xz")
        dir <- liftM (root Path.</>) $ parseRelDir dirPiece
        $logInfo $ "Downloading from: " <> url
        runReaderT (download req file) manager
        $logInfo "Unpacking"
        runIn root "tar" menv ["xf", toFilePath file] Nothing
        $logInfo "Configuring"
        runIn dir "./configure" menv ["--prefix=" ++ toFilePath dest] Nothing
        $logInfo "Installing"
        runIn dir "make" menv ["install"] Nothing
        $logInfo "GHC installed!"
    return [toFilePath dest FP.</> "bin"]

-- | Download 7z as necessary, and get a function for unpacking things.
--
-- Returned function takes an unpack directory and archive.
setup7z :: (MonadReader env m, HasHttpManager env, MonadThrow m, MonadIO m, MonadIO n)
        => SetupInfo
        -> FilePath -- ^ install root (Programs\)
        -> m (FilePath -> FilePath -> n ())
setup7z si root = do
    go (siSevenzDll si) dll
    go (siSevenzExe si) exe
    return $ \outdir archive -> liftIO $ do
        ec <- rawSystem exe
            [ "x"
            , "-o" ++ outdir
            , "-y"
            , archive
            ]
        when (ec /= ExitSuccess)
            $ error $ "Problem while decompressing " ++ archive
  where
    dir = root FP.</> "7z"

    go url fp = do
        path <- Path.parseAbsFile fp
        req <- parseUrl $ T.unpack url
        download req path

    exe = dir FP.</> "7z.exe"
    dll = dir FP.</> "7z.dll"

-- | Install PortableGit and get a list of directories to add to PATH
setupGit :: (MonadLogger m, MonadThrow m, MonadIO m)
         => SetupInfo
         -> Manager
         -> FilePath -- ^ root to install into (Programs\)
         -> m [FilePath]
setupGit si manager root = do
    $logInfo "Downloading PortableGit"
    run7z <- runReaderT (setup7z si root) manager
    req <- parseUrl $ T.unpack url
    dest <- Path.parseAbsFile $ dir FP.<.> "7z"
    runReaderT (download req dest) manager
    liftIO $ createDirectoryIfMissing True dir
    run7z dir $ toFilePath dest
    return $ gitDirs dir
  where
    dir = root FP.</> name
    DownloadPair gitVersion url = siPortableGit si
    name = "git-" <> versionString gitVersion

-- | Windows: Turn a base Git installation directory into a list of bin paths.
gitDirs :: FilePath -> [FilePath]
gitDirs dir =
    [ dir FP.</> "cmd"
    , dir FP.</> "usr" FP.</> "bin"
    ]

-- | Perform necessary installation for Windows
windows :: (MonadLogger m, MonadThrow m, MonadIO m)
        => SetupInfo
        -> Manager
        -> Version
        -> Path Abs Dir -- ^ GHC install root (Programs\ghc-X.Y.Z)
        -> Path Abs Dir -- ^ installation root (Programs\)
        -> m [FilePath]
windows si manager reqVersion dest progDir = do
    let root = toFilePath progDir
    contents <- liftIO $ handleIO (const $ return []) (getDirectoryContents root)
    gitDirs' <- getGitDirs (Just (si, manager)) root contents
    DownloadPair version url <- getGHCPair si "windows" reqVersion
    let dirPiece = "ghc-" <> versionString version
    req <- parseUrl $ T.unpack url
    piece <- Path.parseRelFile $ dirPiece ++ ".tar.xz"
    let destXZ = progDir Path.</> piece
    $logInfo $ "Downloading GHC from: " <> url
    runReaderT (download req destXZ) manager
    run7z <- runReaderT (setup7z si root) manager
    run7z (toFilePath progDir) (toFilePath destXZ)
    run7z (toFilePath progDir)
          (toFilePath progDir FP.</> dirPiece FP.<.> "tar")
    return $
        [ toFilePath $ dest Path.</> $(Path.mkRelDir "bin")
        , toFilePath $ dest Path.</> $(Path.mkRelDir "mingw")
                            Path.</> $(Path.mkRelDir "bin")
        ] ++ gitDirs'

-- -- FIXME cleanup below here

-- data SetupException'
--   = GhcVersionNotRecognized Version
--   | AlreadySetup Version
--   deriving (Show, Typeable)
-- instance Exception SetupException'

-- isSetup :: (MonadIO m, MonadReader env m, Stack.HasConfig env, MonadLogger m)
--   => Version -> m Bool
-- isSetup ghcVersion = do
--   -- TODO: a better implementation
--   liftIO $ oldIsSetupIO (show ghcVersion)

-- data Paths = Paths
--     { binPaths :: [Path Abs Dir]
--     }

-- -- TODO: implement
-- getPaths :: (MonadIO m, MonadReader env m, Stack.HasConfig env)
--   => Version -> m Paths
-- getPaths _ghcVersion = return $ Paths []





-- -- Copied code from stackage-setup follows
-- ---------------------------------------------------------------------
-- userAgent :: ByteString
-- userAgent = "stackage-setup"

-- stackageHostDefault :: String
-- stackageHostDefault = "https://www.stackage.org"

-- data R = R
--   { rConfig :: ConfigSetup
--   , rManager :: Manager
--   }

-- instance HasHttpManager R where
--   getHttpManager = rManager

-- data ConfigSetup = ConfigSetup
--   { configStackageRoot :: FilePath
--   , configStackageHost :: String
--   }

-- data StackageConfig = StackageConfig
--   { _stackageHost :: String }

-- instance FromJSON StackageConfig where
--   parseJSON = withObject "StackageConfig" $ \obj -> do
--     _stackageHost <- obj .:? "stackage-host" .!= stackageHostDefault
--     return StackageConfig{..}

-- | Check if given processes appear to be present, throwing an exception if
-- missing.
checkDependencies :: (MonadIO m, MonadThrow m, MonadReader env m, HasConfig env)
                  => [String] -> m ()
checkDependencies tools = do
    menv <- getMinimalEnvOverride
    missing <- liftM catMaybes $ mapM (check menv) tools
    if null missing
        then return ()
        else throwM $ MissingDependencies missing
  where
    check menv tool = do
        exists <- doesExecutableExist menv tool
        return $ if exists then Nothing else Just tool

-- getStackageRoot :: GetConfig m => m FilePath
-- getStackageRoot = liftM configStackageRoot getConfigSetup

-- getStackageHost :: GetConfig m => m String
-- getStackageHost = liftM configStackageHost getConfigSetup

-- class HasConfigSetup env where
--   accessConfig :: env -> ConfigSetup
-- instance HasConfigSetup R where
--   accessConfig = rConfig

-- -- TODO: check environment properly
-- getStackageRootIO :: IO FilePath
-- getStackageRootIO = do
--   stackageRoot <- lookupEnv "STACKAGE_ROOT" >>= \case
--     Just dir -> return $ dir
--     Nothing -> do
--       -- TODO: windows-ify
--       home <- lookupEnv "HOME" >>= \case
--         Just homeStr -> return homeStr
--         Nothing -> throwM StackageRootNotFound
--       return (home </> ".stackage")
--   createDirectoryIfMissing True stackageRoot
--   return stackageRoot

-- readFileMay :: FilePath -> IO (Maybe ByteString)
-- readFileMay path = do
--   exists <- doesFileExist path
--   if exists
--     then Just <$> S.readFile path
--     else return Nothing

-- getFirstJust :: [IO (Maybe a)] -> IO (Maybe a)
-- getFirstJust [] = return Nothing
-- getFirstJust (xIO:xsIO) = do
--   xMay <- xIO
--   case xMay of
--     Just{} -> return xMay
--     Nothing -> getFirstJust xsIO

-- getStackageHostIO :: FilePath -> IO String
-- getStackageHostIO stackageRoot = do
--   bsMay <- getFirstJust
--     [ readFileMay (stackageRoot </> "config")
--     , readFileMay (stackageRoot </> "config.yaml")
--     , readFileMay (stackageRoot </> "config.yml")
--     ]
--   case bsMay of
--     Nothing -> return stackageHostDefault
--     Just bs -> case Yaml.decodeEither' bs of
--       Left{} -> return stackageHostDefault
--       Right stackageConfig -> return (_stackageHost stackageConfig)


-- getConfigIO :: IO ConfigSetup
-- getConfigIO = do
--   configStackageRoot <- getStackageRootIO
--   configStackageHost <- getStackageHostIO configStackageRoot
--   return ConfigSetup{..}

-- class Monad m => GetConfig m where
--   getConfigSetup :: m ConfigSetup
-- instance GetConfig IO where
--   getConfigSetup = getConfigIO
-- instance (HasConfigSetup env, Monad m)
--   => GetConfig (ReaderT env m) where
--   getConfigSetup = liftM accessConfig ask


-- withConfig :: (MonadIO m)
--   => ReaderT ConfigSetup m a -> m a
-- withConfig m = do
--   config <- liftIO getConfigIO
--   runReaderT m config

-- curryReaderT :: (r1 -> r2 -> env) -> ReaderT env m a -> ReaderT r1 (ReaderT r2 m) a
-- curryReaderT tup m =
--   ReaderT $ \r1 ->
--   ReaderT $ \r2 ->
--   runReaderT m $ tup r1 r2

-- arch :: String
-- arch = "linux64"

-- snapshotsReq :: (MonadThrow m, GetConfig m) => m Request
-- snapshotsReq = do
--   stackageHost <- getStackageHost
--   parseUrl $ stackageHost <> "/download/snapshots.json"

-- ghcMajorVersionReq :: (MonadThrow m, GetConfig m) => Snapshot -> m Request
-- ghcMajorVersionReq snapshot = do
--   stackageHost <- getStackageHost
--   parseUrl $ stackageHost <> "/snapshot/" <> snapshot <> "/ghc-major-version"

-- getLinksReq :: (MonadThrow m, GetConfig m) => GhcMajorVersion -> m Request
-- getLinksReq ghcMajorVersion = do
--   stackageHost <- getStackageHost
--   parseUrl $ stackageHost <> "/download/" <> arch <> "/ghc-" <> ghcMajorVersion <> "-links.yaml"

-- refreshSnapshots ::
--   ( HasHttpManager env
--   , MonadReader env m
--   , GetConfig m
--   , MonadThrow m
--   , MonadIO m
--   ) => m (HashMap String String)
-- refreshSnapshots = do
--   stackageRoot <- getStackageRoot
--   let path = stackageRoot </> snapshotsPath

--   response <- httpLbs =<< snapshotsReq
--   let lbs = responseBody response
--   liftIO $ LByteString.writeFile path lbs

--   either (throwM . ParseSnapshotsError) return $ Aeson.eitherDecode lbs


-- getLinks ::
--   ( MonadIO m
--   , MonadThrow m
--   , MonadReader env m
--   , GetConfig m
--   , HasHttpManager env
--   ) => GhcMajorVersion -> m [Download]
-- getLinks ghcMajorVersion = do
--   stackageRoot <- getStackageRoot
--   response <- httpLbs =<< getLinksReq ghcMajorVersion
--   let lbs = responseBody response
--       bs = LByteString.toStrict lbs
--       path = stackageRoot </> linksPath ghcMajorVersion
--   liftIO $ LByteString.writeFile path lbs

--   either (throwM . ParseLinksError) return $ Yaml.decodeEither' bs

-- data Download = Download
--   { downloadName :: Text
--   , downloadVersion :: Text
--   , downloadUrl :: String
--   , downloadSha1 :: String
--   , downloadInstructions :: [Text]
--   }

-- instance FromJSON Download where
--   parseJSON = withObject "Download" $ \obj -> do
--     downloadName         <- obj .: "name"
--     downloadVersion      <- obj .: "version"
--     downloadUrl          <- obj .: "url"
--     downloadSha1         <- obj .: "sha1"
--     downloadInstructions <- obj .: "instructions"
--     return Download{..}

-- type SetupTarget = String
-- type GhcMajorVersion = String
-- type Series = String
-- type Snapshot = String

-- data SetupExceptions
--   = SeriesNotFound Series
--   | ParseSnapshotsError String
--   | ParseLinksError Yaml.ParseException
--   | StackageRootNotFound
--   deriving (Show, Typeable)
-- instance Exception SetupExceptions

-- readSeries :: String -> Maybe Series
-- readSeries s@"lts" = Just s
-- readSeries s@"nightly" = Just s
-- readSeries s@(List.stripPrefix "lts-" -> Just sver)
--   | all Char.isNumber sver = Just s
-- readSeries (List.stripPrefix "lts/" -> Just sver)
--   | all Char.isNumber sver = Just $ "lts-" <> sver
-- readSeries _ = Nothing

-- readGhcVersion :: String -> Maybe GhcMajorVersion
-- readGhcVersion (List.stripPrefix "ghc-" -> Just s) = case break (== '.') s of
--   (m1, '.':m2) | all Char.isNumber m1 && all Char.isNumber m2
--     -> Just s
--   _ -> Nothing
-- readGhcVersion _ = Nothing

-- getGhcMajorVersion ::
--   ( HasHttpManager env
--   , MonadReader env m
--   , GetConfig m
--   , MonadThrow m
--   , MonadIO m
--   ) => String -> m GhcMajorVersion
-- getGhcMajorVersion target = case readGhcVersion target of
--   Just version -> return version
--   Nothing -> do
--     snapshot <- case readSeries target of
--       Just series -> lookupSnapshot series
--       Nothing -> return target -- just try using it as a snapshot
--     liftIO $ putStrLn $ "Setup for snapshot: " <> snapshot
--     lookupGhcMajorVersion snapshot

-- lookupSnapshot ::
--   ( HasHttpManager env
--   , MonadReader env m
--   , GetConfig m
--   , MonadThrow m
--   , MonadIO m
--   ) => Series -> m Snapshot
-- lookupSnapshot series = do
--   snapshots <- refreshSnapshots
--   case HashMap.lookup series snapshots of
--     Just snapshot -> return snapshot
--     Nothing -> throwM $ SeriesNotFound series


-- lookupGhcMajorVersion ::
--   ( HasHttpManager env
--   , MonadReader env m
--   , GetConfig m
--   , MonadThrow m
--   , MonadIO m
--   ) => Snapshot -> m GhcMajorVersion
-- lookupGhcMajorVersion snapshot = do
--   response <- httpLbs =<< ghcMajorVersionReq snapshot
--   let lbs = responseBody response
--   return $ LText.unpack $ LText.decodeUtf8 lbs

-- data NotSetup = NotSetup
--   deriving (Show, Typeable)
-- instance Exception NotSetup

-- oldIsSetupIO :: GhcMajorVersion -> IO Bool
-- oldIsSetupIO ghcMajorVersion = do
--   ((withManagerSettings tlsManagerSettings
--     $ withConfig
--     $ curryReaderT R
--     $ oldIsSetup ghcMajorVersion
--    ) >> return True) `catch` \NotSetup -> return False

-- -- Just copied a portion of oldSetup
-- oldIsSetup ::
--   ( HasHttpManager env
--   , MonadReader env m
--   , GetConfig m
--   , MonadThrow m
--   , MonadIO m
--   , MonadBaseControl IO m
--   ) => SetupTarget -> m ()
-- oldIsSetup ghcMajorVersion = do
--   links <- getLinks ghcMajorVersion

--   stackageRoot <- getStackageRoot
--   forM_ links $ \_d@Download{..} -> do
--     let dir = stackageRoot </> downloadDir downloadName
--     liftIO $ createDirectoryIfMissing True dir

--     let versionedDir = dir </> downloadPath downloadName downloadVersion
--     exists <- liftIO $ doesDirectoryExist versionedDir

--     when (not exists) $ throwM NotSetup
--   return ()


-- -- The dependencies required for stackage-setup's implementation of
-- -- the instructions for a given download item.
-- depsFor :: Text -> [String]
-- depsFor "ghc"      = ["make", "tar", "xz"]
-- depsFor "cabal"    = ["tar", "gzip"]
-- depsFor "stackage" = ["tar", "xz"]
-- depsFor "alex"     = ["tar", "xz"]
-- depsFor "happy"    = ["tar", "xz"]
-- depsFor _          = []

-- -- TODO: ensure this works cross-platform
-- augmentPath :: MonadIO m => FilePath -> m ()
-- augmentPath pathHead = liftIO $ do
--   pathRest <- getSearchPath
--   let paths = pathHead : pathRest
--       path = List.intercalate [searchPathSeparator] paths
--   setEnv "PATH" path


-- postDownload :: (MonadIO m)
--   => Download -> FilePath -> FilePath -> m ()
-- postDownload d@Download{..} dir versionedDir = do
--   expectInstructions downloadName d dir versionedDir

-- expectInstructions :: (MonadIO m) => Text -> Download -> FilePath -> FilePath -> m ()
-- expectInstructions "ghc" = expectGhcInstructions
-- expectInstructions "cabal" = expectCabalInstructions
-- expectInstructions "stackage" = justUnpackInstructions
-- expectInstructions "alex" = justUnpackInstructions
-- expectInstructions "happy" = justUnpackInstructions
-- expectInstructions t = unexpectedInstructions t

-- unexpectedInstructions :: (MonadIO m) => Text -> Download -> FilePath -> FilePath -> m ()
-- unexpectedInstructions t Download{..} dir _ = liftIO $ do
--   putStrLn $ "Unexpected download: " <> Text.unpack t
--   when (not $ null downloadInstructions) $ do
--     putStrLn $ "Manual instructions:"
--     putStrLn $ "$ cd " <> dir
--     mapM_ (putStrLn . ("$ " <>) . Text.unpack) downloadInstructions

-- justUnpackInstructions :: (MonadIO m) => Download -> FilePath -> FilePath -> m ()
-- justUnpackInstructions Download{..} dir _ = do
--     liftIO $ go downloadInstructions
--   where
--     go :: [Text] -> IO ()
--     go [] = return ()
--     go ( (Text.stripPrefix "tar xJf " -> Just file)
--        : next
--        ) = unzipXZ dir (Text.unpack file) >> go next
--     go ( (Text.stripPrefix "rm " -> Just _file)
--        : next
--        ) = go next -- already done in unzipXZ
--     go (t:_) = fail $ "command not recognized: " <> Text.unpack t


-- expectGhcInstructions :: (MonadIO m) => Download -> FilePath -> FilePath -> m ()
-- expectGhcInstructions Download{..} dir versionedDir =
--     liftIO $ go downloadInstructions
--   where
--     go :: [Text] -> IO ()
--     go [] = return ()
--     go ( (Text.stripPrefix "tar xJf " -> Just file)
--        : next
--        ) = unzipXZ dir (Text.unpack file) >> go next
--     go ( (Text.stripPrefix "rm ghc-" -> Just _file)
--        : next
--        ) = go next -- already done in unzipXZ
--     go ( (Text.stripPrefix "cd ghc-" -> Just version)
--        : "./configure --prefix=`pwd`"
--        : "make install"
--        : "cd .."
--        : next
--        ) | version == downloadVersion
--        = ghcConfigureInstall versionedDir >> go next
--     go (t:_) = fail $ "command not recognized: " <> Text.unpack t


-- inDir :: FilePath -> IO a -> IO a
-- inDir dir action = do
--   currentDir <- getCurrentDirectory
--   let enter = setCurrentDirectory dir
--       exit = setCurrentDirectory currentDir
--   bracket_ enter exit action


-- ghcConfigureInstall :: (MonadIO m) => FilePath -> m ()
-- ghcConfigureInstall versionedDir = liftIO $ do
--   let srcDir = versionedDir <.> "src"
--   exists <- doesDirectoryExist srcDir
--   when exists $ removeDirectoryRecursive srcDir -- TODO: reuse instead
--   renameDirectory versionedDir srcDir
--   createDirectoryIfMissing True versionedDir
--   let go = inDir srcDir $ do
--         callProcess "./configure" ["--prefix=" <> versionedDir]
--         callProcess "make" ["install"]
--   go `onException` removeDirectoryRecursive versionedDir
--   removeDirectoryRecursive srcDir

-- expectCabalInstructions :: (MonadIO m) => Download -> FilePath -> FilePath -> m ()
-- expectCabalInstructions Download{..} dir versionedDir =
--     liftIO $ rememberingOldCabal $ go downloadInstructions
--   where
--     go [] = return ()
--     go ( (Text.stripPrefix "tar xzf " -> Just file)
--        : next
--        ) = unzipGZ dir (Text.unpack file) >> go next
--     go ( (Text.stripPrefix "rm cabal-install-" ->
--           Just (Text.stripSuffix ".tar.gz" -> Just _file))
--        : next
--        ) = go next -- already done in unzipGZ
--     go ( (Text.stripPrefix "cd cabal-install-" -> Just version)
--        : "./bootstrap.sh"
--        : "cd .."
--        : (Text.stripPrefix "rm -r cabal-install-" -> Just version')
--        : next
--        ) | version == downloadVersion && version == version'
--        = cabalBootstrap dir version >> go next
--     go ( (Text.stripPrefix "mkdir cabal-" -> Just version)
--        : (Text.stripPrefix "mv $HOME/.cabal/bin/cabal cabal-" -> Just _newLoc)
--        : next
--        ) | version == downloadVersion
--        = cabalMoveExe versionedDir >> go next
--     go (t:_) = fail $ "command not recognized: " <> Text.unpack t

-- cabalBootstrap :: FilePath -> Text -> IO ()
-- cabalBootstrap dir version = do
--   let cabalInstallVersionedDir = dir </> Text.unpack ("cabal-install-" <> version)
--   inDir cabalInstallVersionedDir $ do
--     callProcess "./bootstrap.sh" []
--   removeDirectoryRecursive cabalInstallVersionedDir

-- cabalMoveExe :: FilePath -> IO ()
-- cabalMoveExe versionedDir = do
--   let versionedDirBin = versionedDir </> "bin"
--   createDirectoryIfMissing True versionedDirBin
--   homeCabal <- getHomeCabal
--   renameFile homeCabal (versionedDirBin </> "cabal")

-- getHomeCabal :: IO FilePath
-- getHomeCabal = do
--   -- TODO: errors
--   Just home <- lookupEnv "HOME"
--   return $ home </> ".cabal" </> "bin" </> "cabal"

-- rememberingOldCabal :: IO a -> IO a
-- rememberingOldCabal action = do
--   homeCabal <- getHomeCabal
--   exists <- doesFileExist homeCabal
--   if exists
--     then do
--       let tempCabal = homeCabal <.> "old"
--           toTemp = renameFile homeCabal tempCabal
--           fromTemp = renameFile tempCabal homeCabal
--       bracket_ toTemp fromTemp action
--     else action

-- -- TODO: use Text more than String
-- download' ::
--   ( MonadIO m
--   , MonadBaseControl IO m
--   , MonadThrow m
--   , MonadReader env m
--   , HasHttpManager env
--   ) => String -> String -> FilePath -> m ()
-- download' url sha1 dir = do
--   -- TODO: deal with partial function last
--   let fname = List.drop (List.last slashes + 1) url
--       slashes = List.findIndices (== '/') url
--       file = dir </> fname
--   liftIO $ putStrLn $ "Downloading: " <> fname
--   req0 <- parseUrl url
--   let req = req0
--         { requestHeaders = [(hUserAgent, userAgent)] }
--   runResourceT $ withResponse req $ \res -> do
--     let source = responseBody res
--     let sink = getZipSink $
--           ZipSink sinkHash <* ZipSink (sinkFile file)
--     theDigest <- source $$ sink
--     let _ = theDigest :: Digest SHA1
--     when (show theDigest /= sha1) $ do
--       fail "Corrupted download"
--     liftIO $ putStrLn $ "Verified sha1: " <> sha1

-- -- TODO: make cross platform
-- _unzipDownload :: (MonadIO m)
--   => FilePath -> FilePath -> m ()
-- _unzipDownload dir file = case Text.stripSuffix ".tar.xz" (Text.pack file) of
--   Just{} -> unzipXZ dir file
--   _ -> case Text.stripSuffix ".tar.gz" (Text.pack file) of
--     Just {} -> unzipGZ dir file
--     _ -> fail $ "unzipDownload: unknown extension"
--   -- TODO: other extensions

-- -- TODO: make cross platform
-- unzipXZ :: (MonadIO m)
--   => FilePath -> FilePath -> m ()
-- unzipXZ dir file = liftIO $ inDir dir $ do
--   putStrLn "Decompressing XZ archive"
--   callProcess "tar"
--     ["xJf"
--     , file
--     ]
--   removeFile file


-- -- TODO: make cross platform
-- unzipGZ :: (MonadIO m)
--   => FilePath -> FilePath -> m ()
-- unzipGZ dir file = liftIO $ inDir dir $ do
--   putStrLn "Decompressing GZ archive"
--   callProcess "tar"
--     ["xzf"
--     , file
--     ]
--   removeFile file

-- downloadDir :: Text -> FilePath
-- downloadDir name =
--   "environment" </> Text.unpack name

-- downloadPath :: Text -> Text -> FilePath
-- downloadPath name version =
--   Text.unpack (name <> "-" <> version)

-- snapshotsPath :: FilePath
-- snapshotsPath = Text.unpack "snapshots.json"

-- linksPath :: GhcMajorVersion -> FilePath
-- linksPath ghcMajorVersion = Text.unpack $ "ghc-" <> Text.pack ghcMajorVersion <> "-links.yaml"
