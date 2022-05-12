{-# LANGUAGE CPP                 #-}
#if __GLASGOW_HASKELL__ >= 800
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
#endif
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE MultiWayIf          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}

module Database.DynamoDB.QueryRequest (
  -- * Query
    query
  , query'
  , querySimple
  , queryCond
  , querySource
  , querySourceChunks
  , queryOverIndex
  , querySourceByKey
  -- * Scan
  , scan
  , scan'
  , scanCond
  , scanSource
  , scanSourceChunks
  -- * Query options
  , QueryOpts
  , queryOpts
  , qConsistentRead, qStartKey, qDirection, qFilterCondition, qHashKey, qRangeCondition, qLimit
  -- * Scan options
  , ScanOpts
  , scanOpts
  , sFilterCondition, sConsistentRead, sLimit, sParallel, sStartKey
  -- * Helper conduits
  , leftJoin
  , innerJoin
) where


import           Control.Arrow                  (first, second)
import           Control.Lens                   (Lens', sequenceOf, view, (%~),
                                                 (.~), (^.), _2)
import           Control.Lens.TH                (makeLenses)
import           Control.Monad                  ((>=>))
import           Control.Monad.Catch            (throwM)
import           Data.Bool                      (bool)
import           Data.Conduit                   (Conduit, Source, (=$=))
import qualified Data.Conduit.List              as CL
import           Data.Foldable                  (toList)
import           Data.Function                  ((&))
import           Data.HashMap.Strict            (HashMap)
import qualified Data.Map                       as Map
import           Data.Maybe                     (mapMaybe)
import           Data.Monoid                    ((<>))
import           Data.Proxy
import           Data.Sequence                  (Seq)
import qualified Data.Sequence                  as Seq
import qualified Data.Text                      as T
import           Generics.SOP
import           Network.AWS
import qualified Network.AWS.DynamoDB.Query     as D
import qualified Network.AWS.DynamoDB.Scan      as D
import qualified Network.AWS.DynamoDB.Types     as D
import           Numeric.Natural                (Natural)
import qualified Data.HashMap.Strict as HMap

import           Database.DynamoDB.BatchRequest (getItemBatch)
import           Database.DynamoDB.Class
import           Database.DynamoDB.Filter
import           Database.DynamoDB.Internal
import           Database.DynamoDB.Types

-- | Decode data, throw exception if decoding fails.
rsDecoder :: (MonadAWS m, DynamoCollection a r t)
    => HashMap T.Text D.AttributeValue -> m a
rsDecoder item =
  case dGsDecode item of
    Right res -> return res
    Left err -> throwM (DynamoException $ "Error decoding item: " <> err)

-- | Options for a generic query.
data QueryOpts a hash range = QueryOpts {
    _qHashKey :: hash
  , _qRangeCondition :: Maybe (RangeOper range)
  , _qFilterCondition :: Maybe (FilterCondition a)
  , _qConsistentRead :: Consistency
  , _qDirection :: Direction
  , _qLimit :: Maybe Natural -- ^ This sets the "D.qLimit" settings for maximum number of evaluated items
  , _qStartKey :: Maybe (hash, range)
  -- ^ Key after which the evaluation starts. When paging, this should be set to qrsLastEvaluatedKey
  -- of the last operation.
}
makeLenses ''QueryOpts
-- | Default settings for query options.
queryOpts :: hash -> QueryOpts a hash range
queryOpts key = QueryOpts key Nothing Nothing Eventually Forward Nothing Nothing

