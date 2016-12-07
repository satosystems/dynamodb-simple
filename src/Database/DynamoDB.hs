{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE MultiWayIf          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}

-- |
-- Module      : Data.DynamoDb
-- License     : BSD-style
--
-- Maintainer  : palkovsky.ondrej@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- Type-safe library for accessing DynamoDB database.
--
module Database.DynamoDB (
    -- * Introduction
    -- $intro

    -- * Data types
    DynamoException(..)
  , Consistency(..)
  , Direction(..)
  , Column
    -- * Attribute path combinators
    , (<.>), (<!>), (<!:>)
    -- * Fetching items
  , getItem
  , getItemBatch
    -- * Query options
  , QueryOpts
  , queryOpts
  , qConsistentRead, qStartKey, qDirection, qFilterCondition, qHashKey, qRangeCondition, qLimit
    -- * Performing query
  , query
  , querySimple
  , queryCond
  , querySource
    -- * Scan options
  , ScanOpts
  , scanOpts
  , sFilterCondition, sConsistentRead, sLimit, sParallel, sStartKey
    -- * Performing scan
  , scan
  , scanSource
  , scanCond
    -- * Data entry
  , putItem
  , putItemBatch
  , insertItem
    -- * Data modification
  , updateItemByKey
  , updateItemByKey_
  , updateItemCond_
    -- * Deleting data
  , deleteItemByKey
  , deleteItemCondByKey
  , deleteItemBatchByKey
    -- * Delete table
  , deleteTable
    -- * Utility functions
  , itemToKey
) where

import           Control.Lens                        ((%~), (.~), (^.))
import           Control.Monad                       (void)
import           Control.Monad.Catch                 (throwM)
import           Data.Bool                           (bool)
import           Data.Function                       ((&))
import           Data.Proxy
import           Data.Semigroup                      ((<>))
import qualified Data.Text                           as T
import           Generics.SOP
import           Network.AWS
import qualified Network.AWS.DynamoDB.DeleteItem     as D
import qualified Network.AWS.DynamoDB.GetItem        as D
import qualified Network.AWS.DynamoDB.PutItem        as D
import qualified Network.AWS.DynamoDB.UpdateItem     as D
import qualified Network.AWS.DynamoDB.DeleteTable    as D
import qualified Network.AWS.DynamoDB.Types    as D

import           Database.DynamoDB.Class
import           Database.DynamoDB.Filter
import           Database.DynamoDB.Internal
import           Database.DynamoDB.Types
import           Database.DynamoDB.Update
import           Database.DynamoDB.BatchRequest
import           Database.DynamoDB.QueryRequest


dDeleteItem :: (DynamoTable a r, HasPrimaryKey a r 'IsTable, Code a ~ '[ hash ': range ': xss ])
          => Proxy a -> PrimaryKey (Code a) r -> D.DeleteItem
dDeleteItem p pkey = D.deleteItem (tableName p) & D.diKey .~ dKeyToAttr p pkey

dGetItem :: (DynamoTable a r, HasPrimaryKey a r 'IsTable, Code a ~ '[ hash ': range ': xss ])
          => Proxy a -> PrimaryKey (Code a) r -> D.GetItem
dGetItem p pkey = D.getItem (tableName p) & D.giKey .~ dKeyToAttr p pkey

-- | Write item into the database; overwrite any previously existing item with the same primary key.
putItem :: (MonadAWS m, DynamoTable a r) => a -> m ()
putItem item = void $ send (dPutItem item)

-- | Write item into the database only if it doesn't already exist.
insertItem  :: forall a r m. (MonadAWS m, DynamoTable a r) => a -> m ()
insertItem item = do
  let keyfields = primaryFields (Proxy :: Proxy a)
      -- Create condition attribute_not_exist(hash_key)
      pkeyMissing = (AttrMissing . nameGenPath . pure . IntraName) $ head keyfields
      (expr, attnames, attvals) = dumpCondition pkeyMissing
      cmd = dPutItem item & D.piExpressionAttributeNames .~ attnames
                          & D.piConditionExpression .~ Just expr
                          & bool (D.piExpressionAttributeValues .~ attvals) id (null attvals) -- HACK; https://github.com/brendanhay/amazonka/issues/332
  void $ send cmd


