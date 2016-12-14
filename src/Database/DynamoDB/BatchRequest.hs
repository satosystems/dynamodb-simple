{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE MultiWayIf          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE ViewPatterns        #-}

module Database.DynamoDB.BatchRequest (
    putItemBatch
  , getItemBatch
  , deleteItemBatchByKey
  , leftJoin
  , innerJoin
) where

import           Control.Arrow                       (second)
import           Control.Concurrent                  (threadDelay)
import           Control.Lens                        (at, ix, (.~), (^.), (^..), _2, sequenceOf)
import           Control.Monad                       (unless)
import           Control.Monad.Catch                 (throwM)
import           Control.Monad.IO.Class              (liftIO)
import           Data.Function                       ((&))
import           Data.HashMap.Strict                 (HashMap)
import qualified Data.HashMap.Strict                 as HMap
import           Data.List.NonEmpty                  (NonEmpty(..))
import           Data.Maybe                          (mapMaybe)
import           Data.Monoid                         ((<>))
import           Data.Proxy
import qualified Data.Text                           as T
import           Generics.SOP
import           Network.AWS
import qualified Network.AWS.DynamoDB.BatchGetItem   as D
import qualified Network.AWS.DynamoDB.BatchWriteItem as D
import qualified Network.AWS.DynamoDB.Types          as D
import qualified Data.Map.Strict as Map

import           Database.DynamoDB.Class
import           Database.DynamoDB.Internal
import           Database.DynamoDB.Types



-- | Retry batch operation, until unprocessedItems is empty.
--
-- TODO: we should use exponential backoff; currently we use a simple 1-sec threadDelay
retryWriteBatch :: MonadAWS m => D.BatchWriteItem -> m ()
retryWriteBatch cmd = do
  rs <- send cmd
  let unprocessed = rs ^. D.bwirsUnprocessedItems
  unless (null unprocessed) $ do
      liftIO $ threadDelay 1000000
      retryWriteBatch (cmd & D.bwiRequestItems .~ unprocessed)

-- | Retry batch operation, until unprocessedItems is empty.
--
-- TODO: we should use exponential backoff; currently we use a simple 1-sec threadDelay
retryReadBatch :: MonadAWS m => D.BatchGetItem -> m (HashMap T.Text [HashMap T.Text D.AttributeValue])
retryReadBatch = go mempty
  where
    go previous cmd = do
      rs <- send cmd
      let unprocessed = rs ^. D.bgirsUnprocessedKeys
          result = HMap.unionWith (++) previous (rs ^. D.bgirsResponses)
      if | null unprocessed -> return result
         | otherwise -> do
              liftIO $ threadDelay 1000000
              go result (cmd & D.bgiRequestItems .~ unprocessed)

-- | Chunk list according to batch operation limit
chunkBatch :: Int -> [a] -> [NonEmpty a]
chunkBatch limit (splitAt limit -> (x:xs, rest)) = (x :| xs) : chunkBatch limit rest
chunkBatch _ _ = []

-- | Batch write into the database.
--
-- The batch is divided to 25-item chunks, each is sent and retried separately.
-- If a batch fails on dynamodb exception, it is raised.
--
-- Note: On exception, the information about which items were saved is unavailable
putItemBatch :: forall m a r. (MonadAWS m, DynamoTable a r) => [a] -> m ()
putItemBatch lst = mapM_ go (chunkBatch 25 lst)
  where
    go items = do
      let tblname = tableName (Proxy :: Proxy a)
          wrequests = fmap mkrequest items
          mkrequest item = D.writeRequest & D.wrPutRequest .~ Just (D.putRequest & D.prItem .~ gsEncode item)
          cmd = D.batchWriteItem & D.bwiRequestItems . at tblname .~ Just wrequests
      retryWriteBatch cmd


-- | Get batch of items.
getItemBatch :: forall m a r range hash rest.
    (MonadAWS m, DynamoTable a r, HasPrimaryKey a r 'IsTable, Code a ~ '[ hash ': range ': rest])
    => Consistency -> [PrimaryKey a r] -> m [a]
getItemBatch consistency lst = concat <$> mapM go (chunkBatch 100 lst)
  where
    go keys = do
        let tblname = tableName (Proxy :: Proxy a)
            wkaas = fmap (dKeyToAttr (Proxy :: Proxy a)) keys
            kaas = D.keysAndAttributes wkaas & D.kaaConsistentRead . consistencyL .~ consistency
            cmd = D.batchGetItem & D.bgiRequestItems . at tblname .~ Just kaas

        tbls <- retryReadBatch cmd
        mapM decoder (tbls ^.. ix tblname . traverse)
    decoder item =
        case gsDecode item of
          Just res -> return res
          Nothing -> throwM (DynamoException $ "Error decoding item: " <> T.pack (show item))

dDeleteRequest :: (HasPrimaryKey a r 'IsTable, Code a ~ '[ hash ': range ': xss ])
          => Proxy a -> PrimaryKey a r -> D.DeleteRequest
dDeleteRequest p pkey = D.deleteRequest & D.drKey .~ dKeyToAttr p pkey

-- | Batch version of 'deleteItemByKey'.
--
-- Note: Because the requests are chunked, the information about which items
-- were deleted in case of exception is unavailable.
deleteItemBatchByKey :: forall m a r range hash rest.
    (MonadAWS m, HasPrimaryKey a r 'IsTable, DynamoTable a r, Code a ~ '[ hash ': range ': rest])
    => Proxy a -> [PrimaryKey a r] -> m ()
deleteItemBatchByKey p lst = mapM_ go (chunkBatch 25 lst)
  where
    go keys = do
      let tblname = tableName p
          wrequests = fmap mkrequest keys
          mkrequest key = D.writeRequest & D.wrDeleteRequest .~ Just (dDeleteRequest p key)
          cmd = D.batchWriteItem & D.bwiRequestItems . at tblname .~ Just wrequests
      retryWriteBatch cmd

-- | Return all rows from the left side of the tuple, replace right side by joined data from database.
--
-- The 'foreign key' must have an 'Ord' to facilitate faster searching
leftJoin :: forall a m r hash range rest b.
    (MonadAWS m, DynamoTable a r, HasPrimaryKey a r 'IsTable, Code a ~ '[ hash ': range ': rest],
      Ord (PrimaryKey a r), ContainsTableKey a a (PrimaryKey a r))
    => Consistency
    -> Proxy a -- ^ Proxy type for the right table
    -> [(b, PrimaryKey a r)]   -- ^ Left table + primary key for the right table
    -> m [(b, Maybe a)]               -- ^ Left table + value from right table, if found
leftJoin consistency _ input = do
  rightTbl <- getItemBatch consistency (map snd input)
  let resultMap = Map.fromList $ map (\res -> (dTableKey res,res)) rightTbl
  return $ map (second (`Map.lookup` resultMap)) input

-- | Return rows that are present in both tables
innerJoin :: forall a m r hash range rest b.
    (MonadAWS m, DynamoTable a r, HasPrimaryKey a r 'IsTable, Code a ~ '[ hash ': range ': rest],
      Ord (PrimaryKey a r), ContainsTableKey a a (PrimaryKey a r))
    => Consistency -> Proxy a -> [(b, PrimaryKey a r)] -> m [(b, a)]
innerJoin consistency p input = do
  res <- leftJoin consistency p input
  return $ mapMaybe (sequenceOf _2) res