-- | Generate a "D.Query" object
queryCmd :: forall a t hash range. CanQuery a t hash range => QueryOpts a hash range -> D.Query
queryCmd q =
    dQueryKey (Proxy :: Proxy a) (q ^. qHashKey) (q ^. qRangeCondition)
                  & D.qConsistentRead . consistencyL .~ (q ^. qConsistentRead)
                  & D.qScanIndexForward .~ Just (q ^. qDirection == Forward)
                  & D.qLimit .~ (q ^. qLimit)
                  & addStartKey (q ^. qStartKey)
                  & addCondition (q ^. qFilterCondition)
  where
    addCondition Nothing = id
    addCondition (Just cond) =
      let (expr, attnames, attvals) = dumpCondition cond
      in (D.qExpressionAttributeNames %~ (<> attnames))
           -- HACK; https://github.com/brendanhay/amazonka/issues/332
         . bool (D.qExpressionAttributeValues %~ (<> attvals)) id (null attvals)
         . (D.qFilterExpression .~ Just expr)
    addStartKey Nothing = id
    addStartKey (Just (key, range)) =
        D.qExclusiveStartKey .~ dQueryKeyToAttr (Proxy :: Proxy a) (key, range)

-- | Same as 'querySource', but return data in original chunks.
querySourceChunks :: forall a t m hash range. (CanQuery a t hash range, MonadAWS m)
  => Proxy a -> QueryOpts a hash range -> Source m [a]
querySourceChunks _ q = paginate (queryCmd q) =$= CL.mapM (\res -> mapM rsDecoder (res ^. D.qrsItems))

-- | Generic query function. You can query table or indexes that have
-- a range key defined. The filter condition cannot access the hash and range keys.
querySource :: forall a t m hash range. (CanQuery a t hash range, MonadAWS m)
  => Proxy a -> QueryOpts a hash range -> Source m a
querySource p q = querySourceChunks p q =$= CL.concat


