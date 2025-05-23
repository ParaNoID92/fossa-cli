{-# LANGUAGE RecordWildCards #-}

module App.Fossa.Config.Report (
  ReportConfig (..),
  ReportCliOptions,
  ReportOutputFormat (..),
  ReportType (..),
  ReportBase (..),
  mkSubCommand,
  -- Exported for testing
  parseReportOutputFormat,
) where

import App.Fossa.Config.Common (
  CacheAction (ReadOnly),
  CommonOpts (..),
  baseDirArg,
  collectApiOpts,
  collectBaseDir,
  collectBaseFile,
  collectRevisionData',
  commonOpts,
  defaultTimeoutDuration,
 )
import App.Fossa.Config.ConfigFile (ConfigFile, resolveLocalConfigFile)
import App.Fossa.Config.EnvironmentVars (EnvVars)
import App.Fossa.Config.SBOM.Common qualified as SBOMCfg
import App.Fossa.Subcommand (EffStack, GetCommonOpts (getCommonOpts), GetSeverity (getSeverity), SubCommand (SubCommand))
import App.Types (BaseDir (..), OverrideProject (OverrideProject), ProjectRevision)
import Control.Applicative ((<|>))
import Control.Effect.Diagnostics (Diagnostics, ToDiagnostic (renderDiagnostic), errHelp, fatal, fromMaybe)
import Control.Effect.Diagnostics qualified as Diag
import Control.Effect.Lift (Has, Lift)
import Control.Timeout (Duration (Seconds))
import Data.Aeson (ToJSON (toEncoding), defaultOptions, genericToEncoding)
import Data.Error (SourceLocation, createEmptyBlock, getSourceLocation)
import Data.List (intercalate)
import Data.String.Conversion (ToText, toText)
import Data.String.Conversion qualified as Conv
import Data.Text (Text)
import Effect.Exec (Exec)
import Effect.Logger (Logger, Severity (..), vsep)
import Effect.ReadFS (ReadFS)
import Errata (Errata (..), errataSimple)
import Fossa.API.Types (ApiOpts)
import GHC.Generics (Generic)
import Options.Applicative (
  InfoMod,
  Parser,
  argument,
  auto,
  long,
  maybeReader,
  metavar,
  option,
  optional,
  progDescDoc,
  strOption,
  switch,
 )
import Options.Applicative.Builder (helpDoc)
import Path
import Prettyprinter (Doc, comma, hardline, punctuate, viaShow)
import Prettyprinter.Render.Terminal (AnsiStyle, Color (Green, Red))
import Style (applyFossaStyle, boldItalicized, coloredBoldItalicized, formatDoc, stringToHelpDoc, styledDivider)

data ReportType = Attribution deriving (Eq, Ord, Enum, Bounded, Generic)

instance ToJSON ReportType where
  toEncoding = genericToEncoding defaultOptions

instance Show ReportType where
  show Attribution = "attribution"

data ReportOutputFormat
  = ReportCSV
  | -- Core will return the cyclonedx report with license data encoded in base64.
    -- This is specified in the bom schema: https://github.com/CycloneDX/specification/blob/1.4/schema/bom-1.4.schema.json#L529
    ReportCycloneDXJSON
  | ReportCycloneDXXML
  | ReportHTML
  | ReportJson
  | ReportMarkdown
  | ReportPlainText
  | ReportSpdx
  | ReportSpdxJSON
  deriving (Eq, Ord, Enum, Bounded, Generic)

parseReportOutputFormat :: String -> Maybe ReportOutputFormat
parseReportOutputFormat s | s == show ReportJson = Just ReportJson
parseReportOutputFormat s | s == show ReportSpdx = Just ReportSpdx
parseReportOutputFormat s | s == show ReportMarkdown = Just ReportMarkdown
parseReportOutputFormat s | s == show ReportPlainText = Just ReportPlainText
parseReportOutputFormat s | s == show ReportSpdxJSON = Just ReportSpdxJSON
parseReportOutputFormat s | s == show ReportCycloneDXJSON = Just ReportCycloneDXJSON
parseReportOutputFormat s | s == show ReportCycloneDXXML = Just ReportCycloneDXXML
parseReportOutputFormat s | s == show ReportHTML = Just ReportHTML
parseReportOutputFormat s | s == show ReportCSV = Just ReportCSV
parseReportOutputFormat _ = Nothing

instance ToText ReportOutputFormat where
  toText = toText . show

instance Show ReportOutputFormat where
  show ReportJson = "json"
  show ReportMarkdown = "markdown"
  show ReportSpdx = "spdx"
  show ReportPlainText = "text"
  show ReportSpdxJSON = "spdx-json"
  show ReportCycloneDXJSON = "cyclonedx-json"
  show ReportCycloneDXXML = "cyclonedx-xml"
  show ReportHTML = "html"
  show ReportCSV = "csv"

allFormats :: [ReportOutputFormat]
allFormats = enumFromTo minBound maxBound

reportOutputFormatList :: String
reportOutputFormatList = intercalate ", " $ map show allFormats

styledReportOutputFormats :: Doc AnsiStyle
styledReportOutputFormats = mconcat $ punctuate styledDivider coloredAllFormats
  where
    coloredAllFormats :: [Doc AnsiStyle]
    coloredAllFormats = map (coloredBoldItalicized Green . viaShow) allFormats

instance ToJSON ReportOutputFormat where
  toEncoding = genericToEncoding defaultOptions

allReports :: [ReportType]
allReports = enumFromTo minBound maxBound

reportInfo :: InfoMod a
reportInfo = progDescDoc (Just $ formatDoc desc)
  where
    desc :: Doc AnsiStyle
    desc =
      "Access various reports from FOSSA and print to stdout"
        <> hardline
        <> "Currently available reports: "
        <> mconcat (punctuate comma (map viaShow allReports))
        <> hardline
        <> "Example: "
        <> "fossa report --format html attribution"

mkSubCommand :: (ReportConfig -> EffStack ()) -> SubCommand ReportCliOptions ReportConfig
mkSubCommand = SubCommand "report" reportInfo parser loadConfig mergeOpts

parser :: Parser ReportCliOptions
parser =
  ReportCliOptions
    <$> commonOpts
    <*> switch (applyFossaStyle <> long "json" <> helpDoc jsonHelp)
    <*> optional (strOption (applyFossaStyle <> long "format" <> helpDoc formatHelp))
    <*> optional (option auto (applyFossaStyle <> long "timeout" <> stringToHelpDoc "Duration to wait for build completion (in seconds)"))
    <*> reportTypeArg
    <*> basePath
  where
    basePath :: Parser Text
    basePath = (Conv.toText <$> baseDirArg) <|> (SBOMCfg.unSBOMFile <$> SBOMCfg.sbomFileArg)

    jsonHelp :: Maybe (Doc AnsiStyle)
    jsonHelp =
      Just . formatDoc $
        vsep
          [ "Output the report in JSON format. Equivalent to " <> coloredBoldItalicized Green "--format json" <> " and overrides " <> coloredBoldItalicized Green "--format"
          , coloredBoldItalicized Red "Deprecated: " <> "prefer " <> coloredBoldItalicized Green "--format"
          ]

    formatHelp :: Maybe (Doc AnsiStyle)
    formatHelp =
      Just . formatDoc $
        vsep
          [ "Output the report in the specified format"
          , boldItalicized "Formats: " <> styledReportOutputFormats
          ]

reportTypeArg :: Parser ReportType
reportTypeArg = argument (maybeReader parseType) (applyFossaStyle <> metavar "REPORT" <> stringToHelpDoc "The report type to fetch from the server")
  where
    parseType :: String -> Maybe ReportType
    parseType = \case
      "attribution" -> Just Attribution
      _ -> Nothing

data ReportCliOptions = ReportCliOptions
  { commons :: CommonOpts
  , cliReportJsonOutput :: Bool
  , cliReportOutputFormat :: Maybe String
  , cliReportTimeout :: Maybe Int
  , cliReportType :: ReportType
  , cliReportBase :: Text
  }
  deriving (Eq, Ord, Show)

instance GetSeverity ReportCliOptions where
  getSeverity ReportCliOptions{..} = if (optDebug commons) then SevDebug else SevInfo

instance GetCommonOpts ReportCliOptions where
  getCommonOpts ReportCliOptions{..} = Just commons

loadConfig ::
  ( Has (Lift IO) sig m
  , Has ReadFS sig m
  , Has Diagnostics sig m
  , Has Logger sig m
  ) =>
  ReportCliOptions ->
  m (Maybe ConfigFile)
loadConfig = resolveLocalConfigFile . optConfig . commons

mergeOpts ::
  ( Has (Lift IO) sig m
  , Has ReadFS sig m
  , Has Logger sig m
  , Has Diagnostics sig m
  , Has Exec sig m
  ) =>
  Maybe ConfigFile ->
  EnvVars ->
  ReportCliOptions ->
  m ReportConfig
mergeOpts cfgfile envvars ReportCliOptions{..} = do
  let apiOpts = collectApiOpts cfgfile envvars commons
      outputformat = validateOutputFormat cliReportJsonOutput cliReportOutputFormat
      timeoutduration = maybe defaultTimeoutDuration Seconds cliReportTimeout
      projectOverride = OverrideProject (optProjectName commons) (optProjectRevision commons) Nothing

  (revision, reportBase) <- generateDirOrSBOMBase cliReportBase projectOverride

  ReportConfig
    <$> apiOpts
    <*> pure reportBase
    <*> outputformat
    <*> pure timeoutduration
    <*> pure cliReportType
    <*> pure revision
  where
    generateDirOrSBOMBase ::
      ( Has Exec sig m
      , Has Logger sig m
      , Has (Lift IO) sig m
      , Has ReadFS sig m
      , Has Diagnostics sig m
      ) =>
      Text ->
      OverrideProject ->
      m (ProjectRevision, ReportBase)
    generateDirOrSBOMBase path projectOverride = do
      basedir <- Diag.recover $ collectBaseDir (Conv.toString path)
      case basedir of
        Just dir ->
          (,)
            <$> collectRevisionData' (pure dir) cfgfile ReadOnly projectOverride
            <*> pure (DirectoryBase . unBaseDir $ dir)
        Nothing -> do
          baseFile <- Diag.recover $ collectBaseFile (Conv.toString path)
          case baseFile of
            Just file ->
              (,)
                <$> SBOMCfg.getProjectRevision (SBOMCfg.SBOMFile (toText file)) projectOverride ReadOnly
                <*> pure (SBOMBase file)
            Nothing -> Diag.fatalText $ "No such file or directory " <> path

newtype NoFormatProvided = NoFormatProvided SourceLocation
instance ToDiagnostic NoFormatProvided where
  renderDiagnostic :: NoFormatProvided -> Errata
  renderDiagnostic (NoFormatProvided srcLoc) =
    errataSimple (Just "No format provided") (createEmptyBlock srcLoc) Nothing

data InvalidReportFormat = InvalidReportFormat SourceLocation String
instance ToDiagnostic InvalidReportFormat where
  renderDiagnostic :: InvalidReportFormat -> Errata
  renderDiagnostic (InvalidReportFormat srcLoc fmt) = do
    let header = "Report format: " <> toText fmt <> " is not supported"
    errataSimple (Just header) (createEmptyBlock srcLoc) Nothing

data ReportErrorHelp = ReportErrorHelp
instance ToDiagnostic ReportErrorHelp where
  renderDiagnostic :: ReportErrorHelp -> Errata
  renderDiagnostic ReportErrorHelp = do
    let header = "Provide a supported format via '--format'. Supported formats: " <> (toText reportOutputFormatList)
    Errata (Just header) [] Nothing

validateOutputFormat :: Has Diagnostics sig m => Bool -> Maybe String -> m ReportOutputFormat
validateOutputFormat True _ = pure ReportJson
validateOutputFormat False Nothing = errHelp ReportErrorHelp $ fatal $ NoFormatProvided getSourceLocation
validateOutputFormat False (Just format) = errHelp ReportErrorHelp $ fromMaybe (InvalidReportFormat getSourceLocation format) $ parseReportOutputFormat format

data ReportConfig = ReportConfig
  { apiOpts :: ApiOpts
  , reportBase :: ReportBase
  , outputFormat :: ReportOutputFormat
  , timeoutDuration :: Duration
  , reportType :: ReportType
  , revision :: ProjectRevision
  }
  deriving (Eq, Ord, Show, Generic)

data ReportBase
  = SBOMBase (Path Abs File)
  | DirectoryBase (Path Abs Dir)
  deriving (Eq, Ord, Show, Generic)

instance ToJSON ReportBase where
  toEncoding = genericToEncoding defaultOptions

instance ToJSON ReportConfig where
  toEncoding = genericToEncoding defaultOptions