-- | Read item from the database; primary key is either a hash key or (hash,range) tuple depending on the table.
getItem :: forall m a r range hash rest.
    (MonadAWS m, DynamoTable a r, HasPrimaryKey a r 'IsTable, Code a ~ '[ hash ': range ': rest])
    => Proxy a -> Consistency -> PrimaryKey (Code a) r -> m (Maybe a)
getItem p consistency key = do
  let cmd = dGetItem p key & D.giConsistentRead . consistencyL .~ consistency
  rs <- send cmd
  let result = rs ^. D.girsItem
  if | null result -> return Nothing
     | otherwise ->
          case gsDecode result of
              Just res -> return (Just res)
              Nothing -> throwM (DynamoException $ "Cannot decode item: " <> T.pack (show result))

-- | Delete item from the database by specifying the primary key.
deleteItemByKey :: forall m a r hash range rest.
    (MonadAWS m, HasPrimaryKey a r 'IsTable, DynamoTable a r, Code a ~ '[ hash ': range ': rest])
    => (Proxy a, PrimaryKey (Code a) r) -> m ()
deleteItemByKey (p, pkey) = void $ send (dDeleteItem p pkey)

-- | Delete item from the database by specifying the primary key and a condition.
-- Throws AWS exception if the condition does not succeed.
deleteItemCondByKey :: forall m a r hash range rest.
    (MonadAWS m, HasPrimaryKey a r 'IsTable, DynamoTable a r, Code a ~ '[ hash ': range ': rest])
    => (Proxy a, PrimaryKey (Code a) r) -> FilterCondition a -> m ()
deleteItemCondByKey (p, pkey) cond =
    let (expr, attnames, attvals) = dumpCondition cond
        cmd = dDeleteItem p pkey & D.diExpressionAttributeNames .~ attnames
                                 & bool (D.diExpressionAttributeValues .~ attvals) id (null attvals) -- HACK; https://github.com/brendanhay/amazonka/issues/332
                                 & D.diConditionExpression .~ Just expr
    in void (send cmd)

-- | Generate update item object; automatically adds condition for existence of primary
-- key, so that only existing objects are modified
dUpdateItem :: forall a r hash range xss.
            (DynamoTable a r, HasPrimaryKey a r 'IsTable, Code a ~ '[ hash ': range ': xss ])
          => Proxy a -> PrimaryKey (Code a) r -> Action a -> Maybe (FilterCondition a) ->  Maybe D.UpdateItem
dUpdateItem p pkey actions mcond =
    genAction <$> dumpActions actions
  where
    keyfields = primaryFields p
        -- Create condition attribute_exists(hash_key)
    pkeyExists = (AttrExists . nameGenPath . pure . IntraName) (head keyfields)

    genAction actparams =
        D.updateItem (tableName p) & D.uiKey .~ dKeyToAttr p pkey
                                   & addActions actparams
                                   & addCondition (Just pkeyExists <> mcond)

    addActions (expr, attnames, attvals) =
          (D.uiUpdateExpression .~ Just expr)
            . (D.uiExpressionAttributeNames %~ (<> attnames))
            . bool (D.uiExpressionAttributeValues %~ (<> attvals)) id (null attvals)
    addCondition (Just cond) =
        let (expr, attnames, attvals) = dumpCondition cond
        in  (D.uiConditionExpression .~ Just expr)
            . (D.uiExpressionAttributeNames %~ (<> attnames))
            . bool (D.uiExpressionAttributeValues %~ (<> attvals)) id (null attvals) -- HACK; https://github.com/brendanhay/amazonka/issues/332
    addCondition Nothing = id -- Cannot happen anyway


-- | Update item in a table
--
-- > updateItem (Proxy :: Proxy Test) (12, "2") [colCount +=. 100]
updateItemByKey_ :: forall a m r hash range rest.
      (MonadAWS m, HasPrimaryKey a r 'IsTable, DynamoTable a r, Code a ~ '[ hash ': range ': rest ])
    => (Proxy a, PrimaryKey (Code a) r) -> Action a -> m ()