querySourceChunksByKey :: forall a parent hash rest v1 m r.
  (DynamoIndex a parent 'NoRange, Code a ~ '[ hash ': rest ], DynamoScalar v1 hash, MonadAWS m,
   DynamoTable parent r)
  => Proxy a -> hash -> Source m [a]
querySourceChunksByKey p key = paginate sQuery =$= CL.mapM (\res -> mapM rsDecoder (res ^. D.qrsItems))
  where
    sQuery = D.query (tableName (Proxy :: Proxy parent))
                                   & D.qKeyConditionExpression .~ Just "#K = :key"
                                   & D.qExpressionAttributeNames .~ HMap.singleton "#K" (head (allFieldNames p))
                                   & D.qExpressionAttributeValues .~ HMap.singleton ":key" (dScalarEncode key)
                                   & D.qIndexName .~ (Just $ indexName p)

-- | Conduit to query global indexes with no range key; in case anyone needed it
querySourceByKey :: forall a parent hash rest v1 m r.
  (DynamoIndex a parent 'NoRange, Code a ~ '[ hash ': rest ], DynamoScalar v1 hash, MonadAWS m,
   DynamoTable parent r)
  => Proxy a -> hash -> Source m a
querySourceByKey p q = querySourceChunksByKey p q =$= CL.concat

-- | Query an index, fetch primary key from the result and immediately read
-- full items from the main table.
--
-- You cannot perform strongly consistent reads on Global indexes; if you set
-- the 'qConsistentRead' to 'Strongly', fetch from global indexes is still done
-- as eventually consistent. Queries on local indexes are performed according to the settings.
queryOverIndex :: forall a t m v1 v2 hash r2 range rest parent.
    (CanQuery a t hash range, MonadAWS m,
     Code a ~ '[ hash ': range ': rest],
     DynamoIndex a parent 'WithRange, ContainsTableKey a parent (PrimaryKey parent r2),
     DynamoTable parent r2,
     DynamoScalar v1 hash, DynamoScalar v2 range)
  => Proxy a -> QueryOpts a hash range -> Source m parent
queryOverIndex p q =
   querySourceChunks p (q & setConsistency)
      =$= CL.mapFoldableM batchParent
  where
    setConsistency -- Strong consistent reads not supported on global indexes
      | indexIsLocal p = id
      | otherwise = qConsistentRead .~ Eventually
    batchParent vals = getItemBatch (q ^. qConsistentRead) (map dTableKey vals)

-- | Perform a simple, eventually consistent, query.
--
-- Simple to use function to query limited amount of data from database.
querySimple :: forall a t m hash range.
  (CanQuery a t hash range, MonadAWS m)
  => Proxy a -- ^ Proxy type of a table to query
  -> hash        -- ^ Hash key
  -> Maybe (RangeOper range) -- ^ Range condition
  -> Direction -- ^ Scan direction
  -> Int -- ^ Maximum number of items to fetch
  -> m [a]
querySimple p key range direction limit = do
  let opts = queryOpts key & qRangeCondition .~ range
                           & qDirection .~ direction
  fst <$> query p opts limit

-- | Query with condition
queryCond :: forall a t m hash range.
  (CanQuery a t hash range, MonadAWS m)
  => Proxy a
  -> hash        -- ^ Hash key
  -> Maybe (RangeOper range) -- ^ Range condition
  -> FilterCondition a
  -> Direction -- ^ Scan direction
  -> Int -- ^ Maximum number of items to fetch
  -> m [a]
queryCond p key range cond direction limit = do
  let opts = queryOpts key & qRangeCondition .~ range
                           & qDirection .~ direction
                           & qFilterCondition .~ Just cond
  fst <$> query p opts limit

-- | Fetch exactly the required count of items even when
-- it means more calls to dynamodb. Return last evaluted key if end of data
-- was not reached. Use 'qStartKey' to continue reading the query.
query :: forall a t m range hash.
  (CanQuery a t hash range, MonadAWS m)
  => Proxy a
  -> QueryOpts a hash range
  -> Int -- ^ Maximum number of items to fetch
  -> m ([a], Maybe (PrimaryKey a 'WithRange))
query p opts limit = do
    (items, newquery, _) <- query' p opts limit
    return (items, newquery)

-- | Fetch exactly the required count of items even when
-- it means more calls to dynamodb. Return last evaluted key if end of data
-- was not reached. Use 'qStartKey' to continue reading the query.
query' :: forall a t m range hash.
  (CanQuery a t hash range, MonadAWS m)
  => Proxy a
  -> QueryOpts a hash range
  -> Int -- ^ Maximum number of items to fetch
  -> m ([a], Maybe (PrimaryKey a 'WithRange), Rs D.Query)
query' _ opts limit = do
    -- Add qLimit to the opts if not already there - and if there is no condition
    let cmd = queryCmd (opts & addQLimit)
    boundedFetch' D.qExclusiveStartKey (view D.qrsItems) (view D.qrsLastEvaluatedKey) cmd limit
  where
    addQLimit
      | Nothing <- opts ^. qLimit, Nothing <- opts ^. qFilterCondition = qLimit .~ Just (fromIntegral limit)
      | otherwise = id

-- | Generic query interface for scanning/querying
boundedFetch :: forall a r t m cmd.
  (MonadAWS m, HasPrimaryKey a r t, AWSRequest cmd)
  => Lens' cmd (HashMap T.Text D.AttributeValue)
  -> (Rs cmd -> [HashMap T.Text D.AttributeValue])
  -> (Rs cmd -> HashMap T.Text D.AttributeValue)
  -> cmd
  -> Int -- ^ Maximum number of items to fetch
  -> m ([a], Maybe (PrimaryKey a r))
boundedFetch startLens rsResult rsLast startcmd limit = do
      (items, newquery, _) <- boundedFetch' startLens rsResult rsLast startcmd limit
      return (items, newquery)

-- | Generic query interface for scanning/querying
boundedFetch' :: forall a r t m cmd.
  (MonadAWS m, HasPrimaryKey a r t, AWSRequest cmd)
  => Lens' cmd (HashMap T.Text D.AttributeValue)
  -> (Rs cmd -> [HashMap T.Text D.AttributeValue])
  -> (Rs cmd -> HashMap T.Text D.AttributeValue)
  -> cmd
  -> Int -- ^ Maximum number of items to fetch
  -> m ([a], Maybe (PrimaryKey a r), Rs cmd)
boundedFetch' startLens rsResult rsLast startcmd limit = do
      (result, nextcmd, rs') <- unfoldLimit fetch startcmd limit
      if | length result > limit ->
             let final = Seq.take limit result
             in case Seq.viewr final of
                 Seq.EmptyR -> return ([], Nothing, rs')
                 (_ Seq.:> lastitem) -> return (toList final, Just (dItemToKey lastitem), rs')
         | length result == limit, Just rs <- nextcmd ->
              return (toList result, dAttrToKey (Proxy :: Proxy a) (rs ^. startLens), rs')
         | otherwise -> return (toList result, Nothing, rs')
  where
    fetch cmd = do
        rs <- send cmd
        items <- Seq.fromList <$> mapM rsDecoder (rsResult rs)
        let lastkey = rsLast rs
            newquery = bool (Just (cmd & startLens .~ lastkey)) Nothing (null lastkey)
        return (items, newquery, rs)

-- | Run command as long as Maybe cmd is Just or the resulting sequence is smaller than limit and return result
unfoldLimit :: Monad m => (cmd -> m (Seq a, Maybe cmd, Rs cmd)) -> cmd -> Int -> m (Seq a, Maybe cmd, Rs cmd)
unfoldLimit code = go
  where
    go cmd limit = do
      (vals, mnext, rs) <- code cmd
      let cnt = length vals
      if | Just next <- mnext, cnt < limit -> go next (limit - cnt) >>= \(vals', mnext', rs') -> return (vals <> vals', mnext', rs')
         | otherwise                       -> return (vals, mnext, rs)

-- | Record for defining scan command. Use lenses to set the content.
--
-- sParallel: (Segment number, Total segments)
data ScanOpts a r = ScanOpts {
    _sFilterCondition :: Maybe (FilterCondition a)
  , _sConsistentRead :: Consistency
  , _sLimit :: Maybe Natural
  , _sParallel :: Maybe (Natural, Natural) -- ^ (Segment number, TotalSegments)
  , _sStartKey :: Maybe (PrimaryKey a r)
}
makeLenses ''ScanOpts
scanOpts :: ScanOpts a r
scanOpts = ScanOpts Nothing Eventually Nothing Nothing Nothing

-- | Conduit source for running scan; the same as 'scanSource', but return results in chunks as they come.
scanSourceChunks :: (MonadAWS m, TableScan a r t) => Proxy a -> ScanOpts a r -> Source m [a]
scanSourceChunks _ q = paginate (scanCmd q) =$= CL.mapM (\res -> mapM rsDecoder (res ^. D.srsItems))

-- | Conduit source for running a scan.
scanSource :: (MonadAWS m, TableScan a r t) => Proxy a -> ScanOpts a r -> Source m a
scanSource p q = scanSourceChunks p q =$= CL.concat

-- | Function to call bounded scans. Tries to return exactly requested number of items.
--
-- Use 'sStartKey' to continue the scan.
scan :: (MonadAWS m, TableScan a r t)
  => Proxy a
  -> ScanOpts a r  -- ^ Scan settings
  -> Int  -- ^ Required result count
  -> m ([a], Maybe (PrimaryKey a r)) -- ^ list of results, lastEvalutedKey or Nothing if end of data reached
scan p opts limit = do
    (items, newquery, _) <- scan' p opts limit
    return (items, newquery)

-- | Function to call bounded scans. Tries to return exactly requested number of items.
--
-- Use 'sStartKey' to continue the scan.
scan' :: (MonadAWS m, TableScan a r t)
  => Proxy a
  -> ScanOpts a r  -- ^ Scan settings
  -> Int  -- ^ Required result count
  -> m ([a], Maybe (PrimaryKey a r), Rs D.Scan) -- ^ list of results, lastEvalutedKey or Nothing if end of data reached
scan' _ opts limit = do
    let cmd = scanCmd (opts & addSLimit)
    boundedFetch' D.sExclusiveStartKey (view D.srsItems) (view D.srsLastEvaluatedKey) cmd limit
  where
    -- If there is no filtercondition, number of processed items = number of scanned items
    addSLimit
      | Nothing <- opts ^. sLimit, Nothing <- opts ^. sFilterCondition = sLimit .~ Just (fromIntegral limit)
      | otherwise = id

-- | Generate a "D.Query" object.
scanCmd :: forall a r t. TableScan a r t => ScanOpts a r -> D.Scan
scanCmd q =
    defaultScan (Proxy :: Proxy a)
        & D.sConsistentRead . consistencyL .~ (q ^. sConsistentRead)
        & D.sLimit .~ (q ^. sLimit)
        & addStartKey (q ^. sStartKey)
        & addCondition (q ^. sFilterCondition)
        & addParallel (q ^. sParallel)
  where
    addCondition Nothing = id
    addCondition (Just cond) =
      let (expr, attnames, attvals) = dumpCondition cond
      in (D.sExpressionAttributeNames %~ (<> attnames))
           -- HACK; https://github.com/brendanhay/amazonka/issues/332
         . bool (D.sExpressionAttributeValues %~ (<> attvals)) id (null attvals)
         . (D.sFilterExpression .~ Just expr)
    --
    addStartKey Nothing = id
    addStartKey (Just pkey) = D.sExclusiveStartKey .~ dKeyToAttr (Proxy :: Proxy a) pkey
    --
    addParallel Nothing = id
    addParallel (Just (segment,total)) =
        (D.sTotalSegments .~ Just total)
        . (D.sSegment .~ Just segment)


-- | Scan table using a given filter condition.
--
-- > scanCond (colAddress <!:> "Home" <.> colCity ==. "London") 10
scanCond :: forall a m r t. (MonadAWS m, TableScan a r t) => Proxy a -> FilterCondition a -> Int -> m [a]
scanCond _ cond limit = do
  let opts = scanOpts & sFilterCondition .~ Just cond
      cmd = scanCmd opts
  fst <$> boundedFetch D.sExclusiveStartKey (view D.srsItems) (view D.srsLastEvaluatedKey) cmd limit

-- | Conduit to do a left join on the items being sent; supposed to be used with querySourceChunks.
--
-- The 'foreign key' must have an 'Ord' to facilitate faster searching.
leftJoin :: forall a b m r.
    (MonadAWS m, DynamoTable a r, Ord (PrimaryKey a r), ContainsTableKey a a (PrimaryKey a r))
    => Consistency
    -> Proxy a -- ^ Proxy type for the right table
    -> (b -> Maybe (PrimaryKey a r))
    -> Conduit [b] m [(b, Maybe a)]
leftJoin consistency p getkey = CL.mapM doJoin
  where
    doJoin input = do
      let keys = filter (dKeyIsDefined p) $ mapMaybe getkey input
      rightTbl <- getItemBatch consistency keys
      let resultMap = Map.fromList $ map (\res -> (dTableKey res,res)) rightTbl
      return $ map (second (id >=> (`Map.lookup` resultMap))) $ zip input $ map getkey input

-- | The same as 'leftJoin', but discard items that do not exist in the right table.
innerJoin :: forall a b m r.
    (MonadAWS m, DynamoTable a r, Ord (PrimaryKey a r), ContainsTableKey a a (PrimaryKey a r))
    => Consistency
    -> Proxy a -- ^ Proxy type for the right table
    -> (b -> Maybe (PrimaryKey a r))
    -> Conduit [b] m [(b, a)]
innerJoin consistency p getkey =
    leftJoin consistency p getkey =$= CL.map (mapMaybe (sequenceOf _2))
