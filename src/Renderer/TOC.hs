module Renderer.TOC (toc, diffTOC, JSONSummary(..), Summarizable(..), isErrorSummary) where

import Category as C
import Data.Aeson
import Data.Functor.Both hiding (fst, snd)
import qualified Data.Functor.Both as Both
import Data.Text (toLower)
import Data.Record
import Diff
import Info
import Prologue
import Renderer.Summary (Summaries(..))
import qualified Data.List as List
import qualified Data.Map as Map hiding (null)
import Source hiding (null)
import Syntax as S
import Term
import Patch

data JSONSummary = JSONSummary { info :: Summarizable }
                 | ErrorSummary { error :: Text, errorSpan :: SourceSpan }
                 deriving (Generic, Eq, Show)

instance ToJSON JSONSummary where
  toJSON JSONSummary{..} = object $ case info of
    InSummarizable{..} -> [ "changeType" .= ("modified" :: Text), "category" .= toCategoryName parentCategory, "term" .= parentTermName, "span" .= parentSourceSpan ]
    Summarizable{..} -> [ "changeType" .= summarizableChangeType, "category" .= toCategoryName summarizableCategory, "term" .= summarizableTermName, "span" .= summarizableSourceSpan ]
  toJSON ErrorSummary{..} = object [ "error" .= error, "span" .= errorSpan ]

isErrorSummary :: JSONSummary -> Bool
isErrorSummary ErrorSummary{} = True
isErrorSummary _ = False

data DiffInfo = DiffInfo
  { infoCategory :: Maybe Category
  , infoName :: Text
  , infoSpan :: SourceSpan
  }
  deriving (Eq, Show)

data TOCSummary a
  = TOCSummary
    { summaryPatch :: Patch a
    , parentInfo :: Maybe Summarizable
    }
  deriving (Eq, Functor, Show, Generic)

data Summarizable
  = Summarizable
    { summarizableCategory :: Category
    , summarizableTermName :: Text
    , summarizableSourceSpan :: SourceSpan
    , summarizableChangeType :: Text
    }
  | InSummarizable
    { parentCategory :: Category
    , parentTermName :: Text
    , parentSourceSpan :: SourceSpan
    }
  deriving (Eq, Show)

toc :: HasDefaultFields fields => Both SourceBlob -> Diff (Syntax Text) (Record fields) -> Summaries
toc blobs diff = Summaries changes errors
  where
    changes = if null changes' then mempty else Map.singleton summaryKey (toJSON <$> changes')
    errors = if null errors' then mempty else Map.singleton summaryKey (toJSON <$> errors')
    (errors', changes') = List.partition isErrorSummary summaries
    summaries = diffTOC blobs diff

    summaryKey = toS $ case runJoin (path <$> blobs) of
      (before, after) | null before -> after
                      | null after -> before
                      | before == after -> after
                      | otherwise -> before <> " -> " <> after

diffTOC :: HasDefaultFields fields => Both SourceBlob -> Diff (Syntax Text) (Record fields) -> [JSONSummary]
diffTOC blobs diff = removeDupes (diffToTOCSummaries (source <$> blobs) diff) >>= toJSONSummaries
  where
    removeDupes :: [TOCSummary DiffInfo] -> [TOCSummary DiffInfo]
    removeDupes = foldl' go []
      where
        go xs x | (_, _ : _) <- find exactMatch x xs = xs
                | (front, TOCSummary _ (Just info) : back) <- find similarMatch x xs =
                  front <> (x { parentInfo = Just (info { summarizableChangeType = "modified" }) } : back)
                | otherwise = xs <> [x]
        find p x = List.break (p x)
        exactMatch a b = parentInfo a == parentInfo b
        similarMatch a b = case (parentInfo a, parentInfo b) of
          (Just (Summarizable catA nameA _ _), Just (Summarizable catB nameB _ _)) -> catA == catB && toLower nameA == toLower nameB
          (_, _) -> False

    diffToTOCSummaries :: HasDefaultFields fields => Both Source -> Diff (Syntax Text) (Record fields) -> [TOCSummary DiffInfo]
    diffToTOCSummaries sources = para $ \diff -> case diff of
        Free (Join (_, annotation) :< syntax)
          | isSummarizable syntax
          , Just termName <- toTermName (Both.snd sources) . cofree . (annotation :<) <$> traverse (afterTerm . fst) syntax
          , parentInfo <- InSummarizable (category annotation) termName (sourceSpan annotation) ->
            foldMap (fmap (contextualize parentInfo) . snd) syntax
          | otherwise -> foldMap snd syntax
        Pure patch -> fmap summarize (sequenceA (runBothWith mapPatch (toInfo <$> sources) patch))

    toInfo :: HasDefaultFields fields => Source -> Term (Syntax Text) (Record fields) -> [DiffInfo]
    toInfo source = para $ \ (annotation :< syntax) -> let termName = toTermName source (cofree (annotation :< fmap fst syntax)) in case syntax of
      S.ParseError{} -> [DiffInfo Nothing termName (sourceSpan annotation)]
      S.Indexed{} -> foldMap snd syntax
      S.Fixed{} -> foldMap snd syntax
      S.Commented{} -> foldMap snd syntax
      S.AnonymousFunction{} -> [DiffInfo (Just C.AnonymousFunction) termName (sourceSpan annotation)]
      _ -> [DiffInfo (Just (category annotation)) termName (sourceSpan annotation)]

    summarize patch = TOCSummary patch (infoCategory >>= summarizable)
      where DiffInfo{..} = afterOrBefore patch
            summarizable category = Summarizable category infoName infoSpan (patchType patch) <$ find (category ==) [C.Function, C.Method, C.SingletonMethod]

    contextualize info summary = summary { parentInfo = Just (fromMaybe info (parentInfo summary)) }

    isSummarizable S.Method{} = True
    isSummarizable S.Function{} = True
    isSummarizable _ = False

toJSONSummaries :: TOCSummary DiffInfo -> [JSONSummary]
toJSONSummaries TOCSummary{..} = case infoCategory of
  Nothing -> [ErrorSummary infoName infoSpan]
  _ -> maybe [] (pure . JSONSummary) parentInfo
  where DiffInfo{..} = afterOrBefore summaryPatch

toTermName :: HasDefaultFields fields => Source -> Term (Syntax Text) (Record fields) -> Text
toTermName source = para $ \ (annotation :< syntax) -> case syntax of
  S.Function (_, identifier) _ _ -> identifier
  S.Method _ (_, identifier) Nothing _ _ -> identifier
  S.Method _ (_, identifier) (Just (receiver, receiverSource)) _ _
    | S.Indexed [receiverParams] <- unwrap receiver
    , S.ParameterDecl (Just ty) _ <- unwrap receiverParams -> "(" <> toTermName source ty <> ") " <> identifier
    | otherwise -> receiverSource <> "." <> identifier
  _ -> toText (Source.slice (byteRange annotation) source)

-- The user-facing category name
toCategoryName :: Category -> Text
toCategoryName category = case category of
  C.SingletonMethod -> "Method"
  c -> show c