updateItemByKey_ (p, pkey) actions
  | Just cmd <- dUpdateItem p pkey actions Nothing = void $ send cmd
  | otherwise = return ()

updateItemByKey :: forall a m r hash range rest.
      (MonadAWS m, HasPrimaryKey a r 'IsTable, DynamoTable a r, Code a ~ '[ hash ': range ': rest ])
    => (Proxy a, PrimaryKey (Code a) r) -> Action a -> m a
updateItemByKey (p, pkey) actions
  | Just cmd <- dUpdateItem p pkey actions Nothing = do
        rs <- send (cmd & D.uiReturnValues .~ Just D.AllNew)
        case gsDecode (rs ^. D.uirsAttributes) of
            Just res -> return res
            Nothing -> throwM (DynamoException $ "Cannot decode item: " <> T.pack (show rs))
  | otherwise = do
      rs <- getItem p Strongly pkey
      case rs of
          Just res -> return res
          Nothing -> throwM (DynamoException "Cannot decode item.")

-- | Update item in a table while specifying a condition
updateItemCond_ :: forall a m r hash range rest.
      (MonadAWS m, DynamoTable a r, HasPrimaryKey a r 'IsTable, Code a ~ '[ hash ': range ': rest ])
    => (Proxy a, PrimaryKey (Code a) r) -> Action a -> FilterCondition a -> m ()
updateItemCond_ (p, pkey) actions cond
  | Just cmd <- dUpdateItem p pkey actions (Just cond) = void $ send cmd
  | otherwise = return ()

-- | Delete table from DynamoDB.
deleteTable :: (MonadAWS m, DynamoTable a r) => Proxy a -> m ()
deleteTable p = void $ send (D.deleteTable (tableName p))

-- | Extract primary key from a record in a form that can be directly used by other functions.
--
-- TODO: this should be callable on index structures containing primary key as well
itemToKey :: (HasPrimaryKey a r t, Code a ~ '[hash ': range ': xss]) => a -> (Proxy a, PrimaryKey (Code a) r)
itemToKey a = (Proxy, dItemToKey a)

-- $intro
--
-- This library is operated in the following way:
--
-- * Create instances for your custom types using "Database.DynamoDB.Types"
-- * Create ordinary datatypes with records
-- * Use functions from "Database.DynamoDB.TH" to derive appropriate instances
-- * Optionally call generated migration function to automatically create
--   tables and indices
-- * Call functions from this module to access the database
--
-- The library does its best to ensure that only correct DynamoDB
-- operations are allowed. There are some limitations of DynamoDB
-- regarding access to empty values, but the library takes care
-- of this reasonably well.
--
-- Example of use
--
-- You may need to set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment
-- variables.
--
-- @
-- data Test = Test {
--     category :: T.Text
--   , messageid :: T.Text
--   , subject :: T.Text
-- } deriving (Show)
-- mkTableDefs "migrate" (tableConfig (''Test, WithRange) [] [])
-- @
--
-- This code creates appropriate instances for the table and the columns. It creates
-- global variables `colCategory`, `colMessageid` and `colSubject` that can be used
-- in filtering conditions or update queries.
--
-- @
-- main = do
--    lgr <- newLogger Info stdout
--    env <- newEnv NorthVirginia Discover
--    -- Override, use DynamoDD on localhost
--    let dynamo = setEndpoint False "localhost" 8000 dynamoDB
--    let newenv = env & configure dynamo
--                     & set envLogger lgr
--    runResourceT $ runAWS newenv $ do
--        -- Create tables and indexes
--        migrate mempty Nothing
--        -- Save data to database
--        putItem (Test "news" "1-2-3-4" "New subject")
--        -- Fetch data given primary key
--        item <- getItem Eventually ("news", "1-2-3-4")
--        liftIO $ print item -- (item :: Maybe Test)
--        -- Scan data using filter condition, return 10 results
--        items <- scanCond tTest (subject' ==. "New subejct") 10
--        print items -- (items :: [Test])
-- @
--
-- See examples/ and test/ directories for more detail examples.
