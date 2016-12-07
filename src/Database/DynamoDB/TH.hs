{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}

-- | Template Haskell macros to automatically derive instances, create column datatypes
--  and create migrations functions.
--
module Database.DynamoDB.TH (
    -- * Derive instances for table and indexes
    -- $table

    -- * Derive instances for nested records
    -- $nested

    -- * Sparse indexes
    -- $sparse

    -- * Main table definition
    mkTableDefs
  , TableConfig(..)
  , tableConfig
  , defaultTranslate
    -- * Nested structures
  , deriveCollection
  , deriveEncodable
    -- * Data types
  , RangeType(..)
) where

import           Control.Lens                    (ix, over, (.~), (^.), _1, view)
import           Control.Monad                   (forM_, when)
import           Control.Monad.Trans.Class       (lift)
import           Control.Monad.Trans.Writer.Lazy (WriterT, execWriterT, tell)
import           Data.Bool                       (bool)
import           Data.Char                       (toUpper)
import           Data.Function                   ((&))
import           Data.Monoid                     ((<>))
import qualified Data.Text                       as T
import           Data.HashMap.Strict             (HashMap)
import           Generics.SOP
import           Generics.SOP.TH                 (deriveGenericOnly)
import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax      (Name (..), OccName (..))
import           Network.AWS.DynamoDB.Types      (attributeValue, avM, ProvisionedThroughput, StreamViewType)
import           Network.AWS                     (MonadAWS)

import           Database.DynamoDB.Class
import           Database.DynamoDB.Migration     (runMigration)
import           Database.DynamoDB.Types
import           Database.DynamoDB.Internal

-- | Configuration of TH macro for creating table instances
data TableConfig = TableConfig {
    tableSetup :: (Name, RangeType, String)       -- ^ Table type, primary key type, table name
  , globalIndexes :: [(Name, RangeType, String)]  -- ^ Global index type, primary key type, index name
  , localIndexes :: [(Name, String)]              -- ^ Local index type, index name
  , translateField :: String -> String            -- ^ Translation of haskell field names to DynamoDB attribute names
}

-- | Simple table configuration
tableConfig ::
     (Name, RangeType)   -- ^ Table type name, primary key type
  -> [(Name, RangeType)] -- ^ Global secondary index records, index key type
  -> [Name] -- ^ Local secondary index records
  -> TableConfig
tableConfig (table, tbltype) globidx locidx =
    TableConfig {
        tableSetup = (table, tbltype, nameToStr table)
      , globalIndexes = map (\(n,r) -> (n, r, nameToStr n)) globidx
      , localIndexes = map (\n -> (n, nameToStr n)) locidx
      , translateField = defaultTranslate
    }
  where
    nameToStr (Name (OccName name) _) = name

-- | Translates haskell field names to database attribute names. Strips everything up to first '_'.
defaultTranslate :: String -> String
defaultTranslate = translate
  where
    translate ('_':rest) = rest
    translate name
      | '_' `elem` name = drop 1 $ dropWhile (/= '_') name
      | otherwise = name

-- | Create instances, datatypes for table, fields and instances.
--
-- Example of what gets created:
--
-- > data Test { first :: Text, second :: Text, third :: Int }
-- > data TestIndex { third :: Int, second :: T.Text}
-- >
-- > mkTableDefs (tableConfig (''Test, WithRange) [(''TestIndex, NoRange)] [])
-- >
-- > deriveGenericOnly ''Test
-- > instance DynamoCollection Test WithRange IsTable
-- > ...
-- > instance DynamoTable Test WithRange
-- >    tableName _ = "Test"
-- >
-- > deriveGenericOnly ''TestIndex
-- > instance DynamoCollection TestIndex NoRange IsIndex
-- > ...
-- > instance DynamoIndex TestIndex Test NoRange IsIndex
-- >    indexName _ = "TestIndex"
-- >
-- > data P_First
-- > instance ColumnInfo P_First where
-- >     columnName _ = "first"
-- > instance InCollection P_First Test 'NestedPath -- For every attribute
-- > instance InCollection P_Second TestIndex 'FullPath -- For every non-primary attribute
-- > first' :: Column Text TypColumn P_First
-- > first' = Column
mkTableDefs ::
    String -- ^ Name of the migration function
  -> TableConfig
  -> Q [Dec]
