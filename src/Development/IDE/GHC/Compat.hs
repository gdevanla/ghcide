-- Copyright (c) 2019 The DAML Authors. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PatternSynonyms #-}
{-# OPTIONS -Wno-dodgy-imports -Wno-incomplete-uni-patterns #-}
#include "ghc-api-version.h"

-- | Attempt at hiding the GHC version differences we can.
module Development.IDE.GHC.Compat(
    getHeaderImports,
    HieFileResult(..),
    HieFile(..),
    NameCacheUpdater(..),
    hieExportNames,
    mkHieFile,
    mkHieFile',
    enrichHie,
    RefMap,
    writeHieFile,
    readHieFile,
    supportsHieFiles,
    setHieDir,
    dontWriteHieFiles,
#if !MIN_GHC_API_VERSION(8,8,0)
    ml_hie_file,
    addBootSuffixLocnOut,
#endif
    hPutStringBuffer,
    includePathsGlobal,
    includePathsQuote,
    addIncludePathsQuote,
    getModuleHash,
    getPackageName,
    setUpTypedHoles,
    GHC.ModLocation,
    Module.addBootSuffix,
    pattern ModLocation,
    HasSrcSpan,
    getLoc,
    upNameCache,
    disableWarningsAsErrors,
    fixDetailsForTH,
    AvailInfo,
    tcg_exports,

#if MIN_GHC_API_VERSION(8,10,0)
    module GHC.Hs.Extension,
#else
    module HsExtension,
    noExtField,
#endif

    module GHC,
    initializePlugins,
    applyPluginsParsedResultAction,
#if MIN_GHC_API_VERSION(8,8,0)
    module HieTypes,
    module HieUtils,
#else
    module Development.IDE.GHC.HieTypes,
    module Development.IDE.GHC.HieUtils,
#endif

    ) where

import StringBuffer
import DynFlags
import Fingerprint (Fingerprint)
import qualified Module
import Packages
import Data.IORef
import HscTypes
import NameCache
import qualified Data.ByteString as BS
import MkIface
import TcRnTypes

#if MIN_GHC_API_VERSION(8,10,0)
import GHC.Hs.Extension
#else
import HsExtension
#endif

import qualified GHC
import GHC hiding (
      ModLocation,
      HasSrcSpan,
      lookupName,
      getLoc
    )
import qualified HeaderInfo as Hdr
import Avail
#if MIN_GHC_API_VERSION(8,8,0)
import Data.List (foldl')
#else
import Data.List (foldl', isSuffixOf)
#endif
import ErrUtils (ErrorMessages)
import FastString (FastString)
import ConLike   (ConLike (PatSynCon))
#if MIN_GHC_API_VERSION(8,8,0)
import InstEnv   (updateClsInstDFun)
import PatSyn    (PatSyn, updatePatSynIds)
#else
import InstEnv   (tidyClsInstDFun)
import PatSyn    (PatSyn, tidyPatSynIds)
#endif

import Development.IDE.GHC.HieAst (mkHieFile,enrichHie)
import Development.IDE.GHC.HieBin
import DynamicLoading
import Plugins (Plugin(parsedResultAction), withPlugins)
import Data.Map.Strict (Map)

#if MIN_GHC_API_VERSION(8,8,0)
import HieUtils
import HieTypes
#else
import Development.IDE.GHC.HieUtils
import Development.IDE.GHC.HieTypes
import System.FilePath ((-<.>))
#endif

#if MIN_GHC_API_VERSION(8,8,0)
import GhcPlugins (Unfolding(BootUnfolding), setIdUnfolding, tidyTopType, setIdType, globaliseId, ppr, pprPanic, isWiredInName, elemNameSet, idName, filterOut)
# else
import qualified EnumSet

import GhcPlugins (srcErrorMessages, Unfolding(BootUnfolding), setIdUnfolding, tidyTopType, setIdType, globaliseId, isWiredInName, elemNameSet, idName, filterOut)

import Control.Exception (catch)
import System.IO
import Foreign.ForeignPtr


hPutStringBuffer :: Handle -> StringBuffer -> IO ()
hPutStringBuffer hdl (StringBuffer buf len cur)
    = withForeignPtr (plusForeignPtr buf cur) $ \ptr ->
             hPutBuf hdl ptr len

#endif

#if !MIN_GHC_API_VERSION(8,10,0)
noExtField :: NoExt
noExtField = noExt
#endif


supportsHieFiles :: Bool
supportsHieFiles = True

hieExportNames :: HieFile -> [(SrcSpan, Name)]
hieExportNames = nameListFromAvails . hie_exports

#if !MIN_GHC_API_VERSION(8,8,0)
ml_hie_file :: GHC.ModLocation -> FilePath
ml_hie_file ml
  | "boot" `isSuffixOf ` ml_hi_file ml = ml_hi_file ml -<.> ".hie-boot"
  | otherwise  = ml_hi_file ml -<.> ".hie"
#endif

upNameCache :: IORef NameCache -> (NameCache -> (NameCache, c)) -> IO c
#if !MIN_GHC_API_VERSION(8,8,0)
upNameCache ref upd_fn
  = atomicModifyIORef' ref upd_fn
#else
upNameCache = updNameCache
#endif


type RefMap = Map Identifier [(Span, IdentifierDetails Type)]

mkHieFile' :: ModSummary
           -> [AvailInfo]
           -> HieASTs Type
           -> BS.ByteString
           -> Hsc HieFile
mkHieFile' ms exports asts src = do
  let Just src_file = ml_hs_file $ ms_location ms
      (asts',arr) = compressTypes asts
  return $ HieFile
      { hie_hs_file = src_file
      , hie_module = ms_mod ms
      , hie_types = arr
      , hie_asts = asts'
      -- mkIfaceExports sorts the AvailInfos for stability
      , hie_exports = mkIfaceExports exports
      , hie_hs_src = src
      }

addIncludePathsQuote :: FilePath -> DynFlags -> DynFlags
addIncludePathsQuote path x = x{includePaths = f $ includePaths x}
    where f i = i{includePathsQuote = path : includePathsQuote i}

pattern ModLocation :: Maybe FilePath -> FilePath -> FilePath -> GHC.ModLocation
pattern ModLocation a b c <-
#if MIN_GHC_API_VERSION(8,8,0)
    GHC.ModLocation a b c _ where ModLocation a b c = GHC.ModLocation a b c ""
#else
    GHC.ModLocation a b c where ModLocation a b c = GHC.ModLocation a b c
#endif

setHieDir :: FilePath -> DynFlags -> DynFlags
setHieDir _f d =
#if MIN_GHC_API_VERSION(8,8,0)
    d { hieDir     = Just _f}
#else
    d
#endif

dontWriteHieFiles :: DynFlags -> DynFlags
dontWriteHieFiles d =
#if MIN_GHC_API_VERSION(8,8,0)
    gopt_unset d Opt_WriteHie
#else
    d
#endif

setUpTypedHoles ::DynFlags -> DynFlags
setUpTypedHoles df
  = flip gopt_unset Opt_AbstractRefHoleFits    -- too spammy
#if MIN_GHC_API_VERSION(8,8,0)
  $ flip gopt_unset Opt_ShowDocsOfHoleFits     -- not used
#endif
  $ flip gopt_unset Opt_ShowMatchesOfHoleFits  -- nice but broken (forgets module qualifiers)
  $ flip gopt_unset Opt_ShowProvOfHoleFits     -- not used
  $ flip gopt_unset Opt_ShowTypeAppOfHoleFits  -- not used
  $ flip gopt_unset Opt_ShowTypeAppVarsOfHoleFits -- not used
  $ flip gopt_unset Opt_ShowTypeOfHoleFits     -- massively simplifies parsing
  $ flip gopt_set   Opt_SortBySubsumHoleFits   -- very nice and fast enough in most cases
  $ flip gopt_unset Opt_SortValidHoleFits
  $ flip gopt_unset Opt_UnclutterValidHoleFits
  $ df
  { refLevelHoleFits = Just 1   -- becomes slow at higher levels
  , maxRefHoleFits   = Just 10  -- quantity does not impact speed
  , maxValidHoleFits = Nothing  -- quantity does not impact speed
  }


nameListFromAvails :: [AvailInfo] -> [(SrcSpan, Name)]
nameListFromAvails as =
  map (\n -> (nameSrcSpan n, n)) (concatMap availNames as)

getHeaderImports
  :: DynFlags
  -> StringBuffer
  -> FilePath
  -> FilePath
  -> IO
       ( Either
           ErrorMessages
           ( [(Maybe FastString, Located ModuleName)]
           , [(Maybe FastString, Located ModuleName)]
           , Located ModuleName
           )
       )
#if MIN_GHC_API_VERSION(8,8,0)
getHeaderImports = Hdr.getImports

type HasSrcSpan = GHC.HasSrcSpan
getLoc :: HasSrcSpan a => a -> SrcSpan
getLoc = GHC.getLoc

#else

class HasSrcSpan a where
    getLoc :: a -> SrcSpan
instance HasSrcSpan Name where
    getLoc = nameSrcSpan
instance HasSrcSpan (GenLocated SrcSpan a) where
    getLoc = GHC.getLoc

getHeaderImports a b c d =
    catch (Right <$> Hdr.getImports a b c d)
          (return . Left . srcErrorMessages)

-- | Add the @-boot@ suffix to all output file paths associated with the
-- module, not including the input file itself
addBootSuffixLocnOut :: GHC.ModLocation -> GHC.ModLocation
addBootSuffixLocnOut locn
  = locn { ml_hi_file  = Module.addBootSuffix (ml_hi_file locn)
         , ml_obj_file = Module.addBootSuffix (ml_obj_file locn)
         }
#endif

getModuleHash :: ModIface -> Fingerprint
#if MIN_GHC_API_VERSION(8,10,0)
getModuleHash = mi_mod_hash . mi_final_exts
#else
getModuleHash = mi_mod_hash
#endif

getPackageName :: DynFlags -> Module.InstalledUnitId -> Maybe PackageName
getPackageName dfs i = packageName <$> lookupPackage dfs (Module.DefiniteUnitId (Module.DefUnitId i))

disableWarningsAsErrors :: DynFlags -> DynFlags
disableWarningsAsErrors df =
    flip gopt_unset Opt_WarnIsError $ foldl' wopt_unset_fatal df [toEnum 0 ..]

#if !MIN_GHC_API_VERSION(8,8,0)
wopt_unset_fatal :: DynFlags -> WarningFlag -> DynFlags
wopt_unset_fatal dfs f
    = dfs { fatalWarningFlags = EnumSet.delete f (fatalWarningFlags dfs) }
#endif

applyPluginsParsedResultAction :: HscEnv -> DynFlags -> ModSummary -> ApiAnns -> ParsedSource -> IO ParsedSource
applyPluginsParsedResultAction env dflags ms hpm_annotations parsed = do
  -- Apply parsedResultAction of plugins
  let applyPluginAction p opts = parsedResultAction p opts ms
  fmap hpm_module $ 
    runHsc env $ withPlugins dflags applyPluginAction 
      (HsParsedModule parsed [] hpm_annotations)

-- | This function recalculates the fields md_types and md_insts in the ModDetails.
-- It duplicates logic from GHC mkBootModDetailsTc to keep more ids,
-- because ghc drops ids in tcg_keep, which matters because TH identifiers
-- might be in there.  See the original function for more comments.
fixDetailsForTH :: TypecheckedModule -> IO TypecheckedModule
fixDetailsForTH tcm = do
   keep_ids <- readIORef keep_ids_ptr
   let
    keep_it id | isWiredInName id_name           = False
                 -- See Note [Drop wired-in things]
               | isExportedId id                 = True
               | id_name `elemNameSet` exp_names = True
               | id_name `elemNameSet` keep_ids  = True -- This is the line added in comparison to the original function.
               | otherwise                       = False
               where
                 id_name = idName id
    final_ids = [ globaliseAndTidyBootId id
                | id <- typeEnvIds type_env
                , keep_it id ]
    final_tcs  = filterOut (isWiredInName . getName) tcs
    type_env1  = typeEnvFromEntities final_ids final_tcs fam_insts
    insts'     = mkFinalClsInsts type_env1 insts
    pat_syns'  = mkFinalPatSyns  type_env1 pat_syns
    type_env'  = extendTypeEnvWithPatSyns pat_syns' type_env1
    fixedDetails = details {
                         md_types         = type_env'
                       , md_insts         = insts'
                       }
   pure $ tcm { tm_internals_ = (tc_gbl_env, fixedDetails) }
 where
    (tc_gbl_env, details) = tm_internals_ tcm
    TcGblEnv{ tcg_exports          = exports,
              tcg_type_env         = type_env,
              tcg_tcs              = tcs,
              tcg_patsyns          = pat_syns,
              tcg_insts            = insts,
              tcg_fam_insts        = fam_insts,
              tcg_keep             = keep_ids_ptr
            } = tc_gbl_env
    exp_names = availsToNameSet exports

-- Functions from here are only pasted from ghc TidyPgm.hs

mkFinalClsInsts :: TypeEnv -> [ClsInst] -> [ClsInst]
mkFinalPatSyns :: TypeEnv -> [PatSyn] -> [PatSyn]
#if MIN_GHC_API_VERSION(8,8,0)
mkFinalClsInsts env = map (updateClsInstDFun (lookupFinalId env))
mkFinalPatSyns env = map (updatePatSynIds (lookupFinalId env))

lookupFinalId :: TypeEnv -> Id -> Id
lookupFinalId type_env id
  = case lookupTypeEnv type_env (idName id) of
      Just (AnId id') -> id'
      _ -> pprPanic "lookup_final_id" (ppr id)
#else
mkFinalClsInsts _env = map (tidyClsInstDFun globaliseAndTidyBootId)
mkFinalPatSyns _env = map (tidyPatSynIds globaliseAndTidyBootId)
#endif


extendTypeEnvWithPatSyns :: [PatSyn] -> TypeEnv -> TypeEnv
extendTypeEnvWithPatSyns tidy_patsyns type_env
  = extendTypeEnvList type_env [AConLike (PatSynCon ps) | ps <- tidy_patsyns ]

globaliseAndTidyBootId :: Id -> Id
-- For a LocalId with an External Name,
-- makes it into a GlobalId
--     * unchanged Name (might be Internal or External)
--     * unchanged details
--     * VanillaIdInfo (makes a conservative assumption about Caf-hood and arity)
--     * BootUnfolding (see Note [Inlining and hs-boot files] in ToIface)
globaliseAndTidyBootId id
  = globaliseId id `setIdType`      tidyTopType (idType id)
                   `setIdUnfolding` BootUnfolding