mkTableDefs migname TableConfig{..} =
  execWriterT $ do
    let (table, tblrange, tblname) = tableSetup

    tblFieldNames <- getFieldNames table translateField
    let tblHashName = fst (head tblFieldNames)
    buildColData tblFieldNames
    genBaseCollection table tblrange tblname Nothing translateField

    -- Check, that hash key name in locindexes == hash key in primary table
    forM_ localIndexes $ \(idx, _) -> do
        idxHashName <- (fst . head) <$> getFieldNames idx translateField
        when (idxHashName /= tblHashName) $
            fail ("Hash key " <> show idxHashName <> " in local index " <> show idx
                  <> " is not equal to table hash key " <> show tblHashName)

    -- Instances for indices
    let allindexes = globalIndexes ++ map (\(idx,name) -> (idx, WithRange, name)) localIndexes
    forM_ allindexes $ \(idx, idxrange, idxname) -> do
        genBaseCollection idx idxrange idxname (Just table) translateField
        -- Check that all records from indices conform to main table and create instances
        instfields <- getFieldNames idx translateField
        let pkeytable = [True | _ <- [1..(pkeySize idxrange)] ] ++ repeat False
        forM_ (zip instfields pkeytable) $ \((fieldname, ltype), isKey) ->
            case lookup fieldname tblFieldNames of
                Just (AppT (ConT mbtype) inptype)
                  | mbtype == ''Maybe && inptype == ltype && isKey -> return () -- Allow sparse index - 'Maybe a' in table, 'a' in index
                Just ptype
                  | ltype /= ptype -> fail $ "Record '" <> fieldname <> "' form index " <> show idx <> " has different type from table " <> show table
                                              <> ": " <> show ltype <> " /= " <> show ptype
                  | otherwise -> return ()
                Nothing ->
                  fail ("Record '" <> fieldname <> "' from index " <> show idx <> " is not in present in table " <> show table)

    migfunc <- lift $ mkMigrationFunc migname table (map (view _1) globalIndexes) (map (view _1) localIndexes)
    tell migfunc

pkeySize :: RangeType -> Int
pkeySize WithRange = 2
pkeySize NoRange = 1

-- | Generate basic collection instances
genBaseCollection :: Name -> RangeType -> String -> Maybe Name -> (String -> String) -> WriterT [Dec] Q ()
genBaseCollection coll collrange tblname mparent translate = do
    tblFieldNames <- getFieldNames coll translate
    let fieldNames = map fst tblFieldNames
    let fieldList = pure (ListE (map (AppE (VarE 'T.pack) . LitE . StringL) fieldNames))
    primaryList' <- case (collrange, fieldNames) of
                      (NoRange, hashname:_) -> return [hashname]
                      (WithRange, h:r:_)-> return [h,r]
                      _ -> fail "Table must have at least 1/2 fields based on range key"
    let primaryList = pure (ListE (map (AppE (VarE 'T.pack) . LitE . StringL) primaryList'))
    let tbltype = maybe (PromotedT 'IsTable) (const $ PromotedT 'IsIndex) mparent

    lift (deriveGenericOnly coll) >>= tell
    lift [d|
      instance DynamoCollection $(pure (ConT coll)) $(pure (ConT $ mrange collrange)) $(pure tbltype) where
          allFieldNames _ = $(fieldList)
          primaryFields _ = $(primaryList)
      |] >>= tell
    case mparent of
      Nothing -> do
         mkCollectionProxy True
         -- $(varP proxyName) = Proxy
         lift [d|
             instance DynamoTable $(conT coll) $(conT $ mrange collrange) where
                tableName _ = $(appE (varE 'T.pack) (litE (StringL tblname)))
              |] >>= tell
      Just parent -> do
        mkCollectionProxy False
        lift [d|
            instance DynamoIndex $(pure (ConT coll)) $(pure (ConT parent)) $(pure (ConT $ mrange collrange)) where
                indexName _ = $(pure $ AppE (VarE 'T.pack) (LitE (StringL tblname)))
              |] >>= tell

    -- Skip primary key, we cannot filter by it
    let constrNames = mkConstrNames tblFieldNames
    forM_ (drop (pkeySize collrange) constrNames) $ \constr ->
      lift [d|
        instance InCollection $(pure (ConT constr)) $(pure (ConT coll)) 'FullPath
        |] >>= tell
  where
    mrange WithRange = 'WithRange
    mrange NoRange = 'NoRange
    mkCollectionProxy istable = do
        let proxyName = mkName (bool "i" "t" istable <> nameBase coll)
        say $ SigD proxyName (AppT (ConT ''Proxy) (ConT coll))
        say $ ValD (VarP proxyName) (NormalB (ConE 'Proxy)) []


-- | Reify name and return list of record fields with type
getFieldNames :: Name -> (String -> String) -> WriterT [Dec] Q [(String, Type)]
getFieldNames tbl translate = do
    info <- lift $ reify tbl
    case getRecords info of
      Left err -> fail $ "Table " <> show tbl <> ": " <> err
      Right lst -> return $ map (over _1 translate) lst
  where
    getRecords :: Info -> Either String [(String, Type)]
#if __GLASGOW_HASKELL__ >= 800
    getRecords (TyConI (DataD _ _ _ _ [RecC _ vars] _)) = Right $ map (\(Name (OccName rname) _,_,typ) -> (rname, typ)) vars
#else
    getRecords (TyConI (DataD _ _ _ [RecC _ vars] _)) = Right $ map (\(Name (OccName rname) _,_,typ) -> (rname, typ)) vars
#endif
    getRecords _ = Left "not a record declaration with 1 constructor"

toConstrName :: String -> String
toConstrName = ("P_" <>) . over (ix 0) toUpper

mkConstrNames :: [(String,a)] -> [Name]
mkConstrNames = map (mkName . toConstrName . fst)

-- | Build P_Column data, add it to instances and make column' variable
buildColData :: [(String, Type)] -> WriterT [Dec] Q ()
buildColData fieldlist = do
    let constrNames = mkConstrNames fieldlist
    forM_ (zip fieldlist constrNames) $ \((fieldname, ltype), constr) -> do
        let pat = mkName (fieldname <> "'")
#if __GLASGOW_HASKELL__ >= 800
        say $ DataD [] constr [] Nothing [] []
#else
        say $ DataD [] constr [] [] []
#endif
        lift [d|
            instance ColumnInfo $(pure (ConT constr)) where
                columnName _ = T.pack fieldname
          |] >>= tell
        say $ SigD pat (AppT (AppT (AppT (ConT ''Column) ltype) (ConT 'TypColumn)) (ConT constr))
        say $ ValD (VarP pat) (NormalB (VarE 'mkColumn)) []

say :: Monad m => t -> WriterT [t] m ()
say a = tell [a]

-- | Derive 'DynamoEncodable' and prepare column instances for nested structures.
deriveCollection :: Name -> (String -> String) -> Q [Dec]
deriveCollection table translate =
  execWriterT $ do
    lift (deriveGenericOnly table) >>= tell
    -- Create column data
    tblFieldNames <- getFieldNames table translate
    buildColData tblFieldNames
    -- Create instance DynamoEncodable
    deriveEncodable table translate

-- | Derive just the 'DynamoEncodable' instance
-- for structures that were already derived using 'mkTableDefs'
-- and you want to use them as nested structures as well.
--
-- Creates:
--
-- > instance DynamoEncodable Type where
-- >   dEncode val = Just (attributeValue & avM .~ gdEncodeG [fieldnames] val)
-- >   dDecode (Just attr) = gdDecodeG [fieldnames] (attr ^. avM)
-- >   dDecode Nothing = Nothing
-- > instance InCollection column_type P_Column1 'NestedPath
-- > instance InCollection column_type P_Column2 'NestedPath
-- > ...
deriveEncodable :: Name -> (String -> String) -> WriterT [Dec] Q ()
deriveEncodable table translate = do
    tblFieldNames <- getFieldNames table translate
    let fieldList = pure (ListE (map (AppE (VarE 'T.pack) . LitE . StringL . fst) tblFieldNames))
    lift [d|
      instance DynamoEncodable $(pure (ConT table)) where
          dEncode val = Just (attributeValue & avM .~ gsEncodeG $(fieldList) val)
          dDecode (Just attr) = gsDecodeG $(fieldList) (attr ^. avM)
          dDecode Nothing = Nothing
      |] >>= tell
    let constrs = mkConstrNames tblFieldNames
    forM_ constrs $ \constr ->
      lift [d|
        instance InCollection $(pure (ConT constr)) $(pure (ConT table)) 'NestedPath
        |] >>= tell

-- | Creates top-leval variable as a call to a migration function with partially applied createIndex
mkMigrationFunc :: String -> Name -> [Name] -> [Name] -> Q [Dec]
mkMigrationFunc name table globindexes locindexes = do
    let glMap = ListE (map glIdxTemplate globindexes)
        locMap = ListE (map locIdxTemplate locindexes)
    let funcname = mkName name
    m <- newName "m"
    let signature = SigD funcname (ForallT [PlainTV m] [AppT (ConT ''MonadAWS) (VarT m)]
                                  (AppT (AppT ArrowT (AppT (AppT (ConT ''HashMap) (ConT ''T.Text))
                                  (ConT ''ProvisionedThroughput)))
                                  (AppT (AppT ArrowT (AppT (ConT ''Maybe) (ConT ''StreamViewType)))
                                  (AppT (VarT m) (TupleT 0)))))
    return [signature, ValD (VarP funcname) (NormalB (AppE (AppE (AppE (VarE 'runMigration)
              (SigE (ConE 'Proxy)
              (AppT (ConT ''Proxy)
              (ConT table)))) glMap) locMap)) []]
  where
    glIdxTemplate idx = AppE (VarE 'createGlobalIndex) (SigE (ConE 'Proxy) (AppT (ConT ''Proxy) (ConT idx)))
    locIdxTemplate idx = AppE (VarE 'createLocalIndex) (SigE (ConE 'Proxy) (AppT (ConT ''Proxy) (ConT idx)))

-- $table
--
-- Use 'mkTableDefs' to derive everything about a table and its indexes. After running the function,
-- you will end up with lots of instances, data types for columns ('P_TId', 'P_TBase', 'P_TDescr')
-- and smart constructors for column ('colTId', 'colTBase', 'colTDescr', etc.) and one function (migrate)
-- that creates table and updates the indexes.
--
-- The migration function has signature:
--
-- >  MonadAWS m => HashMap T.Text ProvisionedThroughput -> Maybe StreamViewType -> m0 ()
--
-- * Table by default equals name of the type.
-- * Attribute name is a field name from a first underscore ('tId'). This should make it compatibile with lens.
-- * Column name is capitalized attribute name with prepended 'col' ('colTId')
-- * Attribute names in an index table must be the same as Attribute names in the main table
-- * Auxiliary datatype for column is P_ followed by capitalized attribute name ('P_TId')
--
-- @
-- data Test = Test {
--     _tId :: Int
--   , _tBase :: T.Text
--   , _tDescr :: T.Text
--   , _tDate :: T.Text
--   , _tDict :: HashMap T.Text Inner
-- } deriving (Show, GHC.Generic)
--
-- data TestIndex = TestIndex {
--   , i_tDate :: T.Text
--   , i_tDescr :: T.Text
-- } deriving (Show, GHC.Generic)
-- mkTableDefs "migrate" (tableConfig (''Test, WithRange) [(''TestIndex, NoRange)] [])
-- @
--

-- $nested
--
-- Use 'deriveCollection' for records that are nested. Use 'deriveEncodable' for records that are
-- nested in one table and serve as its own table at the same time.
--
-- @
-- data Book = Book {
--      author :: T.Text
--    , title :: T.Text
-- } deriving (Show)
-- $(deriveCollection ''Book defaultTranslate)
--
-- data Test = Test {
--     _tId :: Int
--   , _tBase :: T.Text
--   , _tBooks :: [Book]
-- } deriving (Show)
-- mkTableDefs "migrate" (tableConfig (''Test, WithRange) [] [])
-- @

-- $sparse
-- Define sparse index by defining the attribute as "Maybe" in the main table and
-- directly in the index table.
--
-- @
-- data Table {
--    hashKey :: UUID
--  , published :: Maybe UTCTime
--  , ...
-- }
-- data PublishedIndex {
--     published :: UTCTime
--  ,  hashKey :: UUID
--  ,  ...
-- }
-- mkTableDefs "migrate" (tableConfig (''Table, NoRange) [(''PublishedIndex, NoRange)] [])
-- @
--
